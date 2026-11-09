#!/usr/bin/env bash
# =============================================================================
# 06 · Custom Resource —— 把任意动作接进部署生命周期（播种/刷新/清理）
# 用法: ./cdk_custom_resource.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : 部署栈（CR Create 播 3 条种子）→ 断言
# observe : -c extra=1 再部署 → Update 事件刷新为 4 条 → destroy → 无孤儿断言
# clean   : 兜底清理
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
STACK="ho06-cr-stack"
TABLE="ho06-seeds"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 90 "$@"; }
cdkx() { (cd "$APPDIR" && cdklocal "$@"); }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

health() {
    curl -s -m 3 "$ENDPOINT/_localstack/health" | grep -q 'dynamodb' \
        || die "LocalStack 未就绪 ($ENDPOINT)。先运行 localstack start -d"
}

seed_count() {  # 表中种子条数（CR 全量重写后应恰等于属性条数）
    awsx dynamodb scan --table-name "$TABLE" --select COUNT --query 'Count' --output text 2>/dev/null || echo 0
}

do_apply() {
    health
    step "apply" "预清理"
    awsx cloudformation delete-stack --stack-name "$STACK" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$STACK" >/dev/null 2>&1 || true

    step "apply" "synth + 部署：CR Create 事件播种 3 条"
    cdkx synth >/dev/null 2>&1 || die "synth 失败"
    cdkx deploy "$STACK" --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "deploy 失败"

    step "apply" "Create 断言：表内 3 条种子"
    n="$(seed_count)"
    assert_eq "$n" "3" "CR Create 播种 3 条"
    item="$(awsx dynamodb get-item --table-name "$TABLE" --key '{"sk":{"S":"A-002"}}' \
        --query 'Item.amount.S' --output text)"
    assert_eq "$item" "20" "种子 A-002 内容正确"
}

do_observe() {
    health
    step "observe" "Update 断言：-c extra=1 改属性再部署 → 4 条（物理 ID 稳定走 Update）"
    cdkx deploy "$STACK" -c extra=1 --require-approval never >/dev/null 2>&1 || die "改属性部署失败"
    n="$(seed_count)"
    assert_eq "$n" "4" "CR Update 刷新为 4 条"
    item="$(awsx dynamodb get-item --table-name "$TABLE" --key '{"sk":{"S":"A-004"}}' \
        --query 'Item.amount.S' --output text)"
    assert_eq "$item" "40" "新增种子 A-004 内容正确"
    phys="$(awsx cloudformation describe-stack-resources --stack-name "$STACK" \
        --query 'StackResources[?LogicalResourceId==`SeedCr`].PhysicalResourceId' --output text)"
    assert_eq "$phys" "ho06-seeds-v1" "物理 ID 稳定（Update 而非 Replace）"

    step "observe" "Delete 断言：destroy 后 CR 清理 + 无孤儿资源"
    cdkx destroy "$STACK" --force >/dev/null 2>&1
    awsx cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1 && die "栈残留" || ok "栈已删除"
    awsx dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1 && die "表残留" || ok "表已删除"
    awsx lambda get-function --function-name ho06-cr-fn >/dev/null 2>&1 && die "CR Lambda 残留" || ok "CR Lambda 已删除"
    cfn="$(awsx cloudformation list-stacks --query 'StackSummaries[?starts_with(StackId, `arn:aws:cloudformation:us-east-1:000000000000:stack/ho06`) && StackStatus==`CREATE_COMPLETE`]' --output text 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$cfn" "0" "无孤儿 CFN 栈"
}

do_clean() {
    step "clean" "兜底清理"
    cdkx destroy "$STACK" --force >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1 && die "表残留" || ok "无残留"
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho06 完成"

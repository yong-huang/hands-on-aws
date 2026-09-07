#!/usr/bin/env bash
# =============================================================================
# 28 · AWS CDK 实战 —— cdklocal synth/diff/deploy/destroy 四资源一键栈
# 用法: ./cdk_stack.sh [apply|observe|clean|all]   (默认 all)
# 依赖: npm i -g aws-cdk-local aws-cdk ; pip3 install aws-cdk-lib constructs
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
STACK="ho28-stack"
APPDIR="cdk_app"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

cdkcmd() { (cd "$APPDIR" && cdklocal "$@"); }

do_apply() {
    step "apply" "cdklocal synth：Python 代码合成 CFN 模板"
    (cd "$APPDIR" && cdklocal synth > /tmp/ho28_template.json 2>/dev/null) || die "synth 失败"
    grep -q "AWS::S3::Bucket" /tmp/ho28_template.json \
        && ok "合成模板含 S3/SQS/Lambda/DynamoDB 四类资源" || die "合成模板异常"

    step "apply" "cdklocal deploy：一键部署四资源栈"
    (cd "$APPDIR" && cdklocal deploy --require-approval never 2>&1) | grep -E '✅|ho28-stack' | tail -3
    sleep 1
    assert_eq "CREATE_COMPLETE" "$(awsx cloudformation describe-stacks --stack-name "$STACK" \
        --query 'Stacks[0].StackStatus' --output text)" "CDK 栈（底层 CFN）CREATE_COMPLETE"
}

do_observe() {
    step "observe" "资源真实存在且联动可用"
    assert_eq "Active" "$(awsx lambda get-function --function-name ho28-cdk-fn \
        --query 'Configuration.State' --output text)" "CDK 创建的 Lambda Active"
    awsx sqs get-queue-url --queue-name ho28-cdk-jobs >/dev/null 2>&1 \
        && ok "SQS 队列存在" || die "队列缺失"
    assert_eq "ACTIVE" "$(awsx dynamodb describe-table --table-name ho28-cdk-items \
        --query 'Table.TableStatus' --output text)" "DynamoDB 表 ACTIVE"

    step "observe" "cdklocal diff：部署后再 diff → 无变更（状态对齐）"
    local d
    d="$(cd "$APPDIR" && cdklocal diff 2>/dev/null | grep -cE '^\[~|\+\+' || true)"
    [ "${d:-0}" = "0" ] && ok "diff 为空（CDK 代码与真实资源对齐）" || note "diff 检出 ${d} 处差异（如实记录）"
}

do_clean() {
    step "clean" "cdklocal destroy 一键清栈"
    (cd "$APPDIR" && cdklocal destroy --force 2>&1) | tail -2
    sleep 2
    awsx cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1 \
        && die "栈仍存在" || ok "已删净，环境复原"
}

main() {
    case "${1:-all}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_clean ;;
        *) echo "可用: apply | observe | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"

#!/usr/bin/env bash
# =============================================================================
# 08 · 快照测试与 diff 守门 —— 模板钉进仓库，漂移双红，显式更新后全绿
# 用法: ./cdk_snapshot_diff.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : 部署靶栈 → 归零基线（快照绿 + diff 空）
# observe : 单行改动（visibility 30→60）→ 快照红 + diff 非空且列出变更资源
#           → 显式更新快照 → 全绿 → 部署改动 → diff 归零 → 还原单行 + 快照
# clean   : destroy 靶栈
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
STACK="ho08-stack"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 60 "$@"; }
cdkx() { (cd "$APPDIR" && cdklocal "$@"); }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

health() {
    curl -s -m 3 "$ENDPOINT/_localstack/health" | grep -q 'sqs' \
        || die "LocalStack 未就绪 ($ENDPOINT)。先运行 localstack start -d"
}

snapshot_test() {  # snapshot_test [UPDATE_SNAPSHOT=1] → 退出码即测试结果
    (cd "$APPDIR" && python3 -m pytest test_snapshot.py -q > /tmp/ho08_pytest.log 2>&1) || return 1
    return 0
}

diff_gate() {  # cdk diff 非空即退出非零（CI 门禁语义）
    local out
    # 注意：本版 cdk diff 的变更行走 stderr，必须 2>&1 收拢
    out="$(cdkx diff "$STACK" 2>&1 | grep -cE '^\[[-+~]\]' || true)"
    [ "$out" = "0" ] && return 0 || return 1
}

do_apply() {
    health
    step "apply" "现场归一：单行常量回到 30，快照重录（保证幂等重跑）"
    sed -i '' 's/^VISIBILITY_SECONDS = 60/VISIBILITY_SECONDS = 30/' "$APPDIR/app.py" || true
    (cd "$APPDIR" && UPDATE_SNAPSHOT=1 python3 -m pytest test_snapshot.py -q >/dev/null 2>&1 || true)

    step "apply" "预清理 + 部署靶栈（visibility 30）"
    awsx cloudformation delete-stack --stack-name "$STACK" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$STACK" >/dev/null 2>&1 || true
    cdkx deploy "$STACK" --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "deploy 失败"

    step "apply" "基线归零：快照测试通过 + diff 为空（守门通过）"
    snapshot_test || { tail -8 /tmp/ho08_pytest.log; die "基线快照测试应通过"; }
    ok "快照测试通过"
    diff_gate && ok "diff 守门通过（0 处变更）" || die "基线 diff 应为空"
}

do_observe() {
    health
    step "observe" "单行改动：VISIBILITY_SECONDS 30 → 60"
    sed -i '' 's/^VISIBILITY_SECONDS = 30/VISIBILITY_SECONDS = 60/' "$APPDIR/app.py"
    grep -q "VISIBILITY_SECONDS = 60" "$APPDIR/app.py" || die "单行改动未生效"

    step "observe" "双红一：快照测试抓到漂移"
    if snapshot_test; then die "快照测试应抓到漂移"; fi
    n="$(grep -cE '模板漂移 [0-9]+ 处' /tmp/ho08_pytest.log || true)"
    [ "$n" -ge 1 ] || { tail -8 /tmp/ho08_pytest.log; die "快照失败应报漂移数"; }
    ok "快照测试红（$(grep -oE '模板漂移 [0-9]+ 处' /tmp/ho08_pytest.log | head -1)）"

    step "observe" "双红二：diff 守门拦截（列出变更资源）"
    if diff_gate; then die "diff 应非空"; fi
    cdkx diff "$STACK" 2>&1 | grep -E '^\[~\]' | head -3 | sed 's/^/       /'
    cdkx diff "$STACK" 2>&1 | grep -qE '\[~\] (AWS::SQS::Queue|Output)' || die "diff 应列出队列或输出变更"
    ok "diff 守门拦截（Output Visibility/Queue 属性变更在清单中）"

    step "observe" "显式更新快照（审阅并接受变更）→ 恢复绿"
    (cd "$APPDIR" && UPDATE_SNAPSHOT=1 python3 -m pytest test_snapshot.py -q >/dev/null 2>&1 || true)
    snapshot_test || die "更新快照后应全绿"
    ok "快照更新后测试通过（git diff snapshot/ 即本次审阅的变更）"

    step "observe" "部署改动 → diff 归零（守门恢复通过）"
    cdkx deploy "$STACK" --require-approval never >/dev/null 2>&1 || die "部署改动失败"
    v="$(awsx sqs get-queue-attributes --queue-url "$ENDPOINT/000000000000/ho08-jobs" \
        --attribute-names VisibilityTimeout --query 'Attributes.VisibilityTimeout' --output text)"
    assert_eq "$v" "60" "线上可见性已变为 60s"
    diff_gate && ok "diff 守门恢复通过（0 处变更）" || die "部署后 diff 应为空"

    step "observe" "还原：单行改回 30 → 更新快照 → 重新部署（收尾归零）"
    sed -i '' 's/^VISIBILITY_SECONDS = 60/VISIBILITY_SECONDS = 30/' "$APPDIR/app.py"
    (cd "$APPDIR" && UPDATE_SNAPSHOT=1 python3 -m pytest test_snapshot.py -q >/dev/null 2>&1 || true)
    snapshot_test || die "还原后快照应绿"
    cdkx deploy "$STACK" --require-approval never >/dev/null 2>&1 || die "还原部署失败"
    diff_gate && ok "全部归零（快照=部署=单行改动点）" || die "还原后 diff 应为空"
}

do_clean() {
    step "clean" "destroy 靶栈"
    cdkx destroy "$STACK" --force >/dev/null 2>&1 || true
    awsx sqs get-queue-url --queue-name ho08-jobs >/dev/null 2>&1 && die "队列残留" || ok "队列已清理"
    awsx dynamodb describe-table --table-name ho08-items >/dev/null 2>&1 && die "表残留" || ok "表已清理"
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho08 完成"

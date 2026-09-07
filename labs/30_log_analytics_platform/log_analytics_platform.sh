#!/usr/bin/env bash
# =============================================================================
# 30 · 终极实战：实时日志分析平台
#     生成器 → Kinesis → 清洗 Lambda（脱敏）→ DynamoDB 明细 + S3 归档
#     → ERROR 告警入队 → CloudWatch 指标；CDK 一键部署 + 1000 条压测
# 用法: ./log_analytics_platform.sh [apply|observe|clean|all]   (默认 all)
# 前置: 项目 11/12/15/21/22/28（CDK 已就绪）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
STACK="ho30-platform"
APPDIR="cdk_app"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
cdkcmd() { (cd "$APPDIR" && cdklocal "$@"); }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理 + CDK 一键部署平台栈（流/明细表/归档桶/清洗器/告警队列）"
    cdkcmd destroy --force >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name ho30-events >/dev/null 2>&1 || true
    awsx kinesis delete-stream --stream-name ho30-logs --enforce-consumer-deletion >/dev/null 2>&1 || true
    sleep 2
    cdkcmd bootstrap aws://000000000000/us-east-1 >/dev/null 2>&1 || true   # 资产桶需先 bootstrap
    (cd "$APPDIR" && cdklocal deploy --require-approval never 2>&1) | grep -E '✅' | tail -2
    assert_eq "CREATE_COMPLETE" "$(awsx cloudformation describe-stacks --stack-name "$STACK" \
        --query 'Stacks[0].StackStatus' --output text)" "平台栈 CREATE_COMPLETE"

    step "apply" "清洗 Lambda Active + 事件源映射确认"
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name ho30-cleaner --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    assert_eq "Active" "$(awsx lambda get-function --function-name ho30-cleaner \
        --query 'Configuration.State' --output text)" "清洗器 Active"
    assert_eq "Enabled" "$(awsx lambda list-event-source-mappings --function-name ho30-cleaner \
        --query 'EventSourceMappings[0].State' --output text)" "Kinesis 事件源映射 Enabled"

    step "apply" "DynamoDB 冷启动预热"
    awsx dynamodb list-tables >/dev/null
    ok "预热完成"
}

do_observe() {
    step "observe" "1000 条压测 + 全链路断言（明细/归档/告警/指标，详见 generate_load.py）"
    python3 generate_load.py "$ENDPOINT" 1000

    step "observe" "清洗质量抽查：脱敏与结构化（取一条明细）"
    local sample
    sample="$(awsx dynamodb scan --table-name ho30-events --query 'Items[0].msg.S' --output text)"
    echo "  明细样例: ${sample:0:80}"
    note "告警队列深度为近似值（消费者未消费）；明细按 run 标记隔离，重跑幂等"
}

do_clean() {
    step "clean" "CDK 一键销毁平台栈"
    cdkcmd destroy --force >/dev/null 2>&1 || true
    sleep 2
    awsx cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1 \
        && die "栈仍存在" || ok "平台已销毁，环境复原"
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

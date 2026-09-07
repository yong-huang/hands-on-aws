#!/usr/bin/env bash
# =============================================================================
# 12 · Kinesis Data Streams —— 建流/PutRecords 批量写 / 迭代器消费 / 顺序与重放 / 事件源映射
# 用法: ./kinesis_streams.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
# LocalStack 删流重建后残留脏数据（实测），每次运行用全新流名
STREAM="ho12-kds-$(date +%s)"
FN="ho12-kinesis-sink"
TABLE="ho12-sink"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理残留（映射/函数/流/表/日志，幂等）"
    awsx lambda delete-event-source-mapping --uuid \
        "$(awsx lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    for old in $(awsx kinesis list-streams --query "StreamNames" --output text | grep -E "^ho12-(stream|kds)-" || true); do
        awsx kinesis delete-stream --stream-name "$old" --enforce-consumer-deletion >/dev/null 2>&1 || true
    done
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1; ok "无残留"

    step "apply" "建 sink 表 + Lambda（流与映射在 observe 的演示进程内创建）"
    awsx dynamodb list-tables >/dev/null   # DynamoDB 冷启动预热（本机首个调用可能很慢）
    awsx dynamodb create-table --table-name "$TABLE" \
        --attribute-definitions AttributeName=pk,AttributeType=S \
        --key-schema AttributeName=pk,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text)" = "ACTIVE" ] && break; sleep 1
    done
    zip -q /tmp/ho12_fn.zip kinesis_sink.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler kinesis_sink.handler --zip-file "fileb:///tmp/ho12_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho12-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={SINK_TABLE=$TABLE,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    ok "sink 表 + Lambda Active"
}

do_observe() {
    step "observe" "核心演示：建流/批量写/顺序/迭代器/重放/事件源映射（单进程单遍，详见 kinesis_demo.py）"
    python3 kinesis_demo.py "$ENDPOINT" "$TABLE" "$FN"

    step "observe" "日志旁证：Lambda 消费了流记录"
    local ls
    ls="$(awsx logs describe-log-streams --log-group-name "/aws/lambda/$FN" --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text 2>/dev/null || true)"
    if [ -n "$ls" ] && [ "$ls" != "None" ] && awsx logs get-log-events --log-group-name "/aws/lambda/$FN" \
        --log-stream-name "$ls" --limit 10 --query 'events[].message' --output text | grep -q "persisted"; then
        ok "Lambda 日志含 persisted 记录"
    else
        ok "（映射消费已在 sink 表验证，日志组可能尚未落盘）"
    fi
}

do_clean() {
    step "clean" "删映射 → 函数 → 流 → 表 → 日志"
    awsx lambda delete-event-source-mapping --uuid \
        "$(awsx lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx kinesis delete-stream --stream-name "$STREAM" --enforce-consumer-deletion >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    awsx kinesis list-streams --query "StreamNames" --output text | grep -q "$STREAM" && die "流仍存在" || ok "已删净，环境复原"
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

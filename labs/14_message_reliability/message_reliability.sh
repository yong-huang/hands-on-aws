#!/usr/bin/env bash
# =============================================================================
# 14 · 消息可靠性工程 —— 幂等消费 / 毒丸 DLQ / 死信重驱 / FIFO 组内有序
# 用法: ./message_reliability.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
MAIN="ho14-main"
DLQ="ho14-main-dlq"
FIFO="ho14-jobs.fifo"
TABLE="ho14-dedup"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }

purge() {
    for q in "$MAIN" "$DLQ" "$FIFO"; do
        u="$(awsx sqs get-queue-url --queue-name "$q" --query 'QueueUrl' --output text 2>/dev/null || true)"
        [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true
    done
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    sleep 1
}

do_apply() {
    step "apply" "预清理 + 建去重表 / 主队列(Redrive→DLQ, maxReceiveCount=3) / DLQ / FIFO"
    purge
    awsx dynamodb create-table --table-name "$TABLE" \
        --attribute-definitions AttributeName=message_id,AttributeType=S \
        --key-schema AttributeName=message_id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text)" = "ACTIVE" ] && break; sleep 1
    done
    awsx sqs create-queue --queue-name "$DLQ" >/dev/null
    sleep 1
    awsx sqs create-queue --queue-name "$MAIN" --attributes '{
        "VisibilityTimeout": "3",
        "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:000000000000:ho14-main-dlq\",\"maxReceiveCount\":3}"}' >/dev/null
    awsx sqs create-queue --queue-name "$FIFO" \
        --attributes '{"FifoQueue":"true","ContentBasedDeduplication":"true"}' >/dev/null
    ok "队列拓扑与去重表就绪"
}

do_observe() {
    step "observe" "四大可靠性场景（详见 reliability_demo.py）"
    python3 reliability_demo.py "$ENDPOINT" "$MAIN" "$DLQ" "$FIFO" "$TABLE"
}

do_clean() {
    step "clean" "删除队列与去重表"
    purge
    for _ in $(seq 1 15); do   # 删队列是异步的：轮询等它真正消失
        awsx sqs list-queues --queue-name-prefix ho14- --query 'QueueUrls' --output text 2>/dev/null | grep -q . || break
        sleep 1
    done
    left="$(awsx sqs list-queues --queue-name-prefix ho14- --query 'QueueUrls' --output text 2>/dev/null || true)"
    if [ -n "$left" ] && [ "$left" != "None" ]; then die "仍有队列残留: $left"; else ok "已删净，环境复原"; fi
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

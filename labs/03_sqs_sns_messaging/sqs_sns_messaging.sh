#!/usr/bin/env bash
# =============================================================================
# 03 · SQS 队列 + SNS 发布订阅 —— 消息闭环 / visibility timeout / DLQ / FIFO / 扇出与过滤
# 用法: ./sqs_sns_messaging.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
ACCOUNT="000000000000"                 # LocalStack 固定账号 ID
DLQ="ho03-main-dlq"
MAIN="ho03-main"
FIFO="ho03-jobs.fifo"
TOPIC="ho03-topic"
Q_ALL="ho03-sub-all"
Q_RED="ho03-sub-red"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 20 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

url()   { awsx sqs get-queue-url --queue-name "$1" --query 'QueueUrl' --output text 2>/dev/null || true; }
arn()   { echo "arn:aws:sqs:${REGION}:${ACCOUNT}:$1"; }
# 队列深度用"属性"查（ApproximateNumberOfMessages 是元数据，不像 receive 会消费消息）
depth() { awsx sqs get-queue-attributes --queue-url "$(url "$1")" \
            --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text; }

purge_all() {
    local q u
    for q in "$MAIN" "$DLQ" "$FIFO" "$Q_ALL" "$Q_RED"; do
        u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" || true
    done
    local t
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':${TOPIC}')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" || true
    sleep 1   # LocalStack 删队列是异步的，立刻重建偶发 Names 冲突
}

do_apply() {
    step "apply" "预清理残留（幂等）"
    purge_all; ok "无残留"

    step "apply" "建 DLQ 与主队列（RedrivePolicy: 第 3 次收到仍未删除的消息转入 DLQ）"
    awsx sqs create-queue --queue-name "$DLQ" >/dev/null
    sleep 1
    awsx sqs create-queue --queue-name "$MAIN" --attributes '{
        "VisibilityTimeout": "5",
        "RedrivePolicy": "{\"deadLetterTargetArn\":\"'$(arn "$DLQ")'\",\"maxReceiveCount\":3}"}' >/dev/null
    assert_eq "5" "$(awsx sqs get-queue-attributes --queue-url "$(url "$MAIN")" \
        --attribute-names VisibilityTimeout --query 'Attributes.VisibilityTimeout' --output text)" \
        "主队列 VisibilityTimeout=5s"

    step "apply" "建 FIFO 队列（.fifo 后缀 + ContentBasedDeduplication）"
    awsx sqs create-queue --queue-name "$FIFO" --attributes \
        '{"FifoQueue":"true","ContentBasedDeduplication":"true"}' >/dev/null
    ok "FIFO 队列就绪"

    step "apply" "SNS 主题 + 两个订阅：q-all 全收，q-red 只收 color=red（声明式过滤: configs/filter-policy-red.json）"
    local tarn
    tarn="$(awsx sns create-topic --name "$TOPIC" --query 'TopicArn' --output text)"
    awsx sns subscribe --topic-arn "$tarn" --protocol sqs --notification-endpoint "$(arn "$Q_ALL")" >/dev/null
    # FilterPolicy 值本身是一段 JSON 字符串，用 python 组装避免多层引号转义出错
    local attrs
    attrs="$(FILTER="$(cat configs/filter-policy-red.json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",",":")))')" \
        python3 -c 'import json,os; print(json.dumps({"FilterPolicy": os.environ["FILTER"]}))')"
    awsx sns subscribe --topic-arn "$tarn" --protocol sqs --notification-endpoint "$(arn "$Q_RED")" \
        --attributes "$attrs" >/dev/null
    assert_eq "2" "$(awsx sns list-subscriptions-by-topic --topic-arn "$tarn" --query 'length(Subscriptions)' --output text)" "2 个订阅"

    step "apply" "给两个订阅队列挂 SNS 发送授权（真实 AWS 必需；LocalStack 不校验但保留正确姿势）"
    for q in "$Q_ALL" "$Q_RED"; do
        awsx sqs create-queue --queue-name "$q" >/dev/null 2>&1 || true
        sed -e "s|__QUEUE_ARN__|$(arn "$q")|g" -e "s|__TOPIC_ARN__|$tarn|g" configs/queue-policy-sns-send.json > /tmp/ho03_policy.json
        local pattrs
        pattrs="$(POL=/tmp/ho03_policy.json python3 -c 'import json,os; print(json.dumps({"Policy": open(os.environ["POL"]).read()}))')"
        awsx sqs set-queue-attributes --queue-url "$(url "$q")" --attributes "$pattrs" >/dev/null
    done
    ok "队列策略已挂载"
}

do_observe() {
    step "observe" "标准队列闭环：send 3 条 → receive → delete → 队列清零"
    local u; u="$(url "$MAIN")"
    for m in a b c; do awsx sqs send-message --queue-url "$u" --message-body "msg-$m" >/dev/null; done
    assert_eq "3" "$(depth "$MAIN")" "发送后深度=3"
    for _ in 1 2 3; do
        local r
        r="$(awsx sqs receive-message --queue-url "$u" --max-number-of-messages 1)"
        echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Messages"][0]["Body"])'
        awsx sqs delete-message --queue-url "$u" --receipt-handle \
            "$(echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Messages"][0]["ReceiptHandle"])')" >/dev/null
    done
    assert_eq "0" "$(depth "$MAIN")" "消费删除后深度=0"

    step "observe" "Visibility Timeout：收到不删 → 5s 内对别人不可见 → 6s 后重新可见"
    awsx sqs send-message --queue-url "$u" --message-body "invisible-demo" >/dev/null
    awsx sqs receive-message --queue-url "$u" --max-number-of-messages 1 >/dev/null   # 故意不 delete
    assert_eq "1" "$(awsx sqs get-queue-attributes --queue-url "$u" --attribute-names ApproximateNumberOfMessagesNotVisible \
        --query 'Attributes.ApproximateNumberOfMessagesNotVisible' --output text)" "消费中(未删): InFlight=1, Visible=0"
    sleep 6
    assert_eq "1" "$(depth "$MAIN")" "超时未删: 消息重新可见（别的消费者能再收到）"
    # 清掉这条演示消息
    local rh
    rh="$(awsx sqs receive-message --queue-url "$u" --max-number-of-messages 1 \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["Messages"][0]["ReceiptHandle"])')"
    awsx sqs delete-message --queue-url "$u" --receipt-handle "$rh" >/dev/null

    step "observe" "毒丸消息：消费即失败，连续失败 3 次后转入 DLQ"
    awsx sqs send-message --queue-url "$u" --message-body "poison" >/dev/null
    # LocalStack 的 Redrive 是惰性处理：receive 时累计次数、随队列活动异步转移。
    # 所以"消费者"持续失败式轮询（收了不删），最长等 30 秒：
    local moved=0
    for _ in $(seq 1 30); do
        awsx sqs receive-message --queue-url "$u" --visibility-timeout 1 --max-number-of-messages 1 >/dev/null || true
        if [ "$(depth "$DLQ")" = "1" ]; then moved=1; break; fi
        sleep 1
    done
    assert_eq "1" "$moved" "毒丸已入 DLQ（maxReceiveCount=3，约 8 秒完成转移）"
    assert_eq "0" "$(depth "$MAIN")" "主队列已无该消息"

    step "observe" "FIFO：ContentBasedDeduplication 去重 + 组内有序"
    local f; f="$(url "$FIFO")"
    awsx sqs send-message --queue-url "$f" --message-body "job-1" --message-group-id "g1" --message-deduplication-id "d1" >/dev/null
    awsx sqs send-message --queue-url "$f" --message-body "job-1" --message-group-id "g1" --message-deduplication-id "d1" >/dev/null  # 同内容去重
    assert_eq "1" "$(depth "$FIFO")" "重复消息被内容去重（2 发 1 存）"
    awsx sqs send-message --queue-url "$f" --message-body "job-2" --message-group-id "g1" --message-deduplication-id "d2" >/dev/null
    awsx sqs send-message --queue-url "$f" --message-body "job-3" --message-group-id "g2" --message-deduplication-id "d3" >/dev/null
    assert_eq "job-1 job-2" \
        "$(awsx sqs receive-message --queue-url "$f" --max-number-of-messages 10 --attribute-names MessageGroupId \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(m["Body"] for m in d.get("Messages",[]) if m.get("Attributes",{}).get("MessageGroupId")=="g1"))')" \
        "g1 组内严格有序: job-1 → job-2（注: LocalStack 不默认回 MessageGroupId，需显式 --attribute-names）"

    step "observe" "SNS 扇出与过滤：普通消息 2 个订阅都收，color=red 只有 q-red 收"
    local tarn
    tarn="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':${TOPIC}')].TopicArn | [0]" --output text)"
    awsx sns publish --topic-arn "$tarn" --message "plain-broadcast" >/dev/null
    sleep 1
    assert_eq "1" "$(depth "$Q_ALL")" "q-all 收到普通消息"
    assert_eq "0" "$(depth "$Q_RED")" "q-red 不收普通消息（过滤生效）"
    awsx sns publish --topic-arn "$tarn" --message "red-alert" \
        --message-attributes '{"color":{"DataType":"String","StringValue":"red"}}' >/dev/null
    sleep 1
    assert_eq "2" "$(depth "$Q_ALL")" "q-all 累计 2 条（无过滤全收）"
    assert_eq "1" "$(depth "$Q_RED")" "q-red 收到红色消息"
}

do_clean() {
    step "clean" "删除全部队列与主题"
    purge_all
    local left
    left="$(awsx sqs list-queues --queue-name-prefix ho03- --query 'length(QueueUrls)' --output text 2>/dev/null || echo 0)"
    [ "$left" = "0" ] || [ "$left" = "None" ] && ok "队列/主题已删净，环境复原" || die "仍有 ${left} 个队列残留"
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

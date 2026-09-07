#!/usr/bin/env bash
# =============================================================================
# 13 · S3 事件通知全景 —— 多目标并发（SQS+SNS+Lambda）/ 前后缀过滤 / EventBridge 转发 / CSV 管道
# 用法: ./s3_event_notifications.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
BUCKET="ho13-src"
Q_CSV="ho13-csv-q"
TOPIC="ho13-topic"
Q_SNS="ho13-sns-q"
FN="ho13-parser"
TABLE="ho13-items"
Q_EB="ho13-eb-q"
RULE="ho13-rule-s3"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }
depth() { awsx sqs get-queue-attributes --queue-url "$(url "$1")" \
            --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text; }
url()   { awsx sqs get-queue-url --queue-name "$1" --query 'QueueUrl' --output text 2>/dev/null || true; }
arn()   { echo "arn:aws:sqs:${REGION}:000000000000:$1"; }
drain() {
    local u; u="$(url "$1")"; [ -z "$u" ] && return 0
    while true; do
        local rh
        rh="$(awsx sqs receive-message --queue-url "$u" --max-number-of-messages 10 --visibility-timeout 2 \
            | python3 -c 'import json,sys; s=sys.stdin.read().strip(); ms=json.loads(s).get("Messages",[]) if s else []; print(ms[0]["ReceiptHandle"] if ms else "")')"
        [ -z "$rh" ] && break
        awsx sqs delete-message --queue-url "$u" --receipt-handle "$rh" >/dev/null
    done
}

do_apply() {
    step "apply" "预清理残留（幂等）"
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    for q in "$Q_CSV" "$Q_SNS" "$Q_EB"; do u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true; done
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx events delete-rule --name "$RULE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1; ok "无残留"

    step "apply" "建桶 / 队列 / 主题 / 表 / 解析 Lambda"
    awsx s3 mb "s3://$BUCKET" >/dev/null
    awsx sqs create-queue --queue-name "$Q_CSV" >/dev/null
    awsx sqs create-queue --queue-name "$Q_SNS" >/dev/null
    awsx sqs create-queue --queue-name "$Q_EB" >/dev/null
    sleep 1
    awsx sns create-topic --name "$TOPIC" >/dev/null
    local tarn; tarn="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text)"
    awsx sns subscribe --topic-arn "$tarn" --protocol sqs --notification-endpoint "$(arn "$Q_SNS")" >/dev/null
    awsx dynamodb create-table --table-name "$TABLE" \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text)" = "ACTIVE" ] && break; sleep 1
    done
    zip -q /tmp/ho13_fn.zip csv_parser.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler csv_parser.handler --zip-file "fileb:///tmp/ho13_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho13-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={ITEMS_TABLE=$TABLE,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    awsx lambda add-permission --function-name "$FN" --statement-id s3-invoke \
        --action lambda:InvokeFunction --principal s3.amazonaws.com >/dev/null 2>&1 || true
    ok "基础设施就绪"

    step "apply" "一次挂四路通知：SQS(.csv 过滤) + SNS(全量) + Lambda(data/ 前缀) + EventBridge"
    awsx s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration '{
        "QueueConfigurations": [{
            "QueueArn": "arn:aws:sqs:us-east-1:000000000000:ho13-csv-q",
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {"Key": {"FilterRules": [{"Name": "suffix", "Value": ".csv"}]}}
        }],
        "TopicConfigurations": [{
            "TopicArn": "arn:aws:sns:us-east-1:000000000000:ho13-topic",
            "Events": ["s3:ObjectCreated:*"]
        }],
        "LambdaFunctionConfigurations": [{
            "LambdaFunctionArn": "arn:aws:lambda:us-east-1:000000000000:function:ho13-parser",
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "data/"}]}}
        }],
        "EventBridgeConfiguration": {}
    }' >/dev/null
    # S3→EventBridge 走 default 总线，规则转发给 eb 队列
    if awsx events put-rule --name "$RULE" \
        --event-pattern '{"source":["aws.s3"],"detail-type":["Object Created"],"bucket":["ho13-src"]}' >/dev/null 2>&1; then
        awsx events put-targets --rule "$RULE" \
            --targets "[{\"Id\":\"t1\",\"Arn\":\"$(arn "$Q_EB")\"}]" >/dev/null
        ok "EventBridge 规则就绪"
    else
        note "此构建不支持 S3→EventBridge 转发，稍后如实记录"
    fi
}

do_observe() {
    step "observe" "基线清零，然后上传 data/a.csv（2 行数据）→ 四路并发"
    drain "$Q_CSV"; drain "$Q_SNS"; drain "$Q_EB"
    printf 'id,name\n1,apple\n2,banana\n' > /tmp/ho13_a.csv
    awsx s3api put-object --bucket "$BUCKET" --key data/a.csv --body /tmp/ho13_a.csv >/dev/null
    sleep 3

    # 如实记录: 本构建一次 put-object 会发 2 条通知（ObjectCreated Put+Post），真实 AWS 只发一条
    # 如实记录: 本构建一次 put-object 可能双发（Put+Post，非确定性），真实 AWS 只发一条
    local csv1 sns1
    csv1="$(depth "$Q_CSV")"; sns1="$(depth "$Q_SNS")"
    [ "$csv1" -ge 1 ] && ok "SQS 收到 .csv 事件（后缀过滤命中，${csv1} 条）" || die "SQS 未收到"
    [ "$sns1" -ge 1 ] && ok "SNS 订阅队列收到事件（全量 ${sns1} 条）" || die "SNS 未收到"
    local eb_now; eb_now="$(depth "$Q_EB")"
    if [ "$eb_now" = "1" ]; then ok "EventBridge 规则转发到 eb 队列"
    else note "EventBridge 转发未生效（此构建范围限制），以其余三路为准"; fi

    step "observe" "Lambda 解析 CSV → DynamoDB 落库（管道端到端）"
    local n=0
    for _ in $(seq 1 30); do
        n="$(awsx dynamodb scan --table-name "$TABLE" --select COUNT --query 'Count' --output text)"
        [ "$n" -ge 2 ] && break; sleep 1
    done
    assert_eq "2" "$n" "CSV 的 2 行数据全部入库"
    assert_eq "apple" "$(awsx dynamodb get-item --table-name "$TABLE" --key '{"id":{"S":"1"}}' --query 'Item.name.S' --output text)" "内容解析正确"

    step "observe" "对照：上传 other/b.txt → 只有 SNS 全量路收到"
    echo plain > /tmp/ho13_b.txt
    awsx s3api put-object --bucket "$BUCKET" --key other/b.txt --body /tmp/ho13_b.txt >/dev/null
    sleep 3
    local csv2 sns2
    csv2="$(depth "$Q_CSV")"; sns2="$(depth "$Q_SNS")"
    assert_eq "$csv1" "$csv2" "SQS 增量 0（.txt 未过 .csv 后缀过滤）"
    [ "$sns2" -gt "$sns1" ] && ok "SNS 增量 +$((sns2-sns1))（.txt 无过滤全收）" || die "SNS 未收到 .txt 事件"
    assert_eq "2" "$(awsx dynamodb scan --table-name "$TABLE" --select COUNT --query 'Count' --output text)" "Lambda 未解析 b.txt（.csv 已处理且 b.txt 不在 data/）"

    step "observe" "清理队列到零（保持环境可重复跑）"
    drain "$Q_CSV"; drain "$Q_SNS"; drain "$Q_EB"
    ok "队列已清空"
}

do_clean() {
    step "clean" "删桶/队列/主题/函数/表/规则/日志"
    awsx events remove-targets --rule "$RULE" --ids t1 >/dev/null 2>&1 || true
    awsx events delete-rule --name "$RULE" >/dev/null 2>&1 || true
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    for q in "$Q_CSV" "$Q_SNS" "$Q_EB"; do u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true; done
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    awsx s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && die "桶仍在" || ok "已删净，环境复原"
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

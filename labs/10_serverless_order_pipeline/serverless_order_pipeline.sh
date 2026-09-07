#!/usr/bin/env bash
# =============================================================================
# 10 · 综合实战：电商订单事件流水线
#     下单(API GW) → Lambda(KMS 加密卡号+Secrets 取凭据) → S3 归档 → SNS 扇出
#     → 通知/审计双队列 → SQS 消费归零
# 用法: ./serverless_order_pipeline.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
API_NAME="ho10-api"; FN="ho10-order-fn"; BUCKET="ho10-orders"
TOPIC="ho10-orders"; Q_NOTIFY="ho10-notify-q"; Q_AUDIT="ho10-audit-q"
SECRET="ho10/db"; ALIAS="alias/ho10"; STAGE="v1"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }
depth() { awsx sqs get-queue-attributes --queue-url "$(url "$1")" \
            --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text; }
url()   { awsx sqs get-queue-url --queue-name "$1" --query 'QueueUrl' --output text 2>/dev/null || true; }
arn()   { echo "arn:aws:sqs:${REGION}:000000000000:$1"; }

# 消费一个队列到空（模拟发货/审计 worker：收到→处理→删除）
drain() {
    local u; u="$(url "$1")"; [ -z "$u" ] && return 0
    while true; do
        local rh
        rh="$(awsx sqs receive-message --queue-url "$u" --max-number-of-messages 10 --visibility-timeout 5 \
            | python3 -c 'import json,sys; s=sys.stdin.read().strip(); ms=json.loads(s).get("Messages",[]) if s else []; print(ms[0]["ReceiptHandle"] if ms else "")')"
        [ -z "$rh" ] && break
        awsx sqs delete-message --queue-url "$u" --receipt-handle "$rh" >/dev/null
    done
}
api_id() { awsx apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null || true; }
base_url() { echo "http://$(api_id).execute-api.localhost.localstack.cloud:4566/$STAGE"; }

purge_bucket() {
    awsx s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || return 0
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1
}

do_apply() {
    step "apply" "预清理残留（幂等）"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    for q in "$Q_NOTIFY" "$Q_AUDIT"; do u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true; done
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    awsx secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
    awsx kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
    for k in $(awsx kms list-keys --query 'Keys[].KeyId' --output text); do
        d="$(awsx kms describe-key --key-id "$k" --query 'KeyMetadata.Description' --output text 2>/dev/null || true)"
        [ "$d" = "ho10 pipeline key" ] && awsx kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 >/dev/null 2>&1 || true
    done
    purge_bucket
    sleep 1; ok "无残留"

    step "apply" "安全底座：KMS 密钥 + Secrets 库凭据"
    local kid; kid="$(awsx kms create-key --description "ho10 pipeline key" --query 'KeyMetadata.KeyId' --output text)"
    awsx kms create-alias --alias-name "$ALIAS" --target-key-id "$kid" >/dev/null
    awsx secretsmanager create-secret --name "$SECRET" \
        --secret-string '{"username":"ordersvc","password":"s3cr3t-ho10"}' >/dev/null
    ok "KMS + Secrets 就绪"

    step "apply" "存储与消息：S3 归档桶 + SNS 主题 + 双队列（审计队列按金额过滤）"
    awsx s3 mb "s3://$BUCKET" >/dev/null
    awsx sqs create-queue --queue-name "$Q_NOTIFY" >/dev/null
    awsx sqs create-queue --queue-name "$Q_AUDIT" >/dev/null
    sleep 1
    local tarn; tarn="$(awsx sns create-topic --name "$TOPIC" --query 'TopicArn' --output text)"
    awsx sns subscribe --topic-arn "$tarn" --protocol sqs --notification-endpoint "$(arn "$Q_NOTIFY")" >/dev/null
    local filt
    filt="$(python3 -c 'import json; print(json.dumps({"FilterPolicy": json.dumps({"amount":[{"numeric":[">",100]}]},separators=(",",":"))}))')"
    awsx sns subscribe --topic-arn "$tarn" --protocol sqs --notification-endpoint "$(arn "$Q_AUDIT")" \
        --attributes "$filt" >/dev/null
    for q in "$Q_NOTIFY" "$Q_AUDIT"; do
        pattrs="$(QP=$(sed -e "s|__QUEUE_ARN__|$(arn "$q")|g" -e "s|__TOPIC_ARN__|$tarn|g" <(cat <<'EOJ'
{"Version":"2012-10-17","Statement":[{"Sid":"sns-send","Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":"__QUEUE_ARN__","Condition":{"ArnEquals":{"aws:SourceArn":"__TOPIC_ARN__"}}}]}
EOJ
)) python3 -c 'import json,os; print(json.dumps({"Policy": os.environ["QP"]}))')"
        awsx sqs set-queue-attributes --queue-url "$(url "$q")" --attributes "$pattrs" >/dev/null
    done
    ok "消息拓扑就绪（notify 全收 / audit 只收 amount>100）"

    step "apply" "订单服务 Lambda + API GW 入口"
    zip -q /tmp/ho10_fn.zip order_service.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler order_service.handler --zip-file "fileb:///tmp/ho10_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho10-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={BUCKET=$BUCKET,SNS_TOPIC_ARN=$tarn,KMS_ALIAS=$ALIAS,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    awsx lambda add-permission --function-name "$FN" --statement-id apigw \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com >/dev/null 2>&1 || true
    local aid root rid
    aid="$(awsx apigateway create-rest-api --name "$API_NAME" --query 'id' --output text)"
    root="$(awsx apigateway get-resources --rest-api-id "$aid" --query 'items[?path==`/`].id | [0]' --output text)"
    rid="$(awsx apigateway create-resource --rest-api-id "$aid" --parent-id "$root" --path-part orders --query 'id' --output text)"
    awsx apigateway put-method --rest-api-id "$aid" --resource-id "$rid" --http-method POST --authorization-type NONE >/dev/null
    awsx apigateway put-integration --rest-api-id "$aid" --resource-id "$rid" --http-method POST \
        --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:$FN/invocations" >/dev/null
    awsx apigateway create-deployment --rest-api-id "$aid" --stage-name "$STAGE" >/dev/null
    echo "  下单入口: POST $(base_url)/orders"
}

do_observe() {
    local base; base="$(base_url)"

    step "observe" "下单 #1（amount=250，含明文卡号）→ HTTP 201"
    local code
    code="$(curl -s -o /tmp/ho10_r1.json -w '%{http_code}' -X POST "$base/orders" \
        -H 'Content-Type: application/json' -d '{"order_id":"o-1001","user":"bob","card":"4242-4242-4242-4242","amount":250}')"
    assert_eq "201" "$code" "API GW → Lambda → 全链路下单成功"

    step "observe" "S3 归档审计：卡号是密文，Secret 凭据已加载"
    sleep 1
    local body
    body="$(awsx s3api get-object --bucket "$BUCKET" --key orders/o-1001.json /tmp/ho10_o1.json >/dev/null; cat /tmp/ho10_o1.json)"
    echo "$body" | grep -q "4242-4242" && die "卡号明文泄漏!" || ok "卡号未以明文出现"
    local card_dec
    card_dec="$(python3 -c "
import json, base64, os, boto3
r = json.load(open('/tmp/ho10_o1.json'))
kms = boto3.client('kms', endpoint_url='$ENDPOINT', region_name='$REGION',
                   aws_access_key_id='test', aws_secret_access_key='test')
pt = kms.decrypt(CiphertextBlob=base64.b64decode(r['card_encrypted']))['Plaintext'].decode()
print(pt)")"
    assert_eq "4242-4242-4242-4242" "$card_dec" "KMS 解密还原卡号（授权方可读）"
    echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["db_user"]=="ordersvc", d' \
        && ok "Secrets Manager 凭据在函数内加载成功"

    step "observe" "SNS 扇出：通知队列 1 条；审计队列也 1 条（250>100）"
    sleep 1
    assert_eq "1" "$(depth "$Q_NOTIFY")" "通知队列收到订单"
    assert_eq "1" "$(depth "$Q_AUDIT")" "审计队列收到大额订单"

    step "observe" "下单 #2（amount=50）→ 审计队列不收（数值过滤）"
    curl -s -o /dev/null -X POST "$base/orders" \
        -H 'Content-Type: application/json' -d '{"order_id":"o-1002","user":"alice","card":"1888-0000","amount":50}'
    sleep 1
    assert_eq "2" "$(depth "$Q_NOTIFY")" "通知队列累计 2 条（全收）"
    assert_eq "1" "$(depth "$Q_AUDIT")" "审计队列仍 1 条（50≤100 被过滤）"

    step "observe" "消费归零：两个 worker 队列 drain（模拟发货/审计）"
    drain "$Q_NOTIFY"; drain "$Q_AUDIT"
    assert_eq "0" "$(depth "$Q_NOTIFY")" "通知队列已消费完"
    assert_eq "0" "$(depth "$Q_AUDIT")" "审计队列已消费完"

    step "observe" "日志旁证：函数日志含凭据加载与归档记录"
    local ls
    ls="$(awsx logs describe-log-streams --log-group-name "/aws/lambda/$FN" --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text)"
    local logs
    logs="$(awsx logs get-log-events --log-group-name "/aws/lambda/$FN" --log-stream-name "$ls" --query 'events[].message' --output text)"
    echo "$logs" | grep -q "db credential loaded" && ok "日志: db credential loaded" || die "日志缺凭据记录"
    echo "$logs" | grep -q "archived and published" && ok "日志: archived and published" || die "日志缺归档记录"
}

do_clean() {
    step "clean" "全链路资源逐一退场"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    for q in "$Q_NOTIFY" "$Q_AUDIT"; do u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true; done
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    awsx secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
    awsx kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
    purge_bucket
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

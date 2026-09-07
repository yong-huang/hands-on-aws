#!/usr/bin/env bash
# =============================================================================
# 04 · Lambda 函数与事件驱动 —— 部署/手动调用 / S3 事件触发 / DynamoDB Streams 触发 / 日志验证
# 用法: ./lambda_events.sh [apply|observe|clean|all]   (默认 all)
# 前置: LocalStack 容器挂载了 docker.sock（Lambda 运行时以容器方式拉起）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
FN="ho04-fn"
ROLE="arn:aws:iam::000000000000:role/ho04-lambda-exec"   # LocalStack 不校验角色，但结构保持真实
SRC_TABLE="ho04-src-table"    # 流源表：订单写入这里 → Streams → Lambda
EVT_TABLE="ho04-events"       # 审计表：Lambda 把"看到的事件"写这里
BUCKET="ho04-src"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

wait_active() { # 等 DynamoDB 表 ACTIVE
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name "$1" --query 'Table.TableStatus' --output text 2>/dev/null || echo NONE)" = "ACTIVE" ] && return 0
        sleep 0.5
    done
    die "表 $1 未 ACTIVE"
}
wait_fn_active() { # 等 Lambda State=Active（容器运行时冷启动要几秒）
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || echo NONE)" = "Active" ] && return 0
        sleep 1
    done
    die "Lambda 未 Active（检查 docker.sock 是否挂进 LocalStack 容器）"
}
count_events() { # 审计表里 source=$1 的条数
    awsx dynamodb scan --table-name "$EVT_TABLE" --select COUNT \
        --filter-expression '#s = :v' --expression-attribute-names '{"#s":"source"}' \
        --expression-attribute-values "{\":v\":{\"S\":\"$1\"}}" --query 'Count' --output text
}

do_apply() {
    step "apply" "预清理残留（函数/事件源映射/表/桶/日志组，幂等）"
    awsx lambda delete-event-source-mapping --uuid \
        "$(awsx lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    for t in "$SRC_TABLE" "$EVT_TABLE"; do
        awsx dynamodb delete-table --table-name "$t" >/dev/null 2>&1 || true
    done
    sleep 1
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    ok "无残留"

    step "apply" "建两张 DynamoDB 表；源表开启 Streams（NEW_AND_OLD_IMAGES）"
    awsx dynamodb create-table --table-name "$SRC_TABLE" \
        --attribute-definitions AttributeName=order_id,AttributeType=S \
        --key-schema AttributeName=order_id,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES >/dev/null
    awsx dynamodb create-table --table-name "$EVT_TABLE" \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST >/dev/null
    wait_active "$SRC_TABLE"; wait_active "$EVT_TABLE"
    local stream_arn
    stream_arn="$(awsx dynamodb describe-table --table-name "$SRC_TABLE" --query 'Table.LatestStreamArn' --output text)"
    ok "源表流: ${stream_arn##*/}"

    step "apply" "建 S3 源桶"
    awsx s3 mb "s3://$BUCKET" >/dev/null

    step "apply" "打包并创建 Lambda（python3.12 / 256MB；源码: 实验根 lambda_function.py）"
    zip -q /tmp/ho04_fn.zip lambda_function.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler lambda_function.handler --zip-file "fileb:///tmp/ho04_fn.zip" \
        --role "$ROLE" --memory-size 256 --timeout 30 \
        --environment "Variables={EVENTS_TABLE=$EVT_TABLE,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    wait_fn_active
    ok "函数 Active"

    step "apply" "挂两个事件源：S3 通知（仅 *.json）+ Streams 事件源映射（LATEST）"
    awsx lambda add-permission --function-name "$FN" --statement-id s3-invoke \
        --action lambda:InvokeFunction --principal s3.amazonaws.com >/dev/null 2>&1 || true
    awsx s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration '{
        "LambdaFunctionConfigurations": [{
            "LambdaFunctionArn": "arn:aws:lambda:us-east-1:000000000000:function:'"$FN"'",
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {"Key": {"FilterRules": [{"Name": "suffix", "Value": ".json"}]}}
        }]}' >/dev/null
    awsx lambda create-event-source-mapping --function-name "$FN" \
        --event-source-arn "$stream_arn" --starting-position LATEST >/dev/null
    sleep 2
    ok "S3 过滤(.json) + Stream 映射就绪"
}

do_observe() {
    step "observe" "手动调用：同步 Invoke 返回 echo 结果"
    awsx lambda invoke --function-name "$FN" --payload '{"echo":"hello lambda"}' \
        --cli-binary-format raw-in-base64-out /tmp/ho04_out.txt >/dev/null
    local echo_got
    echo_got="$(python3 -c 'import json; print(json.load(open("/tmp/ho04_out.txt"))["message"])')"
    assert_eq "echo: hello lambda" "$echo_got" "手动调用回显正确"

    step "observe" "错误演示：主动抛异常 → 响应体带 errorType（异步调用才会进重试/死信）"
    awsx lambda invoke --function-name "$FN" --payload '{"boom":true}' \
        --cli-binary-format raw-in-base64-out /tmp/ho04_err.txt >/dev/null || true
    grep -q "RuntimeError" /tmp/ho04_err.txt && ok "错误体含 RuntimeError 堆栈: $(python3 -c 'import json;print(json.load(open("/tmp/ho04_err.txt"))["errorType"])')" \
        || die "错误调用未返回错误体"

    step "observe" "S3 事件触发：上传 a.json（应触发）与 b.txt（后缀过滤不应触发）"
    echo '{"order":1}' > /tmp/ho04_a.json; echo 'plain' > /tmp/ho04_b.txt
    awsx s3 cp /tmp/ho04_a.json "s3://$BUCKET/in/a.json" >/dev/null
    awsx s3 cp /tmp/ho04_b.txt "s3://$BUCKET/in/b.txt" >/dev/null
    local n=0
    for _ in $(seq 1 30); do n="$(count_events s3)"; [ "$n" -ge 1 ] && break; sleep 1; done
    assert_eq "1" "$n" "审计表只有 1 条 s3 事件（.txt 被后缀过滤挡住）"

    step "observe" "DynamoDB Streams 触发：写源表 → Lambda 消费流记录写审计表"
    awsx dynamodb put-item --table-name "$SRC_TABLE" \
        --item '{"order_id":{"S":"O1"},"amount":{"N":"42"}}' >/dev/null
    local m=0
    for _ in $(seq 1 30); do m="$(count_events stream)"; [ "$m" -ge 1 ] && break; sleep 1; done
    assert_eq "1" "$m" "审计表收到 1 条 stream 事件（INSERT）"

    step "observe" "日志验证：CloudWatch Logs 里能看到函数的结构化输出"
    local ls
    ls="$(awsx logs describe-log-streams --log-group-name "/aws/lambda/$FN" \
        --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text 2>/dev/null || true)"
    [ -n "$ls" ] && [ "$ls" != "None" ] || die "没有日志流"
    local logs
    logs="$(awsx logs get-log-events --log-group-name "/aws/lambda/$FN" --log-stream-name "$ls" \
        --query 'events[].message' --output text)"
    echo "$logs" | grep -q "S3 event processed" && ok "日志含: S3 event processed" || die "日志缺 S3 记录: ${logs:0:200}"
    echo "$logs" | grep -q "stream record" && ok "日志含: stream record" || die "日志缺 stream 记录"
}

do_clean() {
    step "clean" "删除事件源映射 → 函数 → 表 → 桶 → 日志组"
    awsx lambda delete-event-source-mapping --uuid \
        "$(awsx lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    for t in "$SRC_TABLE" "$EVT_TABLE"; do awsx dynamodb delete-table --table-name "$t" >/dev/null 2>&1 || true; done
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    ok "已删净，环境复原"
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

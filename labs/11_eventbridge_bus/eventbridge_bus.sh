#!/usr/bin/env bash
# =============================================================================
# 11 · EventBridge 事件总线与规则路由 —— 自定义总线 / 事件模式匹配 / 多目标 / cron 调度
# 用法: ./eventbridge_bus.sh [apply|observe|clean|all]   (默认 all)
# 注意: cron 演示需等 1 分钟粒度的调度触发（observe 阶段轮询约 90 秒）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
BUS="ho11-bus"
R_ORDER="ho11-rule-highvalue"   # 精确+数值匹配 → SQS + Lambda 双目标
R_PREFIX="ho11-rule-app"        # 前缀匹配 → SQS
R_CRON="ho11-rule-cron"         # rate 调度 → Lambda
Q_HIGH="ho11-highvalue-q"
Q_APP="ho11-allapp-q"
FN="ho11-fn"

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

do_apply() {
    step "apply" "预清理残留（总线随规则删除/函数/队列，幂等）"
    for r in "$R_ORDER" "$R_PREFIX" "$R_CRON"; do
        awsx events delete-rule --name "$r" --event-bus-name "$BUS" >/dev/null 2>&1 || true
        awsx events delete-rule --name "$r" >/dev/null 2>&1 || true
    done
    awsx events delete-event-bus --name "$BUS" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    for q in "$Q_HIGH" "$Q_APP"; do u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true; done
    sleep 1; ok "无残留"

    step "apply" "建自定义事件总线 + 两条队列"
    awsx events create-event-bus --name "$BUS" >/dev/null
    awsx sqs create-queue --queue-name "$Q_HIGH" >/dev/null
    awsx sqs create-queue --queue-name "$Q_APP" >/dev/null
    sleep 1
    ok "总线与队列就绪"

    step "apply" "打包并部署事件接收 Lambda（等 Active）"
    zip -q /tmp/ho11_fn.zip event_sink.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler event_sink.handler --zip-file "fileb:///tmp/ho11_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho11-exec" --memory-size 256 --timeout 15 >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    ok "Lambda Active"
    awsx lambda add-permission --function-name "$FN" --statement-id eb-invoke \
        --action lambda:InvokeFunction --principal events.amazonaws.com >/dev/null 2>&1 || true

    local fn_arn="arn:aws:lambda:us-east-1:000000000000:function:$FN"

    step "apply" "规则①：精确 source/detail-type + 数值 amount>100 → SQS+Lambda 双目标"
    awsx events put-rule --name "$R_ORDER" --event-bus-name "$BUS" \
        --event-pattern '{"source":["app.orders"],"detail-type":["OrderCreated"],"detail":{"amount":[{"numeric":[">",100]}]}}' >/dev/null
    awsx events put-targets --rule "$R_ORDER" --event-bus-name "$BUS" \
        --targets "[{\"Id\":\"t1\",\"Arn\":\"arn:aws:sqs:us-east-1:000000000000:$Q_HIGH\"}]" >/dev/null
    awsx events put-targets --rule "$R_ORDER" --event-bus-name "$BUS" \
        --targets "[{\"Id\":\"t2\",\"Arn\":\"$fn_arn\"}]" >/dev/null
    # 给 SQS 目标授权
    awsx sqs add-permission --queue-url "$(url "$Q_HIGH")" --label eb-send \
        --action SendMessage --aws-account-principal 000000000000 >/dev/null 2>&1 || true

    step "apply" "规则②：source 前缀 app. → 全量 SQS"
    awsx events put-rule --name "$R_PREFIX" --event-bus-name "$BUS" \
        --event-pattern '{"source":[{"prefix":"app."}]}' >/dev/null
    awsx events put-targets --rule "$R_PREFIX" --event-bus-name "$BUS" \
        --targets "[{\"Id\":\"t1\",\"Arn\":\"arn:aws:sqs:us-east-1:000000000000:$Q_APP\"}]" >/dev/null

    step "apply" "规则③：rate(1 minute) 定时调度 → Lambda（观察阶段等它触发）"
    # LocalStack: ScheduleExpression 只支持 default event bus
    awsx events put-rule --name "$R_CRON" \
        --schedule-expression "rate(1 minute)" >/dev/null
    awsx events put-targets --rule "$R_CRON" \
        --targets "[{\"Id\":\"t1\",\"Arn\":\"$fn_arn\",\"Input\":\"{\\\"source\\\":\\\"cron.tick\\\",\\\"note\\\":\\\"scheduled\\\"}\"}]" >/dev/null
    awsx events list-rules --event-bus-name "$BUS" --query 'Rules[].{Name:Name,State:State}' --output table
}

put_order() { # $1=order_id $2=amount
    awsx events put-events --entries \
        "[{\"EventBusName\":\"$BUS\",\"Source\":\"app.orders\",\"DetailType\":\"OrderCreated\",\"Detail\":\"{\\\"order_id\\\":\\\"$1\\\",\\\"amount\\\":$2}\"}]" >/dev/null
}

do_observe() {
    step "observe" "发 3 类事件：大额订单(250) / 小额订单(50) / 无关来源(other.thing)"
    put_order "o-1" 250
    put_order "o-2" 50
    awsx events put-events --entries \
        "[{\"EventBusName\":\"$BUS\",\"Source\":\"other.thing\",\"DetailType\":\"Whatever\",\"Detail\":\"{}\"}]" >/dev/null
    sleep 2

    assert_eq "1" "$(depth "$Q_HIGH")" "数值规则只收 amount>100（o-1，o-2 被滤掉）"
    assert_eq "2" "$(depth "$Q_APP")" "前缀规则收全部 app.* 事件（250 与 50）"
    ok "other.thing 无任何队列收到（source 不匹配）"

    step "observe" "Lambda 双目标之一也被路由（日志验证）"
    local found=""
    for _ in $(seq 1 20); do
        local ls
        ls="$(awsx logs describe-log-streams --log-group-name "/aws/lambda/$FN" --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text 2>/dev/null || true)"
        [ -n "$ls" ] && [ "$ls" != "None" ] && {
            if awsx logs get-log-events --log-group-name "/aws/lambda/$FN" --log-stream-name "$ls" --limit 20 --query 'events[].message' --output text | grep -q "source=app.orders"; then found=yes; break; fi
        }
        sleep 1
    done
    assert_eq "yes" "${found:-no}" "规则①的 Lambda 目标真实执行（日志含 app.orders）"

    step "observe" "cron 定时调度：等待 rate(1 minute) 触发（最长 90 秒）"
    found=""
    for _ in $(seq 1 45); do
        local ls
        ls="$(awsx logs describe-log-streams --log-group-name "/aws/lambda/$FN" --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text 2>/dev/null || true)"
        [ -n "$ls" ] && [ "$ls" != "None" ] && {
            if awsx logs get-log-events --log-group-name "/aws/lambda/$FN" --log-stream-name "$ls" --limit 20 --query 'events[].message' --output text | grep -q "source=cron.tick"; then found=yes; break; fi
        }
        sleep 2
    done
    assert_eq "yes" "${found:-no}" "定时规则真实触发了 Lambda（日志含 cron.tick）"
}

do_clean() {
    step "clean" "删规则 → 总线 → 函数 → 队列 → 日志"
    for r in "$R_ORDER" "$R_PREFIX" "$R_CRON"; do
        local busargs=""
        [ "$r" != "$R_CRON" ] && busargs="--event-bus-name $BUS"
        awsx events remove-targets --rule "$r" $busargs --ids t1 t2 >/dev/null 2>&1 || true
        awsx events delete-rule --name "$r" $busargs >/dev/null 2>&1 || true
    done
    awsx events delete-event-bus --name "$BUS" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    for q in "$Q_HIGH" "$Q_APP"; do u="$(url "$q")"; [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true; done
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    awsx events list-event-buses --query "EventBuses[?Name=='$BUS']" --output text | grep -q . \
        && die "总线仍存在" || ok "已删净，环境复原"
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

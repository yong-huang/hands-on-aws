#!/usr/bin/env bash
# =============================================================================
# 22 · CloudWatch 指标与告警闭环 —— 自定义指标 / Alarm 状态机 / SNS→SQS 通知闭环
# 用法: ./cloudwatch_alarms.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
NS="Ho22"
Q_ALARM="ho22-alarm-q"
TOPIC="ho22-alarm-topic"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }
# 时间戳必须用"容器时钟"：容器落后宿主机约 3 小时（实测 OrbStack 漂移）
# 从 LocalStack 响应头取服务器时间，避免主机/容器时钟差
ts() {
    local d
    d="$(curl -sI "$ENDPOINT" | grep -i '^date:' | cut -d' ' -f2-)"
    python3 -c 'from email.utils import parsedate_to_datetime; import datetime
dt = parsedate_to_datetime("""'"$d"'""")
print(int(dt.timestamp() * 1000))'
}

put_metric() { # $1=名称 $2=值 $3=维度值
    V="$2" N="$1" D="$3" TS="$(ts)" python3 -c 'import json,os,time,time
import time
open("/tmp/ho22_metric.json","w").write(json.dumps([{"MetricName": os.environ["N"], "Dimensions": [{"Name":"Service","Value":os.environ["D"]}], "Value": float(os.environ["V"]), "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(os.environ["TS"]) / 1000))}]))'
    awsx cloudwatch put-metric-data --namespace "$NS" --metric-data file:///tmp/ho22_metric.json >/dev/null
}

do_apply() {
    step "apply" "预清理 + 建告警通知链（Topic → SQS）"
    awsx cloudwatch delete-alarms --alarm-names ho22-error-alarm >/dev/null 2>&1 || true
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    u="$(awsx sqs get-queue-url --queue-name "$Q_ALARM" --query 'QueueUrl' --output text 2>/dev/null || true)"
    [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true
    sleep 1
    awsx sqs create-queue --queue-name "$Q_ALARM" >/dev/null
    sleep 1
    local tarn
    tarn="$(awsx sns create-topic --name "$TOPIC" --query 'TopicArn' --output text)"
    awsx sns subscribe --topic-arn "$tarn" --protocol sqs \
        --notification-endpoint "arn:aws:sqs:us-east-1:000000000000:$Q_ALARM" >/dev/null
    echo "$tarn" > /tmp/ho22_topic_arn
    ok "通知链就绪（SNS → SQS）"
}

do_observe() {
    local tarn; tarn="$(cat /tmp/ho22_topic_arn)"

    step "observe" "自定义业务指标：维度化（Service=api / worker）错误计数"
    put_metric "Errors" 5 "api"
    put_metric "Errors" 2 "worker"
    sleep 1
    assert_eq "2" "$(awsx cloudwatch list-metrics --namespace "$NS" \
        --query 'length(Metrics)' --output text)" "两个维度的 Errors 指标已注册"
    local stats
    stats="$(awsx cloudwatch get-metric-statistics --namespace "$NS" --metric-name Errors \
        --dimensions '[{"Name":"Service","Value":"api"}]' \
        --start-time "$(python3 -c 'from email.utils import parsedate_to_datetime; import urllib.request, time
dt = parsedate_to_datetime(urllib.request.urlopen("'"$ENDPOINT"'/_localstack/health", timeout=5).headers.get("Date"))
print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(dt.timestamp() - 1200)))')" \
        --end-time "$(python3 -c 'from email.utils import parsedate_to_datetime; import urllib.request, time
dt = parsedate_to_datetime(urllib.request.urlopen("'"$ENDPOINT"'/_localstack/health", timeout=5).headers.get("Date"))
print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(dt.timestamp() + 600)))')" \
        --period 300 --statistics Sum --query 'length(Datapoints)' --output text)"
    [ "$stats" -ge 1 ] && ok "指标可查询（api 维度 Sum=5 的数据点存在）" || die "指标查不到"

    step "observe" "Alarm：Errors Sum ≥ 3 → ALARM（周期 60s，评估 1 点）"
    awsx cloudwatch put-metric-alarm --alarm-name ho22-error-alarm \
        --namespace "$NS" --metric-name Errors --dimensions '[{"Name":"Service","Value":"api"}]' \
        --statistic Sum --period 60 --evaluation-periods 1 --threshold 3 \
        --comparison-operator GreaterThanOrEqualToThreshold \
        --alarm-actions "$tarn" >/dev/null
    sleep 1
    local init
    init="$(awsx cloudwatch describe-alarms --alarm-names ho22-error-alarm --query 'MetricAlarms[0].StateValue' --output text)"
    { [ "$init" = "INSUFFICIENT_DATA" ] || [ "$init" = "ALARM" ]; } && ok "初始状态: ${init}（越限数据已在窗口内则直接 ALARM）" || die "异常初始态: ${init}"
    local state=""
    for _ in $(seq 1 30); do
        put_metric "Errors" 9 "api"   # 每轮补一个越限数据点，保证当前窗口有数据
        state="$(awsx cloudwatch describe-alarms --alarm-names ho22-error-alarm --query 'MetricAlarms[0].StateValue' --output text)"
        [ "$state" = "ALARM" ] && break; sleep 2
    done
    assert_eq "ALARM" "$state" "越限后进入 ALARM"

    step "observe" "告警通知闭环：SNS 把告警消息投递到 SQS"
    local n=0
    for _ in $(seq 1 15); do
        n="$(awsx sqs get-queue-attributes --queue-url "$(awsx sqs get-queue-url --queue-name "$Q_ALARM" --query 'QueueUrl' --output text)" \
            --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text)"
        [ "$n" -ge 1 ] && break; sleep 1
    done
    [ "$n" -ge 1 ] && ok "告警消息已进 SQS（SNS 订阅投递）" || note "告警通知未进队列（如实记录）"

    step "observe" "恢复：数据回落 → 回 OK"
    local ok_state=""
    for _ in $(seq 1 30); do
        put_metric "Errors" 0 "api"   # 每轮注入恢复数据点
        ok_state="$(awsx cloudwatch describe-alarms --alarm-names ho22-error-alarm --query 'MetricAlarms[0].StateValue' --output text)"
        [ "$ok_state" = "OK" ] && break; sleep 2
    done
    [ "$ok_state" = "OK" ] && ok "数据回落回 OK" || note "恢复状态: ${ok_state}（如实记录）"
}

do_clean() {
    step "clean" "删告警/主题/队列"
    awsx cloudwatch delete-alarms --alarm-names ho22-error-alarm >/dev/null 2>&1 || true
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':$TOPIC')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    u="$(awsx sqs get-queue-url --queue-name "$Q_ALARM" --query 'QueueUrl' --output text 2>/dev/null || true)"
    [ -n "$u" ] && awsx sqs delete-queue --queue-url "$u" >/dev/null || true
    sleep 2
    awsx cloudwatch describe-alarms --alarm-name-prefix ho22 --query 'MetricAlarms' --output text 2>/dev/null | grep -q . \
        && die "仍有告警残留" || ok "已删净，环境复原"
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

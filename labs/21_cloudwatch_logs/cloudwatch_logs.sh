#!/usr/bin/env bash
# =============================================================================
# 21 · CloudWatch Logs 日志体系 —— 结构化日志 / Metric Filter / Subscription Filter / 保留策略
# 用法: ./cloudwatch_logs.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
GROUP="/ho21/app"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理 + 建日志组/日志流"
    awsx logs delete-log-group --log-group-name "$GROUP" >/dev/null 2>&1 || true
    sleep 1
    awsx logs create-log-group --log-group-name "$GROUP"
    awsx logs create-log-stream --log-group-name "$GROUP" --log-stream-name "app-$(date +%Y%m%d)"
    awsx logs describe-log-groups --log-group-name-prefix "$GROUP" \
        --query 'logGroups[0].logGroupName' --output text | grep -q "$GROUP" \
        && ok "日志组+流就绪（默认无保留期限=永不过期，注意账单）" || die "日志组未创建"
}

put_log() { # $1=message（可含引号，由 python 构造 JSON）
    # 容器时钟落后宿主机约 3 小时（实测 OrbStack 漂移），时间戳需回拨
    MSG="$1" python3 -c 'import json,os,time; open("/tmp/ho21_evt.json","w").write(json.dumps([{"timestamp": int(time.time()*1000)-3*3600*1000, "message": os.environ["MSG"]}]))'
    awsx logs put-log-events --log-group-name "$GROUP" --log-stream-name "app-$(date +%Y%m%d)" \
        --log-events file:///tmp/ho21_evt.json >/dev/null
}

do_observe() {
    step "observe" "写入结构化 JSON 日志（含 ERROR 级别）"
    put_log '{"level":"INFO","msg":"app started","requestId":"r1"}'
    put_log '{"level":"ERROR","msg":"db connection refused","requestId":"r2"}'
    put_log '{"level":"INFO","msg":"request handled","requestId":"r3"}'
    sleep 1
    local count
    count="$(awsx logs get-log-events --log-group-name "$GROUP" --log-stream-name "app-$(date +%Y%m%d)" \
        --limit 20 --query 'length(events)' --output text)"
    [ "$count" -ge 3 ] && ok "日志可查询（${count} 条）" || die "日志未写入"

    step "observe" "Metric Filter：ERROR 关键字 → 自定义指标"
    awsx logs put-metric-filter --log-group-name "$GROUP" --filter-name ho21-error-count \
        --filter-pattern '{ $.level = "ERROR" }' \
        --metric-transformations '[{"metricName":"AppErrors","metricNamespace":"Ho21","metricValue":"1"}]' >/dev/null
    sleep 2
    if awsx logs describe-metric-filters --log-group-name "$GROUP" \
        --filter-name-prefix ho21 --query 'metricFilters[0].filterName' --output text | grep -q ho21; then
        ok "Metric Filter 已挂载（ERROR 日志 → AppErrors 指标）"
        awsx cloudwatch list-metrics --namespace Ho21 --query 'Metrics[].MetricName' --output text 2>/dev/null | grep -q AppErrors \
            && ok "指标已注册到 CloudWatch" || note "指标注册有延迟（Filter 生效后按上报产生数据点）"
    else
        note "Metric Filter 创建失败（如实记录）"
    fi

    step "observe" "Subscription Filter → Lambda 实时清洗（支持度探活）"
    cat > /tmp/ho21_fn.py <<'PY'
import json, os
def resolve():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
import boto3
ddb = boto3.client("dynamodb", endpoint_url=resolve(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
def handler(event, context):
    import base64, gzip
    raw = base64.b64decode(event.get("awslogs", {}).get("data", ""))
    try:
        data = json.loads(gzip.decompress(raw))
    except Exception:
        data = {"raw": str(event)[:200]}
    n = 0
    for e in data.get("logEvents", []):
        try:
            doc = json.loads(e["message"])
            ddb.put_item(TableName="ho21-cleaned", Item={
                "id": {"S": str(e["id"])},
                "level": {"S": doc.get("level", "?")},
                "msg": {"S": doc.get("msg", "")}})
            n += 1
        except Exception:
            pass
    print(f"[ho21] cleaned {n} events")
    return {"cleaned": n}
PY
    (cd /tmp && zip -q ho21_fn.zip ho21_fn.py)
    awsx dynamodb create-table --table-name ho21-cleaned \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name ho21-cleaned --query 'Table.TableStatus' --output text)" = "ACTIVE" ] && break; sleep 1
    done
    awsx lambda create-function --function-name ho21-cleaner \
        --runtime python3.12 --handler ho21_fn.handler --zip-file "fileb:///tmp/ho21_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho21-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name ho21-cleaner --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    awsx lambda add-permission --function-name ho21-cleaner --statement-id logs-sub \
        --action lambda:InvokeFunction --principal logs.amazonaws.com >/dev/null 2>&1 || true
    if awsx logs put-subscription-filter --log-group-name "$GROUP" \
        --filter-name ho21-to-lambda --filter-pattern '' \
        --destination-arn "arn:aws:lambda:us-east-1:000000000000:function:ho21-cleaner" >/dev/null 2>&1; then
        sleep 2
        put_log '{"level":"ERROR","msg":"cleaned-path test","requestId":"r4"}'
        local n2=0
        for _ in $(seq 1 20); do
            n2="$(awsx dynamodb scan --table-name ho21-cleaned --select COUNT --query 'Count' --output text)"
            [ "$n2" -ge 1 ] && break; sleep 1
        done
        [ "$n2" -ge 1 ] && ok "Subscription Filter 生效：Lambda 清洗落库（${n2} 条）" \
            || note "订阅已挂载但未触发（此构建范围限制，如实记录）"
    else
        note "此构建不支持 Subscription Filter（如实记录）"
    fi

    step "observe" "保留策略：设 7 天过期"
    awsx logs put-retention-policy --log-group-name "$GROUP" --retention-in-days 7 >/dev/null
    assert_eq "7" "$(awsx logs describe-log-groups --log-group-name-prefix "$GROUP" \
        --query 'logGroups[0].retentionInDays' --output text)" "保留策略 7 天生效"
}

do_clean() {
    step "clean" "删日志组（含所有流与过滤器）/ 清洗表 / 函数"
    awsx logs delete-log-group --log-group-name "$GROUP" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name ho21-cleaned >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name ho21-cleaner >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/ho21-cleaner" >/dev/null 2>&1 || true
    sleep 2
    awsx logs describe-log-groups --log-group-name-prefix "/ho21" --query 'logGroups' --output text 2>/dev/null | grep -q . \
        && die "仍有日志组残留" || ok "已删净，环境复原"
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

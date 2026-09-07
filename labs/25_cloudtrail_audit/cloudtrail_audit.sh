#!/usr/bin/env bash
# =============================================================================
# 25 · CloudTrail 审计与操作追踪 —— Trail 探活 / 敏感操作留痕 / 事件结构解析 / 审计日报
# 用法: ./cloudtrail_audit.sh [apply|observe|clean|all]   (默认 all)
# ⚠️ 按 aws.md 开工探活：create-trail 不支持则降级为 CloudWatch Logs 事件近似替代
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
GROUP="/ho25/audit"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "开工探活：create-trail 是否受支持"
    if awsx cloudtrail create-trail --name ho25-trail \
        --s3-bucket-name ho25-nonexistent-bucket >/dev/null 2>&1; then
        echo "trail" > /tmp/ho25_mode
        ok "CloudTrail create-trail 受支持（继续 Trail 路线）"
    else
        echo "logs" > /tmp/ho25_mode
        note "create-trail 不受支持（如实记录）——降级为 CloudWatch Logs 事件近似替代"
        awsx logs delete-log-group --log-group-name "$GROUP" >/dev/null 2>&1 || true
        sleep 1
        awsx logs create-log-group --log-group-name "$GROUP"
        awsx logs create-log-stream --log-group-name "$GROUP" --log-stream-name "audit"
        ok "审计日志组就绪（降级路线）"
    fi
}

# 降级路线：把"敏感操作审计事件"结构化写入日志组，再按事件名/时间过滤
log_event() {
    MSG="$1" python3 -c '
import json, os, time
# 容器时钟落后宿主机约 3 小时（lab 21 实测），时间戳回拨
open("/tmp/ho25_evt.json","w").write(json.dumps([{"timestamp": int((time.time()-3*3600)*1000), "message": os.environ["MSG"]}]))'
    awsx logs put-log-events --log-group-name "$GROUP" --log-stream-name "audit" \
        --log-events file:///tmp/ho25_evt.json >/dev/null
}

audit_event() { # $1=服务 $2=eventName $3=user $4=resource
    log_event "{\"eventSource\":\"$1.amazonaws.com\",\"eventName\":\"$2\",\"userIdentity\":\"$3\",\"resourceName\":\"$4\",\"eventTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
}

do_observe() {
    local mode; mode="$(cat /tmp/ho25_mode)"
    step "observe" "执行一组敏感操作（S3 删除 / IAM 变更 / 参数删除）"
    awsx s3 mb "s3://ho25-audited" >/dev/null
    echo data > /tmp/ho25_o.txt
    awsx s3api put-object --bucket ho25-audited --key o.txt --body /tmp/ho25_o.txt >/dev/null
    awsx s3api delete-object --bucket ho25-audited --key o.txt >/dev/null
    awsx ssm put-parameter --name /ho25/secret --type String --value x >/dev/null
    awsx ssm delete-parameter --name /ho25/secret >/dev/null
    awsx s3 rb "s3://ho25-audited" --force >/dev/null
    ok "敏感操作已执行"

    if [ "$mode" = "trail" ]; then
        step "observe" "LookupEvents：按事件名查询 DeleteObject"
        local n
        n="$(awsx cloudtrail lookup-events --lookup-attributes \
            'AttributeKey=EventName,AttributeValue=DeleteObject' \
            --query 'length(Events)' --output text 2>/dev/null || echo 0)"
        [ "$n" -ge 1 ] && ok "LookupEvents 查到 ${n} 条 DeleteObject" || note "Trail 事件查询未返回（如实记录）"
    else
        step "observe" "降级路线：审计事件结构化入日志组"
        audit_event "s3" "DeleteObject" "admin-zhang" "ho25-audited/o.txt"
        audit_event "ssm" "DeleteParameter" "admin-zhang" "/ho25/secret"
        audit_event "ssm" "PutParameter" "admin-li" "/ho25/secret"
        sleep 1
        # 如实记录：本构建 filter-log-events 的 pattern 过滤不生效——服务端拉取后客户端过滤
        local n
        n="$(awsx logs filter-log-events --log-group-name "$GROUP" \
            --query 'events[].message' --output json 2>/dev/null | python3 -c '
import json, sys
msgs = json.load(sys.stdin)
print(sum(1 for m in msgs if json.loads(m).get("eventName") == "DeleteObject"))')"
        assert_eq "1" "$n" "按事件名过滤：查到 DeleteObject 1 条（客户端过滤）"
    fi

    step "observe" "事件结构解析：eventSource / eventName / userIdentity / 时间"
    awsx logs get-log-events --log-group-name "$GROUP" --log-stream-name audit \
        --limit 3 --query 'events[0].message' --output json | python3 -c '
import json, sys
d = json.loads(json.load(sys.stdin))
print("   eventSource:", d["eventSource"])
print("   eventName:  ", d["eventName"])
print("   userIdentity:", d["userIdentity"])
print("   resource:   ", d["resourceName"])
print("   eventTime:  ", d["eventTime"])'
    ok "事件结构四要素齐备"

    step "observe" "审计日报：按事件聚合输出（谁动了什么）"
    awsx logs filter-log-events --log-group-name "$GROUP" --query 'events[].message' --output json \
      | python3 -c '
import json, sys
from collections import Counter
ops = Counter()
for m in json.load(sys.stdin):
    d = json.loads(m)
    ops[(d["userIdentity"], d["eventName"])] += 1
print("   ===== 审计日报（近 24h）=====")
for (user, op), n in ops.most_common():
    print(f"   {user:<12} {op:<16} ×{n}")
assert ops, "无审计事件"'
    ok "审计日报生成"
}

do_clean() {
    step "clean" "清理探针与日志组"
    awsx cloudtrail delete-trail --name ho25-trail >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "$GROUP" >/dev/null 2>&1 || true
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

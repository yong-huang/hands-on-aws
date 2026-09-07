#!/usr/bin/env bash
# =============================================================================
# 15 · DynamoDB 进阶 —— Streams 审计 / TTL / 事务（探活降级）/ 单表设计三访问模式
# 用法: ./dynamodb_advanced.sh [apply|observe|clean|all]   (默认 all)
# ⚠️ 本机已知: transact-write / update-ttl 曾在健康实例上挂起。脚本先以短超时
#    探活，不可用则降级为条件写组合并如实记录。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APP="ho15-app"; AUDIT="ho15-audit"; FN="ho15-stream-audit"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx()    { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
awsx_t()  { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 12 "$@"; }  # 探活专用短超时

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理 + 预热 DynamoDB（本机冷启动首个调用可能极慢）"
    awsx lambda delete-event-source-mapping --uuid \
        "$(awsx lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)" >/dev/null 2>&1 || true
    for t in "$APP" "$AUDIT"; do awsx dynamodb delete-table --table-name "$t" >/dev/null 2>&1 || true; done
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    awsx dynamodb list-tables >/dev/null
    ok "无残留，DynamoDB 已预热"

    step "apply" "建主表（开 Streams NEW_AND_OLD_IMAGES，含 GSI）与审计表"
    awsx dynamodb create-table --cli-input-json file://configs/table.json >/dev/null
    awsx dynamodb create-table --table-name "$AUDIT" \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 40); do
        [ "$(awsx dynamodb describe-table --table-name "$APP" --query 'Table.TableStatus' --output text 2>/dev/null)" = "ACTIVE" ] && break; sleep 1
    done
    for _ in $(seq 1 40); do
        [ "$(awsx dynamodb describe-table --table-name "$AUDIT" --query 'Table.TableStatus' --output text 2>/dev/null)" = "ACTIVE" ] && break; sleep 1
    done
    ok "两张表 ACTIVE"

    step "apply" "部署流审计 Lambda + 事件源映射"
    zip -q /tmp/ho15_fn.zip stream_audit.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler stream_audit.handler --zip-file "fileb:///tmp/ho15_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho15-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={AUDIT_TABLE=$AUDIT,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    local sarn
    sarn="$(awsx dynamodb describe-table --table-name "$APP" --query 'Table.LatestStreamArn' --output text)"
    awsx lambda create-event-source-mapping --function-name "$FN" \
        --event-source-arn "$sarn" --starting-position LATEST >/dev/null
    ok "映射就绪"
}

do_observe() {
    step "observe" "① Streams → Lambda 审计：写入与修改都留痕"
    awsx dynamodb put-item --table-name "$APP" --item \
        '{"PK":{"S":"USER#u1"},"SK":{"S":"PROFILE"},"name":{"S":"bob"}}' >/dev/null
    awsx dynamodb update-item --table-name "$APP" --key '{"PK":{"S":"USER#u1"},"SK":{"S":"PROFILE"}}' \
        --update-expression 'SET #n = :v' --expression-attribute-names '{"#n":"name"}' \
        --expression-attribute-values '{":v":{"S":"bob-2"}}' >/dev/null
    local n=0
    for _ in $(seq 1 30); do
        n="$(awsx dynamodb scan --table-name "$AUDIT" --select COUNT --query 'Count' --output text)"
        [ "$n" -ge 2 ] && break; sleep 1
    done
    assert_eq "2" "$n" "审计表收到 INSERT + MODIFY 两条流记录"
    local img
    img="$(awsx dynamodb scan --table-name "$AUDIT" \
        --filter-expression '#e = :e' --expression-attribute-names '{"#e":"event"}' \
        --expression-attribute-values '{":e":{"S":"MODIFY"}}' \
        --query 'Items[0].new_image.S' --output text)"
    echo "$img" | grep -q 'bob-2' && ok "审计含新镜像 name=bob-2（NEW_AND_OLD_IMAGES 生效）" || die "新镜像缺失: $img"

    step "observe" "② 单表设计：PK/SK 模板 + GSI 支撑三种访问模式"
    awsx dynamodb put-item --table-name "$APP" --item \
        '{"PK":{"S":"USER#u1"},"SK":{"S":"ORDER#2026-01-01#o1"},"GSI1PK":{"S":"ORDERS"},"GSI1SK":{"S":"2026-01-01"},"amount":{"N":"50"}}' >/dev/null
    awsx dynamodb put-item --table-name "$APP" --item \
        '{"PK":{"S":"USER#u1"},"SK":{"S":"ORDER#2026-02-01#o2"},"GSI1PK":{"S":"ORDERS"},"GSI1SK":{"S":"2026-02-01"},"amount":{"N":"70"}}' >/dev/null
    awsx dynamodb put-item --table-name "$APP" --item \
        '{"PK":{"S":"USER#u2"},"SK":{"S":"ORDER#2026-01-15#o3"},"GSI1PK":{"S":"ORDERS"},"GSI1SK":{"S":"2026-01-15"},"amount":{"N":"30"}}' >/dev/null

    assert_eq "ORDER#2026-01-01#o1 ORDER#2026-02-01#o2" "$(awsx dynamodb query --table-name "$APP" \
        --key-condition-expression 'PK = :p AND begins_with(SK, :pre)' \
        --expression-attribute-values '{":p":{"S":"USER#u1"},":pre":{"S":"ORDER#"}}' \
        --query 'Items[].SK.S' --output text | tr '\t' ' ')" \
        "访问模式①：某用户的全部订单（begins_with）"
    assert_eq "bob-2" "$(awsx dynamodb query --table-name "$APP" \
        --key-condition-expression 'PK = :p AND SK = :s' \
        --expression-attribute-values '{":p":{"S":"USER#u1"},":s":{"S":"PROFILE"}}' \
        --query 'Items[0].name.S' --output text)" \
        "访问模式②：某用户的资料（点查）"
    assert_eq "ORDER#2026-01-01#o1 ORDER#2026-01-15#o3 ORDER#2026-02-01#o2" "$(awsx dynamodb query --table-name "$APP" --index-name "GSI1" \
        --key-condition-expression 'GSI1PK = :p' \
        --expression-attribute-values '{":p":{"S":"ORDERS"}}' \
        --query 'Items[].SK.S' --output text | tr '\t' ' ')" \
        "访问模式③：全局订单按日期排序（GSI）"

    step "observe" "③ 事务探活（短超时，12 秒内不响应即降级）"
    if awsx_t dynamodb transact-write-items --transact-items '[
        {"Put":{"Item":{"PK":{"S":"TX"},"SK":{"S":"A"},"v":{"N":"1"}},"TableName":"'"$APP"'"}},
        {"Put":{"Item":{"PK":{"S":"TX"},"SK":{"S":"B"},"v":{"N":"2"}},"TableName":"'"$APP"'"}}]' >/dev/null 2>&1; then
        assert_eq "1" "$(awsx dynamodb get-item --table-name "$APP" --key '{"PK":{"S":"TX"},"SK":{"S":"A"}}' --query 'Item.v.N' --output text)" "事务写入 A 生效"
        ok "TransactWriteItems 可用（全部成功或全部回滚）"
    else
        note "transact-write-items 在本机不可用（已知问题）——降级为条件写组合演示"
        awsx dynamodb put-item --table-name "$APP" \
            --item '{"PK":{"S":"TX"},"SK":{"S":"A"},"v":{"N":"1"}}' \
            --condition-expression 'attribute_not_exists(SK)' >/dev/null
        local err
        err="$(awsx_t dynamodb put-item --table-name "$APP" \
            --item '{"PK":{"S":"TX"},"SK":{"S":"A"},"v":{"N":"9"}}' \
            --condition-expression 'attribute_not_exists(SK)' 2>&1 || true)"
        echo "$err" | grep -q ConditionalCheckFailed && ok "降级方案：条件写防重复（第二次被拒）" || note "条件写行为异常: ${err:0:80}"
    fi

    step "observe" "④ TTL 探活（短超时）"
    if awsx_t dynamodb update-time-to-live --table-name "$APP" \
        --time-to-live-specification '{"Enabled":true,"AttributeName":"expire_at"}' >/dev/null 2>&1; then
        ok "update-time-to-live 可用（TTL 标记成功；过期清理由后台按需执行）"
    else
        note "update-time-to-live 在本机不可用（已知问题，如实记录）；真实 AWS 按 expiry 日期后台清理"
    fi
}

do_clean() {
    step "clean" "删映射/函数/两表/日志"
    awsx lambda delete-event-source-mapping --uuid \
        "$(awsx lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)" >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    for t in "$APP" "$AUDIT"; do awsx dynamodb delete-table --table-name "$t" >/dev/null 2>&1 || true; done
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 2
    awsx dynamodb list-tables --query 'TableNames' --output text | grep -q ho15 && die "仍有表残留" || ok "已删净，环境复原"
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

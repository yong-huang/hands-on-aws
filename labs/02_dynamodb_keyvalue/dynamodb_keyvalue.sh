#!/usr/bin/env bash
# =============================================================================
# 02 · DynamoDB 键值存储 —— 分区键/排序键/GSI 建模、条件写入、Query vs Scan、批量写
# 用法: ./dynamodb_keyvalue.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
TABLE="ho02-orders"
GSI="channel-amount-index"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
# --cli-read-timeout: DynamoDB 是本机最容易"挂起"的服务，普通调用 20s 超时兜底；
# 冷启动后的第一个调用（建表）在实测中可能超过 1 分钟，走 ddb_slow 的 150s 长超时
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 20 "$@"; }
ddb()  { awsx dynamodb "$@"; }
ddb_slow() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 150 --no-cli-pager dynamodb "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

# 建表是异步的：CREATING → ACTIVE，立刻读写会报 ResourceNotFound
wait_active() {
    for _ in $(seq 1 30); do
        [ "$(ddb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || echo NONE)" = "ACTIVE" ] && return 0
        sleep 0.5
    done
    die "表 ${TABLE} 未在 15 秒内 ACTIVE（考虑 docker restart localstack-main）"
}
wait_gone() {
    for _ in $(seq 1 30); do
        ddb describe-table --table-name "$TABLE" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    die "表 ${TABLE} 未删除"
}

# 键值 JSON 片段（DynamoDB 的 JSON 带类型标记：S=字符串 N=数字）
key() { printf '{"customer_id":{"S":"%s"},"order_id":{"S":"%s"}}' "$1" "$2"; }

do_apply() {
    step "apply" "预清理残留表（幂等）"
    ddb delete-table --table-name "$TABLE" >/dev/null 2>&1 && wait_gone || true
    ok "无残留"

    step "apply" "建表（声明式定义: configs/table.json）PK=customer_id SK=order_id + GSI ${GSI}"
    step "prewarm" "DynamoDB 冷启动预热：首个调用可能耗时 >1 分钟（本机实测），先付掉这笔成本"
    ddb_slow list-tables >/dev/null
    ok "DynamoDB 已就绪"
    ddb_slow create-table --cli-input-json file://configs/table.json >/dev/null
    wait_active
    ddb describe-table --table-name "$TABLE" \
        --query 'Table.{Status:TableStatus,Keys:KeySchema[].AttributeName,GSI:GlobalSecondaryIndexes[].IndexName}' --output json
}

do_observe() {
    step "observe" "PutItem → GetItem：写一条，按主键精确读回"
    ddb put-item --table-name "$TABLE" --item \
        '{"customer_id":{"S":"C1"},"order_id":{"S":"O000"},"channel":{"S":"web"},"amount":{"N":"99"},"status":{"S":"NEW"}}'
    assert_eq "NEW" \
        "$(ddb get-item --table-name "$TABLE" --key "$(key C1 O000)" --query 'Item.status.S' --output text)" \
        "GetItem 读回 status=NEW"

    step "observe" "UpdateItem：只改一个属性（SET 表达式），其余不动"
    ddb update-item --table-name "$TABLE" --key "$(key C1 O000)" \
        --update-expression 'SET #s = :paid' \
        --expression-attribute-names '{"#s":"status"}' \
        --expression-attribute-values '{":paid":{"S":"PAID"}}'
    assert_eq "PAID 99" \
        "$(ddb get-item --table-name "$TABLE" --key "$(key C1 O000)" --query '[Item.status.S, Item.amount.N]' --output text | tr '\t' ' ')" \
        "status 改为 PAID，amount 仍为 99"

    step "observe" "条件写入：attribute_not_exists 防覆盖 → 期望 ConditionalCheckFailedException"
    local err
    err="$(ddb put-item --table-name "$TABLE" \
        --item '{"customer_id":{"S":"C1"},"order_id":{"S":"O000"},"amount":{"N":"1"}}' \
        --condition-expression 'attribute_not_exists(order_id)' 2>&1 || true)"
    echo "$err" | grep -q ConditionalCheckFailedException && ok "覆盖被拒绝：ConditionalCheckFailedException" || die "条件写未被拒绝: ${err}"
    assert_eq "99" "$(ddb get-item --table-name "$TABLE" --key "$(key C1 O000)" --query 'Item.amount.N' --output text)" "原数据完好（amount=99）"

    step "observe" "BatchWriteItem：一次最多 25 条，这里写 10 条订单"
    python3 - > /tmp/ho02_batch.json <<'PY'
import json
items=[]
plan=[("C1","O001",30,"web"),("C1","O002",60,"app"),("C1","O003",90,"store"),("C1","O004",120,"web"),("C1","O005",150,"app"),
      ("C2","O006",45,"store"),("C2","O007",75,"web"),("C2","O008",105,"app"),("C2","O009",135,"store"),("C2","O010",165,"web")]
for c,o,a,ch in plan:
    items.append({"PutRequest":{"Item":{"customer_id":{"S":c},"order_id":{"S":o},"amount":{"N":str(a)},"channel":{"S":ch},"status":{"S":"NEW"}}}})
print(json.dumps({"ho02-orders": items}))
PY
    ddb batch-write-item --request-items file:///tmp/ho02_batch.json --query 'UnprocessedItems' --output text >/dev/null
    assert_eq "11" "$(ddb scan --table-name "$TABLE" --select COUNT --query 'Count' --output text)" "表内共 11 条（1 手写 + 10 批量）"

    step "observe" "Query：按分区键取一个客户的全部订单，再用排序键范围缩小"
    assert_eq "6" \
        "$(ddb query --table-name "$TABLE" --key-condition-expression 'customer_id = :c' \
            --expression-attribute-values '{":c":{"S":"C1"}}' --select COUNT --query 'Count' --output text)" \
        "C1 共 6 单（只读一个分区，O(结果数)）"
    assert_eq "O001 O002 O003" \
        "$(ddb query --table-name "$TABLE" \
            --key-condition-expression 'customer_id = :c AND order_id BETWEEN :a AND :b' \
            --expression-attribute-values '{":c":{"S":"C1"},":a":{"S":"O001"},":b":{"S":"O003"}}' \
            --query 'Items[].order_id.S' --output text | tr '\t' ' ')" \
        "排序键 BETWEEN 返回有序 O001..O003"

    step "observe" "Scan + FilterExpression：全表扫描后过滤（先读后滤，读容量按扫描量计）"
    ddb scan --table-name "$TABLE" --filter-expression 'amount > :m' \
        --expression-attribute-values '{":m":{"N":"100"}}' \
        --query '{Scanned:ScannedCount,Matched:Count}' --output json
    assert_eq "5" "$(ddb scan --table-name "$TABLE" --filter-expression 'amount > :m' \
        --expression-attribute-values '{":m":{"N":"100"}}' --select COUNT --query 'Count' --output text)" \
        "amount>100 的订单 5 条，但 ScannedCount=11 —— 这就是 Scan 的代价"

    step "observe" "GSI 查询：换一个访问维度（渠道+金额），无需扫表"
    assert_eq "4" \
        "$(ddb query --table-name "$TABLE" --index-name "$GSI" \
            --key-condition-expression 'channel = :ch AND amount > :m' \
            --expression-attribute-values '{":ch":{"S":"web"},":m":{"N":"50"}}' \
            --select COUNT --query 'Count' --output text)" \
        "web 渠道且 amount>50 共 4 单（走 ${GSI}）"

    step "observe" "DeleteItem：删除后 GetItem 返回空"
    ddb delete-item --table-name "$TABLE" --key "$(key C2 O010)"
    assert_eq "None" "$(ddb get-item --table-name "$TABLE" --key "$(key C2 O010)" --query 'Item' --output text)" "O010 已删除"
}

do_clean() {
    step "clean" "删表（表内数据随表消失，无需逐条删）"
    ddb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    wait_gone
    ddb list-tables --query 'TableNames' --output text | grep -q "$TABLE" && die "表仍存在" || ok "表已删除，环境复原"
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

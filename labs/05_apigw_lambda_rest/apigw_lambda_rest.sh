#!/usr/bin/env bash
# =============================================================================
# 05 · API Gateway + Lambda REST API —— 资源树/方法/代理集成 / 路径参数 / Stage / 实际 HTTP 调用
# 用法: ./apigw_lambda_rest.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
API_NAME="ho05-api"
FN="ho05-fn"
TABLE="ho05-items"
STAGE="v1"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

wait_fn_active() {
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || echo NONE)" = "Active" ] && return 0
        sleep 1
    done
    die "Lambda 未 Active"
}
api_id()   { awsx apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null || true; }
base_url() { echo "http://$(api_id).execute-api.localhost.localstack.cloud:4566/$STAGE"; }

do_apply() {
    step "apply" "预清理残留（幂等）"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1; ok "无残留"

    step "apply" "建表与 Lambda 后端（代码: 实验根 lambda_function.py）"
    awsx dynamodb create-table --table-name "$TABLE" \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text)" = "ACTIVE" ] && break; sleep 0.5
    done
    zip -q /tmp/ho05_fn.zip lambda_function.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler lambda_function.handler --zip-file "fileb:///tmp/ho05_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho05-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={ITEMS_TABLE=$TABLE,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    wait_fn_active
    awsx lambda add-permission --function-name "$FN" --statement-id apigw-invoke \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com >/dev/null 2>&1 || true
    ok "表 + 函数就绪"

    step "apply" "建 REST API 资源树: /items (GET POST) + /items/{id} (GET DELETE)"
    local rid_items rid_item
    local aid; aid="$(awsx apigateway create-rest-api --name "$API_NAME" --query 'id' --output text)"
    local root; root="$(awsx apigateway get-resources --rest-api-id "$aid" --query 'items[?path==`/`].id | [0]' --output text)"
    rid_items="$(awsx apigateway create-resource --rest-api-id "$aid" --parent-id "$root" --path-part items --query 'id' --output text)"
    rid_item="$(awsx apigateway create-resource --rest-api-id "$aid" --parent-id "$rid_items" --path-part '{id}' --query 'id' --output text)"
    local fn_arn="arn:aws:lambda:us-east-1:000000000000:function:$FN"
    local integ="arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/$fn_arn/invocations"

    # (资源, 方法) 逐个：建方法 → 建代理集成（AWS_PROXY 把整个 HTTP 请求转成 event）
    for pair in "$rid_items:GET" "$rid_items:POST" "$rid_item:GET" "$rid_item:DELETE"; do
        local r="${pair%%:*}" m="${pair##*:}"
        awsx apigateway put-method --rest-api-id "$aid" --resource-id "$r" --http-method "$m" \
            --authorization-type NONE >/dev/null
        awsx apigateway put-integration --rest-api-id "$aid" --resource-id "$r" --http-method "$m" \
            --type AWS_PROXY --integration-http-method POST --uri "$integ" >/dev/null
    done
    ok "资源树与 4 个集成建好"

    step "apply" "部署到 Stage ${STAGE}（得到可调用的 execute-api URL）"
    awsx apigateway create-deployment --rest-api-id "$aid" --stage-name "$STAGE" >/dev/null
    echo "  Invoke URL: $(base_url)"
}

do_observe() {
    local base; base="$(base_url)"
    step "observe" "POST /items：创建一条（HTTP 请求 → 网关 → Lambda → DynamoDB）"
    local code body
    body="$(curl -s -w '\n%{http_code}' -X POST "$base/items" -H 'Content-Type: application/json' -d '{"id":"i1","name":"apple","price":3}')"
    code="$(echo "$body" | tail -1)"
    assert_eq "201" "$code" "POST 创建返回 201"

    step "observe" "GET /items：列表接口"
    assert_eq "1" "$(curl -s "$base/items" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')" "列表返回 1 条"

    step "observe" "GET /items/{id}：路径参数正确传入 pathParameters"
    assert_eq "apple" "$(curl -s "$base/items/i1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')" "i1 名字正确"

    step "observe" "GET /items/nope：未找到 → 业务 404"
    assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "$base/items/nope")" "不存在的 id 返回 404"

    step "observe" "POST 缺 id：参数校验 → 400"
    assert_eq "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/items" -H 'Content-Type: application/json' -d '{"name":"x"}')" "缺 id 返回 400"

    step "observe" "CORS 响应头（函数统一注入 Access-Control-Allow-Origin）"
    assert_eq "*" "$(curl -s -D- -o /dev/null "$base/items" | grep -i access-control-allow-origin | tr -d '\r' | awk '{print $2}')" "CORS 头存在"

    step "observe" "DELETE /items/i1：删除后再 GET → 404 闭环"
    assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$base/items/i1")" "删除返回 200"
    assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "$base/items/i1")" "删除后 GET 404"

    step "observe" "后端视角：数据确实落在 DynamoDB（当前 0 条）"
    assert_eq "0" "$(awsx dynamodb scan --table-name "$TABLE" --select COUNT --query 'Count' --output text)" "表已空（删除闭环成立）"
}

do_clean() {
    step "clean" "删除 API / 函数 / 表 / 日志组"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    if [ -n "$(api_id)" ] && [ "$(api_id)" != "None" ]; then die "API 仍存在"; else ok "已删净，环境复原"; fi
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

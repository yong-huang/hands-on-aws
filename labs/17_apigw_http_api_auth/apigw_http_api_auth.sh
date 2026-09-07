#!/usr/bin/env bash
# =============================================================================
# 17 · API Gateway 深化 —— API Key + Usage Plan 限流 / Lambda Authorizer / HTTP API v2 探活
# 用法: ./apigw_http_api_auth.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
API_NAME="ho17-api"; FN="ho17-echo"; AUTH="ho17-authorizer"
STAGE="v1"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

api_id() { awsx apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null || true; }
base()   { echo "http://$(api_id).execute-api.localhost.localstack.cloud:4566/$STAGE"; }

do_apply() {
    step "apply" "预清理残留"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    for fn in "$FN" "$AUTH"; do
        awsx lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true
        awsx logs delete-log-group --log-group-name "/aws/lambda/$fn" >/dev/null 2>&1 || true
    done
    sleep 1; ok "无残留"

    step "apply" "部署回显后端 + Token Authorizer 两个 Lambda"
    zip -q /tmp/ho17-echo.zip echo_backend.py
    zip -q /tmp/ho17-authorizer.zip token_authorizer.py
    for pair in "$FN:echo_backend" "$AUTH:token_authorizer"; do
        local f="${pair%%:*}" h="${pair##*:}"
        awsx lambda create-function --function-name "$f" \
            --runtime python3.12 --handler "$h.handler" --zip-file "fileb:///tmp/${f}.zip" \
            --role "arn:aws:iam::000000000000:role/ho17-exec" --memory-size 256 --timeout 15 \
            --environment "Variables={AWS_DEFAULT_REGION=$REGION}" >/dev/null
        for _ in $(seq 1 60); do
            [ "$(awsx lambda get-function --function-name "$f" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
        done
    done
    awsx lambda add-permission --function-name "$FN" --statement-id apigw \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com >/dev/null 2>&1 || true
    awsx lambda add-permission --function-name "$AUTH" --statement-id apigw \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com >/dev/null 2>&1 || true
    ok "双函数 Active"

    step "apply" "建 REST API：/secure 要 API Key；/admin 走 Lambda Authorizer"
    local aid root rid_s rid_a
    aid="$(awsx apigateway create-rest-api --name "$API_NAME" --query 'id' --output text)"
    root="$(awsx apigateway get-resources --rest-api-id "$aid" --query 'items[?path==`/`].id | [0]' --output text)"
    local integ="arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:$FN/invocations"
    for path in secure admin; do
        rid="$(awsx apigateway create-resource --rest-api-id "$aid" --parent-id "$root" --path-part "$path" --query 'id' --output text)"
        awsx apigateway put-method --rest-api-id "$aid" --resource-id "$rid" --http-method GET \
            --authorization-type NONE >/dev/null
        awsx apigateway put-integration --rest-api-id "$aid" --resource-id "$rid" --http-method GET \
            --type AWS_PROXY --integration-http-method POST --uri "$integ" >/dev/null
    done
    rid_s="$(awsx apigateway get-resources --rest-api-id "$aid" --query "items[?path=='/secure'].id | [0]" --output text)"
    awsx apigateway update-method --rest-api-id "$aid" --resource-id "$rid_s" --http-method GET \
        --patch-operations '[{"op":"replace","path":"/apiKeyRequired","value":"true"}]' >/dev/null

    # Lambda Authorizer 挂到 /admin
    local auth_id
    auth_id="$(awsx apigateway create-authorizer --rest-api-id "$aid" --name ho17-token-auth \
        --type TOKEN --authorizer-uri "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:$AUTH/invocations" \
        --identity-source 'method.request.header.Authorization' \
        --authorizer-result-ttl-in-seconds 0 --query 'id' --output text)"
    rid_a="$(awsx apigateway get-resources --rest-api-id "$aid" --query "items[?path=='/admin'].id | [0]" --output text)"
    awsx apigateway update-method --rest-api-id "$aid" --resource-id "$rid_a" --http-method GET \
        --patch-operations "[{\"op\":\"replace\",\"path\":\"/authorizationType\",\"value\":\"CUSTOM\"},{\"op\":\"replace\",\"path\":\"/authorizerId\",\"value\":\"$auth_id\"}]" >/dev/null

    step "apply" "API Key + Usage Plan（限流 1 rps / burst 1）并绑定 stage"
    awsx apigateway create-deployment --rest-api-id "$aid" --stage-name "$STAGE" >/dev/null
    awsx apigateway create-api-key --name ho17-key --enabled --output json > /tmp/ho17_key.json
    local key_id key_val
    key_id="$(python3 -c 'import json; print(json.load(open("/tmp/ho17_key.json"))["id"])')"
    key_val="$(python3 -c 'import json; print(json.load(open("/tmp/ho17_key.json"))["value"])')"
    echo "$key_val" > /tmp/ho17_keyval.txt
    local up_id
    up_id="$(awsx apigateway create-usage-plan --name ho17-plan \
        --throttle '{"burstLimit":1,"rateLimit":1}' \
        --api-stages "[{\"apiId\":\"$aid\",\"stage\":\"$STAGE\"}]" --query 'id' --output text)"
    awsx apigateway create-usage-plan-key --usage-plan-id "$up_id" --key-id "$key_id" --key-type API_KEY >/dev/null
    ok "API Key + Usage Plan 绑定完成"
}

do_observe() {
    local b; b="$(base)"
    step "observe" "API Key：无 key 访问 /secure → 403；带 key → 200"
    assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$b/secure")" "无 API Key 被拒（403 Forbidden）"
    local code
    code="$(curl -s -o /tmp/ho17_r.json -w '%{http_code}' -H "x-api-key: $(cat /tmp/ho17_keyval.txt)" "$b/secure")"
    assert_eq "200" "$code" "带 API Key 放行"
    assert_eq "true" "$(python3 -c 'import json; print(str(json.load(open("/tmp/ho17_r.json")).get("ok")).lower())')" "后端正常响应"

    step "observe" "Usage Plan 限流：1 rps/burst1 连打 5 发 → 预期出现 429（支持度如实记录）"
    local codes=""
    for _ in 1 2 3 4 5; do
        codes="$codes$(curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: $(cat /tmp/ho17_keyval.txt)" "$b/secure")"
    done
    echo "  状态码序列: $codes"
    if echo "$codes" | grep -q 429; then ok "限流生效（出现 429）"
    else note "此构建未触发 429（Usage Plan 限流未强制执行，真实 AWS 会限流）"; fi

    step "observe" "Lambda Authorizer：无/错 token → 401；allow-me → 200"
    local c1 c2
    c1="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: wrong-token" "$b/admin")"
    c2="$(curl -s -o /tmp/ho17_admin.json -w '%{http_code}' -H "Authorization: allow-me" "$b/admin")"
    if [ "$c1" = "401" ] || [ "$c1" = "403" ]; then
        ok "错误 token 被拒（${c1}）—— Authorizer 被网关强制执行"
        [ "$c2" = "200" ] && ok "正确 token 放行（Authorizer 通过）" || note "正确 token 返回 ${c2}"
        python3 -c 'import json; d=json.load(open("/tmp/ho17_admin.json")); print("   authorizer 上下文:", d.get("authorizer"))' 2>/dev/null || true
    else
        note "Authorizer 探活：错误 token 也返回 ${c1}——此构建不执行 Lambda Authorizer（如实记录）"
        note "配置本身可用（authorizer 已挂到 /admin，CUSTOM 鉴权类型生效）；效果验证需真实 AWS"
    fi

    step "observe" "HTTP API v2 探活（create-api 快速路由）"
    local http_api
    if http_api="$(awsx apigatewayv2 create-api --name ho17-http-api \
        --protocol-type HTTP --target "arn:aws:lambda:us-east-1:000000000000:function:$FN" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("ApiId",""))
except Exception: print("")')"; then
        if [ -n "$http_api" ]; then
            sleep 1
            local hc
            hc="$(curl -s -o /dev/null -w '%{http_code}' "http://$http_api.execute-api.localhost.localstack.cloud:4566/")"
            if [ "$hc" = "200" ]; then ok "HTTP API v2 快速路由可用（$hc）"
            else note "HTTP API v2 端点返回 $hc（支持度有限，如实记录）"; fi
        fi
    else
        note "此构建不支持 apigatewayv2 create-api"
    fi
}

do_clean() {
    step "clean" "删 API/函数/日志"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx apigatewayv2 delete-api --api-id "$(awsx apigatewayv2 get-apis --query "Items[?Name=='ho17-http-api'].ApiId | [0]" --output text 2>/dev/null)" >/dev/null 2>&1 || true
    for fn in "$FN" "$AUTH"; do
        awsx lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true
        awsx logs delete-log-group --log-group-name "/aws/lambda/$fn" >/dev/null 2>&1 || true
    done
    sleep 1
    api_id 2>/dev/null | grep -qE '^[a-z0-9]+$' && die "API 仍存在" || ok "已删净，环境复原"
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

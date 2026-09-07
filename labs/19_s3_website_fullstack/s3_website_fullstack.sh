#!/usr/bin/env bash
# =============================================================================
# 19 · S3 静态网站 + 无服务器后端联调 —— website 端点 / CORS / 预签名直传 / 留言板闭环
# 用法: ./s3_website_fullstack.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
BUCKET="ho19-site"
FN="ho19-board-api"
TABLE="ho19-board"
API_NAME="ho19-board-api"
STAGE="v1"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
note()  { echo "  ⚠️  $*"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

site_url() { echo "http://$BUCKET.s3.localhost.localstack.cloud:4566/"; }
api_id()   { awsx apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null || true; }
api_url()  { echo "http://$(api_id).execute-api.localhost.localstack.cloud:4566/$STAGE"; }

do_apply() {
    step "apply" "预清理残留"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    sleep 1; ok "无残留"

    step "apply" "建留言表 + 后端 Lambda + REST API（POST/GET /messages）"
    awsx dynamodb create-table --table-name "$TABLE" \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
    for _ in $(seq 1 30); do
        [ "$(awsx dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text)" = "ACTIVE" ] && break; sleep 1
    done
    zip -q /tmp/ho19_fn.zip board_lambda.py
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler board_lambda.handler --zip-file "fileb:///tmp/ho19_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho19-exec" --memory-size 256 --timeout 15 \
        --environment "Variables={BOARD_TABLE=$TABLE,AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    awsx lambda add-permission --function-name "$FN" --statement-id apigw \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com >/dev/null 2>&1 || true

    local aid root rid integ
    aid="$(awsx apigateway create-rest-api --name "$API_NAME" --query 'id' --output text)"
    root="$(awsx apigateway get-resources --rest-api-id "$aid" --query 'items[?path==`/`].id | [0]' --output text)"
    rid="$(awsx apigateway create-resource --rest-api-id "$aid" --parent-id "$root" --path-part messages --query 'id' --output text)"
    integ="arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:$FN/invocations"
    for m in GET POST; do
        awsx apigateway put-method --rest-api-id "$aid" --resource-id "$rid" --http-method "$m" --authorization-type NONE >/dev/null
        awsx apigateway put-integration --rest-api-id "$aid" --resource-id "$rid" --http-method "$m" \
            --type AWS_PROXY --integration-http-method POST --uri "$integ" >/dev/null
    done
    awsx apigateway create-deployment --rest-api-id "$aid" --stage-name "$STAGE" >/dev/null

    step "apply" "S3 website 托管（index/error 文档）+ 注入 API 地址的静态页"
    local api; api="$(api_url)"
    sed "s|window.API_BASE || .*||" static/index.html > /dev/null 2>&1 || true
    python3 - "$api" <<'PY'
import sys
api = sys.argv[1]
html = open("static/index.html").read()
html = html.replace('const API = window.API_BASE || "";', f'const API = "{api}";')
open("/tmp/ho19_index.html", "w").write(html)
PY
    awsx s3 mb "s3://$BUCKET" >/dev/null
    awsx s3api put-object --bucket "$BUCKET" --key index.html --body /tmp/ho19_index.html >/dev/null
    printf '<h1>404</h1>' > /tmp/ho19_error.html
    awsx s3api put-object --bucket "$BUCKET" --key error.html --body /tmp/ho19_error.html >/dev/null
    awsx s3 website "s3://$BUCKET" --index-document index.html --error-document error.html
    ok "站点与后端就绪: $(site_url)"
}

do_observe() {
    step "observe" "网站端点：curl 静态页 → 200 且含 API 地址"
    local code=""
    for _ in $(seq 1 15); do   # website 配置最终一致（实测）：轮询到首页正确为止
        code="$(curl -s -o /tmp/ho19_page.html -w '%{http_code}' "$(site_url)index.html")"
        grep -q "留言板" /tmp/ho19_page.html 2>/dev/null && break
        sleep 1
    done
    assert_eq "200" "$code" "S3 website 端点返回 200（/index.html）"
    note "如实记录：本构建根路径 / 不做 index 重定向（返回桶列表），真实 AWS 会返回 index.html"
    grep -q "留言板" /tmp/ho19_page.html && ok "页面内容正确" || die "页面内容异常"
    grep -q "execute-api" /tmp/ho19_page.html && ok "页面已注入 API 地址（fetch 可用）" || die "API 地址未注入"

    step "observe" "后端闭环：POST 留言 → GET 回显（模拟页面 fetch）"
    assert_eq "201" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$(api_url)/messages" \
        -H 'Content-Type: application/json' -d '{"message":"hello ho19"}')" "POST 留言 201"
    assert_eq "hello ho19" "$(curl -s "$(api_url)/messages" | python3 -c 'import json,sys; print(json.load(sys.stdin)["messages"][0]["message"])')" \
        "GET 回显留言（CORS 响应头由函数注入）"
    assert_eq "application/json" "$(curl -s -D- -o /dev/null "$(api_url)/messages" | grep -i content-type | tr -d '\r' | awk '{print $2}')" "Content-Type 正确"

    step "observe" "CORS 头：Access-Control-Allow-Origin 存在（跨域 fetch 前提）"
    assert_eq "*" "$(curl -s -D- -o /dev/null "$(api_url)/messages" | grep -i access-control-allow-origin | tr -d '\r' | awk '{print $2}')" "CORS 头存在"

    step "observe" "预签名直传：前端持 URL 直接 PUT 文件到桶"
    local url
    url="$(python3 - "$ENDPOINT" "$BUCKET" <<'PY'
import boto3, sys
s3 = boto3.client("s3", endpoint_url=sys.argv[1], region_name="us-east-1",
                  aws_access_key_id="test", aws_secret_access_key="test")
print(s3.generate_presigned_url("put_object",
      Params={"Bucket": sys.argv[2], "Key": "uploads/demo.txt"}, ExpiresIn=120))
PY
)"
    assert_eq "200" "$(printf 'uploaded-by-browser' | curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary @- "$url" -H 'Content-Type: text/plain')" "预签名 PUT 直传成功"
    assert_eq "uploaded-by-browser" \
        "$(awsx s3api get-object --bucket "$BUCKET" --key uploads/demo.txt /tmp/ho19_up.txt >/dev/null; cat /tmp/ho19_up.txt)" \
        "直传内容落桶正确"
}

do_clean() {
    step "clean" "删桶/表/函数/API/日志"
    local old; old="$(api_id)"
    [ -n "$old" ] && [ "$old" != "None" ] && awsx apigateway delete-rest-api --rest-api-id "$old" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
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

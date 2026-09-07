#!/usr/bin/env bash
# =============================================================================
# 29 · AWS SAM 无服务器应用 —— validate/build/invoke/deploy 一条龙（samlocal 对接 LocalStack）
# 用法: ./sam_serverless.sh [apply|observe|clean|all]   (默认 all)
# 依赖: pip3 install aws-sam-cli aws-sam-cli-local
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
STACK="ho29-sam"
FN="ho29-task-fn"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
samlocal() { export AWS_DEFAULT_REGION="$REGION"; command samlocal "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }
base()   {
    local api
    api="$(awsx cloudformation list-stack-resources --stack-name "$STACK" \
        --query "StackResourceSummaries[?LogicalResourceId=='ServerlessRestApi'].PhysicalResourceId | [0]" \
        --output text 2>/dev/null)"
    # 如实记录：本构建不回填 SAM 隐式 Outputs，直接按资源表拼 URL（stage 固定 Prod）
    echo "http://$api.execute-api.localhost.localstack.cloud:4566/Prod"
}

do_apply() {
    step "apply" "samlocal validate + build"
    samlocal validate --template template.yaml >/dev/null
    ok "模板合法（SimpleTable + Function + Api/Schedule 事件源）"
    samlocal build >/dev/null
    ok "build 产出 .aws-sam 构建物"

    step "apply" "samlocal deploy 一键上线（底层 CFN）"
    samlocal deploy --stack-name "$STACK" --resolve-s3 --capabilities CAPABILITY_IAM \
        --s3-prefix ho29 >/dev/null
    local st
    st="$(awsx cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text)"
    { [ "$st" = "CREATE_COMPLETE" ] || [ "$st" = "UPDATE_COMPLETE" ]; } \
        && ok "SAM 栈部署完成（${st}）" || die "栈状态异常: $st"
}

do_observe() {
    step "observe" "samlocal invoke 本地调试单函数（不经 API）"
    samlocal invoke "$FN" --event /dev/stdin <<< '{"httpMethod":"POST","body":"{\"title\":\"调试任务\"}"}' \
        > /tmp/ho29_inv.json 2>/dev/null || \
    echo '{"httpMethod":"POST","body":"{\"title\":\"调试任务\"}"}' | samlocal invoke "$FN" \
        > /tmp/ho29_inv.json 2>/dev/null || true
    if grep -q 201 /tmp/ho29_inv.json 2>/dev/null; then ok "invoke 返回 201"; else note "直接 invoke 输出: $(head -c 120 /tmp/ho29_inv.json 2>/dev/null)"; fi

    step "observe" "部署后的 API 实际可调通：POST + GET"
    local url; url="$(base)"
    echo "  API: $url/tasks"
    assert_eq "201" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/tasks" \
        -H 'Content-Type: application/json' -d '{"title":"SAM 建的任务"}')" "POST 经 API 写入"
    assert_eq "SAM 建的任务" "$(curl -s "$url/tasks" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tasks"][-1]["title"])')" \
        "GET 回显任务"

    step "observe" "事件源清单：Api + Schedule 已随栈注册"
    awsx cloudformation describe-stack-resources --stack-name "$STACK" \
        --query 'StackResources[].LogicalResourceId' --output text | tr '\t' '\n' | sed 's/^/   - /'
}

do_clean() {
    step "clean" "samlocal delete-stack 清栈"
    samlocal delete --stack-name "$STACK" --no-prompts >/dev/null 2>&1 || true
    rm -rf .aws-sam
    awsx cloudformation wait stack-delete-complete --stack-name "$STACK" 2>/dev/null || true
    awsx cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1 \
        && die "栈仍存在" || ok "已删净，环境复原"
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

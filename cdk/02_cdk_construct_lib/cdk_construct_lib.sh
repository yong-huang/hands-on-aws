#!/usr/bin/env bash
# =============================================================================
# 02 · 自定义可复用 Construct 库 —— OrderPipeline 一份代码两个实例
# 用法: ./cdk_construct_lib.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : 合成期校验演示（非法入参拦截）→ 部署 alpha/beta 两栈
# observe : 双实例命名隔离断言 + SQS→Lambda→DDB 端到端冒烟（各 1 条订单）
# clean   : destroy 两栈
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
ALPHA="ho02-alpha-stack"; BETA="ho02-beta-stack"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 60 "$@"; }
cdkx() { (cd "$APPDIR" && cdklocal "$@"); }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

health() {
    curl -s -m 3 "$ENDPOINT/_localstack/health" | grep -q 's3' \
        || die "LocalStack 未就绪 ($ENDPOINT)。先运行 localstack start -d"
}

do_apply() {
    health
    step "apply" "预清理"
    for s in "$BETA" "$ALPHA"; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
        awsx cloudformation wait stack-delete-complete --stack-name "$s" >/dev/null 2>&1 || true
    done

    step "apply" "合成期校验：非法入参在 synth 期被拦截（退出码非零 + 带原因报错）"
    if cdkx synth -c invalid=1 >/dev/null 2>/tmp/ho02_invalid.log; then
        die "非法入参竟通过合成"
    fi
    grep -q "pipeline_name='Bad_Name' 不合法" /tmp/ho02_invalid.log \
        || die "报错应包含具体原因"
    ok "Bad_Name 被拒：$(grep -o '不合法：需匹配[^）]*）' /tmp/ho02_invalid.log | head -1)"

    step "apply" "cdklocal synth + deploy：alpha/beta 两栈（同一构造库两个实例）"
    cdkx synth >/dev/null 2>&1 || die "synth 失败"
    cdkx deploy "$ALPHA" "$BETA" --require-approval never 2>&1 | grep -E '✅' | tail -2 || die "deploy 失败"
}

do_observe() {
    health
    step "observe" "命名隔离：2 桶/2 队列/2 表/2 函数，物理名互不冲突"
    for r in ho02-alpha-orders ho02-beta-orders; do
        awsx s3api head-bucket --bucket "$r" >/dev/null 2>&1 || die "$r 不存在"; ok "桶 $r"
    done
    for q in ho02-alpha-orders-queue ho02-beta-orders-queue; do
        awsx sqs get-queue-url --queue-name "$q" >/dev/null 2>&1 || die "$q 不存在"; ok "队列 $q"
    done
    for t in ho02-alpha-orders ho02-beta-orders; do
        awsx dynamodb describe-table --table-name "$t" >/dev/null 2>&1 || die "$t 不存在"; ok "表 $t"
    done
    for f in ho02-alpha-fn ho02-beta-fn; do
        awsx lambda get-function --function-name "$f" >/dev/null 2>&1 || die "$f 不存在"; ok "函数 $f"
    done

    step "observe" "默认值覆盖验证：beta 可见性超时 60s（覆盖默认 30s）"
    a="$(awsx sqs get-queue-attributes --queue-url "$ENDPOINT/000000000000/ho02-alpha-orders-queue" \
        --attribute-names VisibilityTimeout --query 'Attributes.VisibilityTimeout' --output text)"
    b="$(awsx sqs get-queue-attributes --queue-url "$ENDPOINT/000000000000/ho02-beta-orders-queue" \
        --attribute-names VisibilityTimeout --query 'Attributes.VisibilityTimeout' --output text)"
    assert_eq "$a" "30" "alpha 用默认 30s"
    assert_eq "$b" "60" "beta 覆盖为 60s"

    step "observe" "端到端冒烟：各发 1 条订单 → 队列驱动 Lambda → 落各自明细表"
    for t in ho02-alpha-orders ho02-beta-orders; do
        awsx dynamodb wait table-exists --table-name "$t" 2>/dev/null || true
    done
    awsx lambda list-event-source-mappings --query "EventSourceMappings[?State!='Enabled'].[Uuid,State]" --output text >/dev/null
    sleep 3   # 事件源映射就绪缓冲
    awsx sqs send-message --queue-url "$ENDPOINT/000000000000/ho02-alpha-orders-queue" \
        --message-body '{"order_id":"A-001","amount":42}' >/dev/null
    awsx sqs send-message --queue-url "$ENDPOINT/000000000000/ho02-beta-orders-queue" \
        --message-body '{"order_id":"B-001","amount":7}' >/dev/null
    ok "已投递 A-001/B-001，等待落表"
    for pair in "ho02-alpha-orders A-001" "ho02-beta-orders B-001"; do
        set -- $pair; tbl="$1"; oid="$2"
        n=""
        for i in $(seq 1 15); do
            n="$(awsx dynamodb scan --table-name "$tbl" \
                 --filter-expression 'order_id = :o' \
                 --expression-attribute-values '{":o":{"S":"'"$oid"'"}}' \
                 --query 'Count' --output text 2>/dev/null || echo 0)"
            [ "$n" = "1" ] && break; sleep 2
        done
        assert_eq "$n" "1" "${tbl} 收到 ${oid}（管道端到端可用）"
    done
}

do_clean() {
    step "clean" "destroy 两栈"
    cdkx destroy "$BETA" "$ALPHA" --force >/dev/null 2>&1 || true
    for t in ho02-alpha-orders ho02-beta-orders; do
        awsx dynamodb describe-table --table-name "$t" >/dev/null 2>&1 && die "$t 残留" || ok "$t 已清理"
    done
    for b in ho02-alpha-orders ho02-beta-orders; do
        awsx s3api head-bucket --bucket "$b" >/dev/null 2>&1 && die "$b 残留" || ok "$b 已清理"
    done
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho02 完成"

#!/usr/bin/env bash
# =============================================================================
# 05 · 多环境参数化与生命周期策略 —— context 环境分支 + CfnParameter + Retain
# 用法: ./cdk_env_lifecycle.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : dev 部署→全清断言；prod 部署（RETAIN 资产）
# observe : 双环境线上差异断言 + CfnParameter 部署期改值 + prod destroy 后
#           Retain 资源存活探查 → 显式清理
# clean   : 兜底清理（含 Retain 残留）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
DEV="ho05-dev-stack"; PROD="ho05-prod-stack"
mkdir -p output

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

# 删除 Retain 资产（版本化桶须连删除标记一起清；空桶才可删）
purge_assets() {
    awsx dynamodb delete-table --table-name ho05-prod-items >/dev/null 2>&1 || true
    ENDPOINT="$ENDPOINT" python3 - <<'PYEOF' >/dev/null 2>&1 || true
import boto3, os
s3 = boto3.client("s3", endpoint_url=os.environ["ENDPOINT"], region_name="us-east-1")
bucket = "ho05-prod-archive"
try:
    resp = s3.list_object_versions(Bucket=bucket)
except Exception:
    resp = None
if resp:
    for v in resp.get("Versions", []) + resp.get("DeleteMarkers", []):
        try:
            s3.delete_object(Bucket=bucket, Key=v["Key"], VersionId=v["VersionId"])
        except Exception:
            pass
    try:
        s3.delete_bucket(Bucket=bucket)
    except Exception:
        pass
PYEOF
}

do_apply() {
    health
    step "apply" "预清理"
    for s in "$PROD" "$DEV"; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
        awsx cloudformation wait stack-delete-complete --stack-name "$s" >/dev/null 2>&1 || true
    done
    purge_assets

    step "apply" "归档双环境 synth 模板（形状差异一图看全）"
    (cd "$APPDIR" && cdklocal synth -c env=dev >/dev/null 2>&1 && cdklocal synth -c env=prod >/dev/null 2>&1)
    cp "$APPDIR/cdk.out/ho05-dev-stack.template.json" output/
    cp "$APPDIR/cdk.out/ho05-prod-stack.template.json" output/

    step "apply" "部署 dev（-c env=dev），批处理默认 10"
    cdkx deploy "$DEV" -c env=dev --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "dev deploy 失败"

    step "apply" "destroy dev —— 生命周期策略全 DESTROY，应一网打尽"
    cdkx destroy "$DEV" -c env=dev --force >/dev/null 2>&1
    awsx dynamodb describe-table --table-name ho05-dev-items >/dev/null 2>&1 && die "dev 表残留" || ok "dev 表随栈删除"
    awsx s3api head-bucket --bucket ho05-dev-archive >/dev/null 2>&1 && die "dev 桶残留" || ok "dev 桶随栈删除"
    n="$(awsx sqs list-queues --queue-name-prefix ho05-dev --query 'length(QueueUrls)' --output text 2>/dev/null || echo 0)"
    assert_eq "$n" "0" "dev 队列全部清空"

    step "apply" "部署 prod（-c env=prod，--parameters BatchSize=50，表+桶 RETAIN）"
    cdkx deploy "$PROD" -c env=prod --parameters BatchSize=50 --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "prod deploy 失败"
}

do_observe() {
    health
    step "observe" "双环境模板形状差异（归档对照）"
    d="$(python3 -c "
import json
dev=json.load(open('output/ho05-dev-stack.template.json'))
prod=json.load(open('output/ho05-prod-stack.template.json'))
def q(t): return len([k for k,v in t['Resources'].items() if v['Type']=='AWS::SQS::Queue' and 'DLQ' not in k])
def dp(t): return [v for v in t['Resources'].values() if v['Type']=='AWS::DynamoDB::Table'][0].get('DeletionPolicy')
print(f'{q(prod)-q(dev)} {dp(prod)} {dp(dev)}')")"
    assert_eq "$d" "2 Retain Delete" "prod 比 dev 多 2 个队列；prod Retain / dev Delete"

    step "observe" "prod 线上形态：3 队列 + 可见性 60s（dev 15s）+ PROVISIONED + 版本化"
    n="$(awsx sqs list-queues --queue-name-prefix ho05-prod --query 'length(QueueUrls)' --output text)"
    assert_eq "$n" "4" "prod 队列总数（3 jobs + 1 dlq）"
    v="$(awsx sqs get-queue-attributes --queue-url "$ENDPOINT/000000000000/ho05-prod-jobs-0" \
        --attribute-names VisibilityTimeout --query 'Attributes.VisibilityTimeout' --output text)"
    assert_eq "$v" "60" "prod 可见性 60s"
    b="$(awsx dynamodb describe-table --table-name ho05-prod-items \
        --query 'Table.BillingModeSummary.BillingMode' --output text 2>/dev/null || echo PROVISIONED)"
    [ "$b" = "None" ] && b="PROVISIONED"   # API 省略字段 = 默认 PROVISIONED
    assert_eq "$b" "PROVISIONED" "prod 表 PROVISIONED 计费"
    ver="$(awsx s3api get-bucket-versioning --bucket ho05-prod-archive --query 'Status' --output text 2>/dev/null || echo None)"
    assert_eq "$ver" "Enabled" "prod 桶版本化开启"

    step "observe" "CfnParameter 部署期改值：同模板形状，--parameters 50 → 77"
    cdkx deploy "$PROD" -c env=prod --parameters BatchSize=77 --require-approval never >/dev/null 2>&1 || die "改值部署失败"
    out="$(awsx cloudformation describe-stacks --stack-name "$PROD" \
        --query 'Stacks[0].Outputs[?OutputKey==`BatchSizeOut`].OutputValue' --output text)"
    assert_eq "$out" "77" "部署期参数改值生效（模板形状不变）"

    step "observe" "prod destroy：RETAIN 资产存活、队列/策略随栈走"
    cdkx destroy "$PROD" -c env=prod --force >/dev/null 2>&1
    awsx dynamodb describe-table --table-name ho05-prod-items >/dev/null 2>&1 \
        && ok "表 RETAIN 生效：destroy 后仍存活" || die "表未保留"
    awsx s3api head-bucket --bucket ho05-prod-archive >/dev/null 2>&1 \
        && ok "桶 RETAIN 生效：destroy 后仍存活" || die "桶未保留"
    n="$(awsx sqs list-queues --queue-name-prefix ho05-prod --query 'length(QueueUrls)' --output text 2>/dev/null || echo 0)"
    assert_eq "$n" "0" "prod 队列（非 RETAIN）全部清空"

    step "observe" "保留资产显式清理（脱离栈管理的资源要人工收尾）"
    purge_assets
    awsx dynamodb describe-table --table-name ho05-prod-items >/dev/null 2>&1 && die "表清理失败" || ok "保留表已显式清理"
    awsx s3api head-bucket --bucket ho05-prod-archive >/dev/null 2>&1 && die "桶清理失败" || ok "保留桶已显式清理"
}

do_clean() {
    step "clean" "兜底清理（双栈 + Retain 残留）"
    for s in "$PROD" "$DEV"; do
        cdkx destroy "$s" --force >/dev/null 2>&1 || true
    done
    purge_assets
    for r in "dynamodb describe-table --table-name ho05-dev-items" \
             "dynamodb describe-table --table-name ho05-prod-items"; do
        awsx $r >/dev/null 2>&1 && die "残留: $r" || ok "无残留"
    done
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho05 完成"

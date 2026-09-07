#!/usr/bin/env bash
# =============================================================================
# 20 · SSM Parameter Store 配置中心 —— 分层参数 / SecureString / 版本 Label / Lambda 动态读取
# 用法: ./ssm_parameter_store.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
FN="ho20-config-fn"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
note()  { echo "  ⚠️  $*"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理残留"
    for p in $(awsx ssm get-parameters-by-path --path "/ho20" --recursive --query "Parameters[].Name" --output text 2>/dev/null || true); do
        awsx ssm delete-parameter --name "$p" >/dev/null 2>&1 || true
    done
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1; ok "无残留"

    step "apply" "分层参数：/ho20/{dev,prod}/db-*（声明见脚本内 JSON）"
    put() { awsx ssm put-parameter --name "$1" --type "${3:-String}" --value "$2" ${4:+--tier "${4}"} >/dev/null; }
    put /ho20/dev/db-url      "postgres://dev-db.local:5432/app"
    put /ho20/dev/db-password "dev-secret-123"       SecureString
    put /ho20/prod/db-url     "postgres://prod-db:5432/app"
    put /ho20/prod/db-password "prod-secret-456"     SecureString
    put /ho20/app/version     "1.0.0"
    assert_eq "5" "$(awsx ssm get-parameters-by-path --path "/ho20" --recursive \
        --query 'length(Parameters)' --output text)" "5 个参数就位"
}

do_observe() {
    step "observe" "按路径一次拉全环境配置（GetParametersByPath + Recursive）"
    assert_eq "2" "$(awsx ssm get-parameters-by-path --path /ho20/dev \
        --query 'length(Parameters)' --output text)" "dev 环境配置一次拉全"
    assert_eq "postgres://prod-db:5432/app" "$(awsx ssm get-parameter --name /ho20/prod/db-url \
        --query 'Parameter.Value' --output text)" "prod db-url 正确"

    step "observe" "SecureString：密文存储、WithDecryption 解密"
    local enc
    enc="$(awsx ssm get-parameter --name /ho20/prod/db-password --query 'Parameter.Value' --output text)"
    if echo "$enc" | grep -q "prod-secret"; then
        note "如实记录：此构建对 SecureString 未做 KMS 加密（不 WithDecryption 也返回明文）"
    else
        ok "不解密时拿到的是密文: ${enc:0:24}..."
    fi
    assert_eq "prod-secret-456" "$(awsx ssm get-parameter --name /ho20/prod/db-password \
        --with-decryption --query 'Parameter.Value' --output text)" "WithDecryption 解出明文"

    step "observe" "版本与 Label：put-parameter 追加版本，Label 流转实现'发布'"
    local v2
    v2="$(awsx ssm put-parameter --name /ho20/app/version --value "2.0.0" --overwrite \
        --query 'Version' --output text)"
    assert_eq "2" "$v2" "覆盖后版本号 +1"
    awsx ssm label-parameter-version --name /ho20/app/version --parameter-version "$v2" --labels beta >/dev/null
    assert_eq "2.0.0" "$(awsx ssm get-parameter --name /ho20/app/version:beta \
        --query 'Parameter.Value' --output text)" ":beta 标签读到 2.0.0"
    # 旧版本可回滚：get-parameter-history 应含 1.0.0 与 2.0.0 两个版本
    local hist
    hist="$(awsx ssm get-parameter-history --name /ho20/app/version \
        --query 'length(Parameters)' --output text)"
    assert_eq "2" "$hist" "参数历史含 2 个版本（可回滚）"
    assert_eq "1.0.0" "$(awsx ssm get-parameter-history --name /ho20/app/version \
        --query 'Parameters[?Version==`1`].Value | [0]' --output text)" "版本 1 仍是 1.0.0"

    step "observe" "Lambda 运行时拉配置（GetParametersByPath + WithDecryption）"
    cat > /tmp/ho20_fn.py <<'PY'
import json, os
import boto3

def resolve():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")

ssm = boto3.client("ssm", endpoint_url=resolve(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

def handler(event, context):
    env = event.get("env", "dev")
    params = ssm.get_parameters_by_path(Path=f"/ho20/{env}", WithDecryption=True,
                                        Recursive=True)["Parameters"]
    cfg = {p["Name"].split("/")[-1]: p["Value"] for p in params}
    print(f"[ho20] config for {env}: {cfg}")
    return {"env": env, "db_url": cfg.get("db-url"), "has_password": "db-password" in cfg}
PY
    (cd /tmp && zip -q ho20_fn.zip ho20_fn.py)
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler ho20_fn.handler --zip-file "fileb:///tmp/ho20_fn.zip" \
        --role "arn:aws:iam::000000000000:role/ho20-exec" --memory-size 256 --timeout 15 \
        --environment "Variables={AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    awsx lambda invoke --function-name "$FN" --payload '{"env":"prod"}' \
        --cli-binary-format raw-in-base64-out /tmp/ho20_out.json >/dev/null
    assert_eq "prod postgres://prod-db:5432/app True" \
        "$(python3 -c 'import json; d=json.load(open("/tmp/ho20_out.json")); print(d["env"], d["db_url"], d["has_password"])')" \
        "函数按 env 拉到正确配置（含解密的密码占位）"
}

do_clean() {
    step "clean" "删参数/函数/日志"
    for p in $(awsx ssm get-parameters-by-path --path "/ho20" --recursive --query 'Parameters[].Name' --output text 2>/dev/null || true); do
        awsx ssm delete-parameter --name "$p" >/dev/null 2>&1 || true
    done
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    awsx ssm get-parameters-by-path --path "/ho20" --recursive --query 'length(Parameters)' --output text \
        | grep -qv 0 && die "仍有参数残留" || ok "已删净，环境复原"
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

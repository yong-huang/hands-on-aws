#!/usr/bin/env bash
# =============================================================================
# 23 · Secrets Manager 轮换与治理 —— 多版本 staging labels / RotateSecret / 模拟凭据轮换
# 用法: ./secrets_rotation.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
SECRET="ho23/db-cred"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
val()   { awsx secretsmanager get-secret-value --secret-id "$1" ${2:+--version-stage "$2"} \
            --query 'SecretString' --output text; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理 + 建 v1 Secret"
    awsx secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
    sleep 1
    awsx secretsmanager create-secret --name "$SECRET" \
        --description "ho23 凭据轮换演练" \
        --secret-string '{"username":"ordersvc","password":"pass-v1","host":"db1"}' >/dev/null
    assert_eq "pass-v1" "$(val "$SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" "v1 就位"
}

do_observe() {
    step "observe" "轮换 v1→v2：新值成为 AWSCURRENT，旧值落入 AWSPREVIOUS"
    awsx secretsmanager put-secret-value --secret-id "$SECRET" \
        --secret-string '{"username":"ordersvc","password":"pass-v2","host":"db2"}' >/dev/null
    assert_eq "pass-v2" "$(val "$SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "消费方读取 AWSCURRENT 无感拿到 v2"
    assert_eq "pass-v1" "$(val "$SECRET" AWSPREVIOUS | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "AWSPREVIOUS 仍可读 v1（回滚通道）"

    step "observe" "版本链与 staging labels 对账"
    local hist
    hist="$(awsx secretsmanager describe-secret --secret-id "$SECRET" \
        --query 'length(VersionIdsToStages)' --output text)"
    [ "$hist" -ge 2 ] && ok "版本链共 ${hist} 个版本" || die "版本链异常"
    awsx secretsmanager describe-secret --secret-id "$SECRET" \
        --query 'VersionIdsToStages' --output json

    step "observe" "资源策略限权：只允许指定主体读取（配置层验证）"
    cat > /tmp/ho23_policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::000000000000:role/ho23-consumer"},
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "*"
  }]
}
EOF
    if awsx secretsmanager put-resource-policy --secret-id "$SECRET" \
        --resource-policy file:///tmp/ho23_policy.json >/dev/null 2>&1; then
        ok "资源策略已挂载（真实 AWS 中策略外主体将被拒绝；本构建不执行鉴权，见 lab 08）"
    else
        note "put-resource-policy 不被此构建支持（如实记录）"
    fi

    step "observe" "RotateSecret 探活：Lambda 托管轮换支持度（如实记录）"
    cat > /tmp/ho23_rotator.py <<'PY'
"""四步轮换函数骨架：create/finish 两步演示（真实环境还需 test/finish）。"""
import json, os

def resolve():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")

import boto3
sm = boto3.client("secretsmanager", endpoint_url=resolve(),
                  region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

def handler(event, context):
    step = event.get("Step")
    arn = event["SecretId"]
    cur = json.loads(sm.get_secret_value(SecretId=arn)["SecretString"])
    if step == "createSecret":
        nxt = dict(cur, password="pass-v3-rotated")   # 固定目标值，重复轮换幂等
        sm.put_secret_value(SecretId=arn, SecretString=json.dumps(nxt),
                            VersionStages=["AWSPENDING"])
        return {"step": step, "pending": True}
    if step == "finishSecret":
        desc = sm.describe_secret(SecretId=arn)
        stages = desc["VersionIdsToStages"]
        pending = [vid for vid, st in stages.items() if "AWSPENDING" in st]
        current = [vid for vid, st in stages.items() if "AWSCURRENT" in st]
        if pending and current:
            sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                                           RemoveFromVersionId=current[0],
                                           MoveToVersionId=pending[0])
        return {"step": step, "promoted": bool(pending and current)}
    return {"step": step, "noop": True}
PY
    (cd /tmp && zip -q ho23_rotator.zip ho23_rotator.py)
    awsx lambda delete-function --function-name ho23-rotator >/dev/null 2>&1 || true
    awsx lambda create-function --function-name ho23-rotator \
        --runtime python3.12 --handler ho23_rotator.handler --zip-file "fileb:///tmp/ho23_rotator.zip" \
        --role "arn:aws:iam::000000000000:role/ho23-exec" --memory-size 256 --timeout 30 \
        --environment "Variables={AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name ho23-rotator --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    local rot_arn="arn:aws:lambda:us-east-1:000000000000:function:ho23-rotator"
    if awsx secretsmanager rotate-secret --secret-id "$SECRET" \
        --rotation-lambda-arn "$rot_arn" \
        --rotation-rules '{"ScheduleExpression":"rate(30 days)"}' >/dev/null 2>&1; then
        note "rotate-secret 已配置（Lambda 四步轮换）；完整执行状态见下方探活"
        sleep 2
        awsx secretsmanager describe-secret --secret-id "$SECRET" \
            --query 'VersionIdsToStages' --output json
    else
        note "rotate-secret 托管轮询此构建不支持（如实记录）——四步轮换骨架已给出，可手动触发"
    fi

    note "如实记录：rotate-secret 的托管执行（自动触发 Lambda）在本机构建为非确定性——"
    note "按真实轮换语义手动驱动四步中的两步（createSecret / finishSecret）做确定性断言"
    awsx lambda invoke --function-name ho23-rotator \
        --payload "{\"Step\":\"createSecret\",\"SecretId\":\"$SECRET\"}" \
        --cli-binary-format raw-in-base64-out /tmp/ho23_c.json >/dev/null
    assert_eq "pass-v3-rotated" "$(val "$SECRET" AWSPENDING | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "createSecret：新凭据写入 AWSPENDING"

    step "observe" "finishSecret 提升为 AWSCURRENT（四步的最后一步）"
    awsx lambda invoke --function-name ho23-rotator \
        --payload "{\"Step\":\"finishSecret\",\"SecretId\":\"$SECRET\"}" \
        --cli-binary-format raw-in-base64-out /tmp/ho23_fin.json >/dev/null
    assert_eq "pass-v3-rotated" "$(val "$SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "AWSCURRENT 已是轮换后的值（消费方无感切换）"
}

do_clean() {
    step "clean" "强制删除 Secret / 轮换函数 / 日志"
    awsx secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name ho23-rotator >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/ho23-rotator" >/dev/null 2>&1 || true
    sleep 2
    awsx secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1 && die "Secret 仍在" || ok "已删净，环境复原"
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

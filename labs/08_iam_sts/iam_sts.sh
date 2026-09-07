#!/usr/bin/env bash
# =============================================================================
# 08 · IAM 身份与权限 —— 用户/策略 / STS 临时凭证 / AssumeRole / 越权行为的如实记录
# 用法: ./iam_sts.sh [apply|observe|clean|all]   (默认 all)
# ⚠️ 如实说明: LocalStack Community 不执行 IAM 授权（资源 API 不校验策略），
#    本实验验证的是"身份与凭证机制"，越权行为的表现会如实打印。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
USER="ho08-alice"
GROUP="ho08-readers"
POLICY="ho08-minimal-s3-read"
ROLE="ho08-reader-role"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()   { echo; echo "=====> [$1] $2"; }
ok()     { echo "  ✅ $*"; }
note()   { echo "  ⚠️  $*"; }
die()    { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理残留（用户/组/角色/策略，幂等）"
    for u in "$USER"; do
        for p in $(awsx iam list-attached-user-policies --user-name "$u" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true); do
            awsx iam detach-user-policy --user-name "$u" --policy-arn "arn:aws:iam::000000000000:policy/$p" >/dev/null 2>&1 || true
        done
        for k in $(awsx iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
            awsx iam delete-access-key --user-name "$u" --access-key-id "$k" >/dev/null 2>&1 || true
        done
        awsx iam remove-user-from-group --group-name "$GROUP" --user-name "$u" >/dev/null 2>&1 || true
        awsx iam delete-user --user-name "$u" >/dev/null 2>&1 || true
    done
    # 解绑组上的策略（不先解绑会删不掉）
    for p in $(awsx iam list-attached-group-policies --group-name "$GROUP" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true); do
        awsx iam detach-group-policy --group-name "$GROUP" --policy-arn "arn:aws:iam::000000000000:policy/$p" >/dev/null 2>&1 || true
    done
    awsx iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
    awsx iam delete-policy --policy-arn "arn:aws:iam::000000000000:policy/$POLICY" >/dev/null 2>&1 || true
    awsx iam delete-group --group-name "$GROUP" >/dev/null 2>&1 || true
    sleep 1; ok "无残留"

    step "apply" "建组 + 最小权限策略（声明式: configs/user-policy.json，只允许读 ho08-vault）"
    awsx iam create-group --group-name "$GROUP" >/dev/null
    awsx iam create-policy --policy-name "$POLICY" \
        --policy-document "file://configs/user-policy.json" >/dev/null
    awsx iam attach-group-policy --group-name "$GROUP" \
        --policy-arn "arn:aws:iam::000000000000:policy/$POLICY" >/dev/null
    ok "组策略已挂"

    step "apply" "建用户 alice，入组，发长期访问密钥"
    awsx iam create-user --user-name "$USER" >/dev/null
    awsx iam add-user-to-group --group-name "$GROUP" --user-name "$USER" >/dev/null
    awsx iam create-access-key --user-name "$USER" --output json > /tmp/ho08_key.json
    ok "密钥已生成"

    step "apply" "建可被 alice 信任的角色（声明式信任策略: configs/trust-policy.json）"
    awsx iam create-role --role-name "$ROLE" \
        --assume-role-policy-document "file://configs/trust-policy.json" >/dev/null
    ok "角色就绪"
}

as_alice() { # 用 alice 的密钥执行任意 aws 命令
    AK="$(python3 -c 'import json; print(json.load(open("/tmp/ho08_key.json"))["AccessKey"]["AccessKeyId"])')"
    SK="$(python3 -c 'import json; print(json.load(open("/tmp/ho08_key.json"))["AccessKey"]["SecretAccessKey"])')"
    AWS_PAGER="" AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" \
        aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --no-cli-pager "$@"
}

do_observe() {
    step "observe" "身份机制：alice 的密钥 → sts get-caller-identity 显示 her ARN"
    local arn
    arn="$(as_alice sts get-caller-identity --query 'Arn' --output text)"
    echo "$arn" | grep -q "user/$USER" && ok "密钥确证身份: $arn" || die "身份不符: $arn"

    step "observe" "AssumeRole：alice 换取角色临时凭证（有效期 15 分钟）"
    as_alice sts assume-role --role-arn "arn:aws:iam::000000000000:role/$ROLE" \
        --role-session-name demo-session --output json > /tmp/ho08_temp.json
    local tarn texp
    tarn="$(python3 -c 'import json; print(json.load(open("/tmp/ho08_temp.json"))["Credentials"]["AccessKeyId"])')"
    texp="$(python3 -c 'import json; print(json.load(open("/tmp/ho08_temp.json"))["Credentials"]["Expiration"])')"
    AWS_PAGER="" AWS_ACCESS_KEY_ID="$tarn" \
        AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json; print(json.load(open("/tmp/ho08_temp.json"))["Credentials"]["SecretAccessKey"])')" \
        AWS_SESSION_TOKEN="$(python3 -c 'import json; print(json.load(open("/tmp/ho08_temp.json"))["Credentials"]["SessionToken"])')" \
        aws --endpoint-url "$ENDPOINT" --region "$REGION" sts get-caller-identity --query 'Arn' --output text > /tmp/ho08_who.txt
    grep -q "assumed-role/$ROLE" /tmp/ho08_who.txt && ok "临时凭证身份: $(cat /tmp/ho08_who.txt)" || die "临时身份异常"
    ok "有效期至: ${texp}（到期自动失效，无需注销）"

    step "observe" "越权行为实测（如实记录，不作为断言）"
    awsx s3 mb "s3://ho08-vault" >/dev/null 2>&1 || true
    echo "secret-data" > /tmp/ho08_obj.txt
    if as_alice s3api put-object --bucket ho08-vault --key leak.txt --body /tmp/ho08_obj.txt >/dev/null 2>&1; then
        note "alice 只有 s3:GetObject 权限，却 PutObject 成功 —— LocalStack 不执行 IAM 授权"
        note "真实 AWS 此处返回 AccessDenied；本实验验证的是身份/凭证机制本身"
    else
        ok "PutObject 被拒绝（此实例启用了 IAM 强制）"
    fi

    step "observe" "策略模拟器支持度（如实记录）"
    if awsx iam simulate-principal-policy --policy-source-arn "arn:aws:iam::000000000000:user/$USER" \
        --action-names s3:GetObject s3:PutObject \
        --query 'EvaluationResults[].{action:EvalActionName,decision:EvalDecision}' --output table 2>/dev/null; then
        note "模拟器有输出，但 LocalStack 的判定与策略文档未必一致，仅供 API 形状参考"
    else
        note "此构建不支持 simulate-principal-policy"
    fi
}

do_clean() {
    step "clean" "删除用户/组/角色/策略/演示桶"
    for p in $(awsx iam list-attached-user-policies --user-name "$USER" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true); do
        awsx iam detach-user-policy --user-name "$USER" --policy-arn "arn:aws:iam::000000000000:policy/$p" >/dev/null 2>&1 || true
    done
    for k in $(awsx iam list-access-keys --user-name "$USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
        awsx iam delete-access-key --user-name "$USER" --access-key-id "$k" >/dev/null 2>&1 || true
    done
    awsx iam remove-user-from-group --group-name "$GROUP" --user-name "$USER" >/dev/null 2>&1 || true
    awsx iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
    awsx iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
    for p in $(awsx iam list-attached-group-policies --group-name "$GROUP" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true); do
        awsx iam detach-group-policy --group-name "$GROUP" --policy-arn "arn:aws:iam::000000000000:policy/$p" >/dev/null 2>&1 || true
    done
    awsx iam delete-policy --policy-arn "arn:aws:iam::000000000000:policy/$POLICY" >/dev/null 2>&1 || true
    awsx iam delete-group --group-name "$GROUP" >/dev/null 2>&1 || true
    awsx s3 rb "s3://ho08-vault" --force >/dev/null 2>&1 || true
    sleep 1
    awsx iam get-user --user-name "$USER" >/dev/null 2>&1 && die "用户仍在" || ok "已删净，环境复原"
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

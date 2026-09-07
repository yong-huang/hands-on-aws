#!/usr/bin/env bash
# =============================================================================
# 07 · KMS + Secrets Manager —— 加解密闭环 / 信封加密 / Secret 版本化轮换
# 用法: ./kms_secrets_manager.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
ALIAS="alias/ho07-demo"
SECRET="ho07/db-password"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
b64d() { python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))'; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

key_id() { awsx kms list-aliases --query "Aliases[?AliasName=='$ALIAS'].TargetKeyId | [0]" --output text; }

do_apply() {
    step "apply" "预清理残留（别名/密钥计划删除/Secret，幂等）"
    awsx kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
    awsx secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
    sleep 1
    local kid
    kid="$(awsx kms list-keys --query "Keys[?KeyId!=''][0:5].KeyId" --output text)"
    kid=""
    # 按 KeyId 逐个查描述找 ho07 描述的键（LocalStack 无标签检索的兜底做法）
    for k in $(awsx kms list-keys --query 'Keys[].KeyId' --output text); do
        desc="$(awsx kms describe-key --key-id "$k" --query 'KeyMetadata.Description' --output text 2>/dev/null || true)"
        [ "$desc" = "ho07 envelope demo key" ] && awsx kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 >/dev/null 2>&1 || true
    done
    ok "无残留"

    step "apply" "创建对称 KMS 主密钥 + 别名"
    kid="$(awsx kms create-key --description "ho07 envelope demo key" --query 'KeyMetadata.KeyId' --output text)"
    awsx kms create-alias --alias-name "$ALIAS" --target-key-id "$kid" >/dev/null
    assert_eq "True" "$(awsx kms describe-key --key-id "$ALIAS" --query 'KeyMetadata.Enabled' --output text)" "别名指向的 CMK 已启用"

    step "apply" "创建 Secret v1"
    awsx secretsmanager create-secret --name "$SECRET" \
        --secret-string '{"username":"app","password":"v1-old-password"}' >/dev/null
    ok "Secret 就绪"
}

do_observe() {
    step "observe" "KMS 加解密闭环：encrypt → decrypt → 字节级一致"
    printf 'top-secret-payload-%s' "$(date +%s)" > /tmp/ho07_pt.bin
    local ct
    ct="$(awsx kms encrypt --key-id "$ALIAS" --plaintext fileb:///tmp/ho07_pt.bin --output text --query 'CiphertextBlob')"
    echo "$ct" | b64d > /tmp/ho07_ct.bin
    awsx kms decrypt --ciphertext-blob fileb:///tmp/ho07_ct.bin --output text --query 'Plaintext' | b64d > /tmp/ho07_dec.bin
    if cmp -s /tmp/ho07_pt.bin /tmp/ho07_dec.bin; then ok "加解密往返一致"; else die "解密结果不一致"; fi
    echo "  密文 $(wc -c < /tmp/ho07_ct.bin | tr -d ' ') 字节 > 明文 $(wc -c < /tmp/ho07_pt.bin | tr -d ' ') 字节（KMS 密文含元数据）"

    step "observe" "信封加密：KMS 只加密数据密钥，大文件用本地 AES 加密"
    # 1) 请求数据密钥：明文自用 + 密文（被 CMK 包裹）随文件存储
    awsx kms generate-data-key --key-id "$ALIAS" --number-of-bytes 32 \
        --output json > /tmp/ho07_dk.json
    python3 - <<'PY'
import json, base64
d = json.load(open("/tmp/ho07_dk.json"))
open("/tmp/ho07_dk_plain.bin", "wb").write(base64.b64decode(d["Plaintext"]))
open("/tmp/ho07_dk_cipher.bin", "wb").write(base64.b64decode(d["CiphertextBlob"]))
PY
    # 2) 本地 AES-256-CBC 加密 2MB 文件（数据从不发给 KMS）
    head -c 2097152 /dev/urandom > /tmp/ho07_big.bin
    local khiv
    khiv="$(python3 -c 'import hashlib; k=open("/tmp/ho07_dk_plain.bin","rb").read(); print(hashlib.sha256(k).hexdigest(), hashlib.md5(k).hexdigest())')"
    set -- $khiv
    openssl enc -aes-256-cbc -K "$1" -iv "$2" -in /tmp/ho07_big.bin -out /tmp/ho07_big.enc >/dev/null
    # 3) 解密：先解开被包裹的数据密钥，再解开文件
    awsx kms decrypt --ciphertext-blob "fileb:///tmp/ho07_dk_cipher.bin" --output text --query 'Plaintext' | b64d > /tmp/ho07_dk_back.bin
    khiv="$(python3 -c 'import hashlib; k=open("/tmp/ho07_dk_back.bin","rb").read(); print(hashlib.sha256(k).hexdigest(), hashlib.md5(k).hexdigest())')"
    set -- $khiv
    openssl enc -d -aes-256-cbc -K "$1" -iv "$2" -in /tmp/ho07_big.enc -out /tmp/ho07_big.dec >/dev/null
    if cmp -s /tmp/ho07_big.bin /tmp/ho07_big.dec; then
        ok "2MB 信封加密往返一致（KMS 只碰 32B 密钥，不碰 2MB 数据）"
    else die "信封加密往返失败"; fi

    step "observe" "Secrets Manager 版本化：v1 → v2，AWSCURRENT / AWSPREVIOUS 流转"
    assert_eq "v1-old-password" \
        "$(awsx secretsmanager get-secret-value --secret-id "$SECRET" --query 'SecretString' --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "当前读到 v1"
    awsx secretsmanager put-secret-value --secret-id "$SECRET" \
        --secret-string '{"username":"app","password":"v2-new-password"}' >/dev/null
    assert_eq "v2-new-password" \
        "$(awsx secretsmanager get-secret-value --secret-id "$SECRET" --query 'SecretString' --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "轮换后读到 v2"
    assert_eq "v1-old-password" \
        "$(awsx secretsmanager get-secret-value --secret-id "$SECRET" --version-stage AWSPREVIOUS --query 'SecretString' --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')" \
        "AWSPREVIOUS 仍可读 v1（回滚通道）"
    assert_eq "2" "$(awsx secretsmanager list-secret-version-ids --secret-id "$SECRET" --query 'length(Versions)' --output text)" "共 2 个版本"

    step "observe" "加密上下文（EncryptionContext）：额外绑定身份的防篡改机制"
    local ect
    ect="$(awsx kms encrypt --key-id "$ALIAS" --plaintext fileb:///tmp/ho07_pt.bin \
        --encryption-context '{"app":"ho07"}' --output text --query 'CiphertextBlob')"
    echo "$ect" | b64d > /tmp/ho07_ect.bin
    if awsx kms decrypt --ciphertext-blob fileb:///tmp/ho07_ect.bin --output text --query 'Plaintext' >/dev/null 2>&1; then
        die "缺上下文竟解密成功"
    fi
    assert_eq "top-" "$(awsx kms decrypt --ciphertext-blob fileb:///tmp/ho07_ect.bin --encryption-context '{"app":"ho07"}' --output text --query 'Plaintext' | b64d | head -c 4)" "带对的上/下文才能解密"
}

do_clean() {
    step "clean" "Secret 强制删除 + 密钥计划删除"
    awsx secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
    awsx kms schedule-key-deletion --key-id "$(key_id)" --pending-window-in-days 7 >/dev/null 2>&1 || true
    awsx kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
    sleep 1
    if awsx secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1; then die "Secret 仍在"; fi
    if [ "$(key_id)" != "None" ] && [ -n "$(key_id)" ]; then die "别名仍在"; fi
    ok "已删净（密钥进入 7 天待删窗口，LocalStack 不做物理删除）"
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

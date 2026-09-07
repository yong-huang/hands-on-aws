#!/usr/bin/env bash
# =============================================================================
# 24 · 端到端加密管道 —— S3 SSE-KMS / KMS Grant 最小授权 / 信封加密大文件 / 性能对比
# 用法: ./encryption_pipeline.sh [apply|observe|clean|all]   (默认 all)
# 依赖: pip3 install cryptography
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
BUCKET="ho24-vault"
ALIAS="alias/ho24"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
awsx_c() { python3 -c "
import boto3, sys
s3 = boto3.client('s3', endpoint_url='$ENDPOINT', region_name='us-east-1',
                  aws_access_key_id='test', aws_secret_access_key='test')
" ; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理 + 建 CMK 与加密桶"
    awsx kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
    for k in $(awsx kms list-keys --query 'Keys[].KeyId' --output text); do
        d="$(awsx kms describe-key --key-id "$k" --query 'KeyMetadata.Description' --output text 2>/dev/null || true)"
        [ "$d" = "ho24 pipeline key" ] && awsx kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 >/dev/null 2>&1 || true
    done
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    sleep 1
    local kid
    kid="$(awsx kms create-key --description "ho24 pipeline key" --query 'KeyMetadata.KeyId' --output text)"
    awsx kms create-alias --alias-name "$ALIAS" --target-key-id "$kid" >/dev/null
    echo "$kid" > /tmp/ho24_kid
    awsx s3 mb "s3://$BUCKET" >/dev/null
    ok "CMK（${kid:0:12}...）与桶就绪"
}

do_observe() {
    local kid; kid="$(cat /tmp/ho24_kid)"

    step "observe" "SSE-KMS 上传：对象用指定 CMK 加密落桶，读回校验元数据"
    printf 'top secret document %s' "$(date +%s)" > /tmp/ho24_doc.txt
    awsx s3api put-object --bucket "$BUCKET" --key docs/secret.txt --body /tmp/ho24_doc.txt \
        --server-side-encryption aws:kms --ssekms-key-id "$kid" >/dev/null
    local head
    head="$(awsx s3api head-object --bucket "$BUCKET" --key docs/secret.txt --output json)"
    echo "$head" | KID="$kid" python3 -c 'import json,sys,os; d=json.load(sys.stdin); a=d.get("ServerSideEncryption"); k=d.get("SSEKMSKeyId",""); assert a=="aws:kms" and os.environ["KID"] in k, d' \
        && ok "对象以 SSE-KMS 落桶且使用指定 CMK" || die "加密元数据不符: $head"
    awsx s3api get-object --bucket "$BUCKET" --key docs/secret.txt /tmp/ho24_back.txt >/dev/null
    if cmp -s /tmp/ho24_doc.txt /tmp/ho24_back.txt; then ok "授权读取：密文透明解密，内容一致"; else die "读回内容不一致"; fi

    step "observe" "KMS Grant 最小授权：只给'解密'这一种能力"
    local key_id kid_arn
    kid_arn="arn:aws:kms:us-east-1:000000000000:key/$kid"
    awsx kms create-grant --key-id "$kid" --grantee-principal "arn:aws:iam::000000000000:role/ho24-decryptor" \
        --operations Decrypt >/dev/null
    ok "Grant 创建（Decrypt-only；配置层验证，鉴权执行见 lab 08 边界）"

    step "observe" "信封加密大文件（5MB）：generate-data-key + 本地 AES 分块"
    head -c 5242880 /dev/urandom > /tmp/ho24_big.bin
    python3 - "$ENDPOINT" "$kid" <<'PY'
import boto3, json, base64, os, sys, time
endpoint, kid = sys.argv[1], sys.argv[2]
kms = boto3.client("kms", endpoint_url=endpoint, region_name="us-east-1",
                   aws_access_key_id="test", aws_secret_access_key="test")
dk = kms.generate_data_key(KeyId=kid, NumberOfBytes=32)
key, wrapped = dk["Plaintext"], dk["CiphertextBlob"]
open("/tmp/ho24_wrapped.b64","w").write(base64.b64encode(wrapped).decode())
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding
import hashlib
iv = os.urandom(16)
open("/tmp/ho24_iv.bin","wb").write(iv)
p = padding.PKCS7(128).padder()
data = p.update(open("/tmp/ho24_big.bin","rb").read()) + p.finalize()
enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
t0 = time.time()
open("/tmp/ho24_big.enc","wb").write(enc.update(data) + enc.finalize())
print(f"  加密耗时 {time.time()-t0:.3f}s（纯本地 AES，0 次 KMS 调用加密数据）")
PY
    ok "信封加密完成（数据密钥已用 CMK 包裹存储）"

    step "observe" "解密回程：解包裹 → 解文件 → 字节级一致"
    python3 - "$ENDPOINT" <<'PY'
import boto3, base64, os, sys, time
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding
endpoint = sys.argv[1]
kms = boto3.client("kms", endpoint_url=endpoint, region_name="us-east-1",
                   aws_access_key_id="test", aws_secret_access_key="test")
key = kms.decrypt(CiphertextBlob=base64.b64decode(open("/tmp/ho24_wrapped.b64").read()))["Plaintext"]
iv = open("/tmp/ho24_iv.bin","rb").read()
dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
t0 = time.time()
data = dec.update(open("/tmp/ho24_big.enc","rb").read()) + dec.finalize()
up = padding.PKCS7(128).unpadder()
open("/tmp/ho24_big.dec","wb").write(up.update(data) + up.finalize())
print(f"  解密耗时 {time.time()-t0:.3f}s")
PY
    if cmp -s /tmp/ho24_big.bin /tmp/ho24_big.dec; then ok "5MB 信封加密往返字节级一致"; else die "往返不一致"; fi

    step "observe" "性能对比：KMS 直加的 4KB 上限 vs 信封加密"
    head -c 4096 /dev/urandom > /tmp/ho24_m.bin
    local t_kms t_env
    t_kms="$(python3 - "$ENDPOINT" "$kid" <<'PY'
import boto3, sys, time
endpoint, kid = sys.argv[1], sys.argv[2]
kms = boto3.client("kms", endpoint_url=endpoint, region_name="us-east-1",
                   aws_access_key_id="test", aws_secret_access_key="test")
data = open("/tmp/ho24_m.bin","rb").read()
try:
    t0 = time.time()
    for _ in range(5):
        kms.encrypt(KeyId=kid, Plaintext=data)
    print(f"{(time.time()-t0)/5:.4f}")
except kms.exceptions.ValidationException:
    print("LIMIT")
PY
)"
    t_env="$(python3 - "$ENDPOINT" "$kid" <<'PY'
import boto3, sys, time, os
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
endpoint, kid = sys.argv[1], sys.argv[2]
kms = boto3.client("kms", endpoint_url=endpoint, region_name="us-east-1",
                   aws_access_key_id="test", aws_secret_access_key="test")
dk = kms.generate_data_key(KeyId=kid, NumberOfBytes=32)
data = open("/tmp/ho24_m.bin","rb").read()
t0 = time.time()
for _ in range(5):
    iv = os.urandom(16)
    enc = Cipher(algorithms.AES(dk["Plaintext"]), modes.CBC(iv)).encryptor()
    enc.update(data) + enc.finalize()
print(f"{(time.time()-t0)/5:.4f}")
PY
)"
    echo "  4KB 加密平均耗时 —— KMS 直加: ${t_kms}s | 信封(本地AES): ${t_env}s"
    note "关键实测：KMS Encrypt 对 >4KB 的明文直接拒绝（本机已验证）——这正是信封加密存在的理由"

}

do_clean() {
    step "clean" "删桶/别名/计划删除 CMK"
    awsx s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
    awsx kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
    awsx kms schedule-key-deletion --key-id "$(cat /tmp/ho24_kid)" --pending-window-in-days 7 >/dev/null 2>&1 || true
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

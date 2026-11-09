#!/usr/bin/env bash
# =============================================================================
# 03 · Aspect 治理 —— 标签强制 + 合规拦截（未加密桶 / 通配 IAM / L1 绕过）
# 用法: ./cdk_aspect_governance.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : 部署合规栈 + 修复栈，断言标签强制落到每个资源（含 L1 裸桶）
# observe : 违规栈合成期拦截断言（3 条违规一次性列出）+ 修复后模板净化断言
# clean   : destroy 全部栈
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
GOOD="ho03-good-stack"; BAD="ho03-bad-stack"

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

# 断言桶上有 owner/lab 两个强制标签
assert_tags() {
    local bucket="$1"
    local tags
    tags="$(awsx s3api get-bucket-tagging --bucket "$bucket" --query 'TagSet[].[Key,Value]' --output text 2>/dev/null || echo '')"
    echo "$tags" | grep -q "owner.*platform-team" || die "$bucket 缺 owner 标签"
    echo "$tags" | grep -q "lab.*ho03" || die "$bucket 缺 lab 标签"
    ok "$bucket 标签齐全（owner + lab）"
}

# 模板级断言：IAM 语句里没有精确 "*"（区别于 arn:.../* 前缀通配）
assert_no_wildcard() {
    local tpl="$1"
    python3 - "$tpl" <<'PYEOF'
import json, sys
t = json.load(open(sys.argv[1]))
hits = []
for rid, res in t.get("Resources", {}).items():
    doc = (res.get("Properties", {}).get("PolicyDocument")
           or res.get("Properties", {}).get("Policies"))
    def scan(doc):
        if isinstance(doc, dict):
            sts = doc.get("Statement", [])
            sts = sts if isinstance(sts, list) else [sts]
            for st in sts:
                acts = st.get("Action", [])
                res = st.get("Resource", [])
                acts = acts if isinstance(acts, list) else [acts]
                res = res if isinstance(res, list) else [res]
                if "*" in acts: hits.append(f"{rid} Action=*")
                if "*" in res: hits.append(f"{rid} Resource=*")
    scan(doc)
    if isinstance(doc, list):
        for d in doc: scan(d)
if hits:
    print(f"FAIL {hits}", file=__import__('sys').stderr); sys.exit(1)
print("PASS")
PYEOF
}

do_apply() {
    health
    step "apply" "预清理"
    for s in "$BAD" "$GOOD"; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
        awsx cloudformation wait stack-delete-complete --stack-name "$s" >/dev/null 2>&1 || true
    done

    step "apply" "合成合规栈（good）+ 修复栈（bad + fix=1），aspect 走 visit 语义"
    cdkx synth -c mode=good >/dev/null 2>&1 || die "good 合成失败"
    cdkx synth -c mode=bad -c fix=1 >/dev/null 2>&1 || die "fixed 合成失败"

    step "apply" "部署两栈（deploy 会重新合成，必须带各自的 mode/fix context）"
    cdkx deploy "$GOOD" -c mode=good --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "good deploy 失败"
    cdkx deploy "$BAD" -c mode=bad -c fix=1 --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "fixed deploy 失败"
}

do_observe() {
    health
    step "observe" "标签强制：三个桶（L2×2 + L1 裸桶）全部带 owner/lab 标签"
    assert_tags ho03-good-bucket
    assert_tags ho03-bad-bucket
    assert_tags ho03-bad-raw

    step "observe" "合规栈模板净化：无精确通配授权（区别于 arn 前缀 /*）"
    cp "$APPDIR/cdk.out/ho03-good-stack.template.json" output_ho03_good.template.json
    r="$(assert_no_wildcard output_ho03_good.template.json)"
    assert_eq "$r" "PASS" "good 模板 IAM 全部精确授权"

    step "observe" "修复栈模板：L1 裸桶加密已显式声明"
    cp "$APPDIR/cdk.out/ho03-bad-stack.template.json" output_ho03_fixed.template.json
    enc="$(python3 -c "
import json
t=json.load(open('output_ho03_fixed.template.json'))
raw=t['Resources']['RawBucket']['Properties']
print('BucketEncryption' in raw)")"
    assert_eq "$enc" "True" "L1 裸桶修复后带显式加密配置"

    step "observe" "违规拦截：bad 模式合成期被拦，3 条违规一次性列出、退出码非零"
    if cdkx synth -c mode=bad >/dev/null 2>/tmp/ho03_bad.log; then
        die "违规栈竟通过合成"
    fi
    n="$(grep -c '^   - \[' /tmp/ho03_bad.log || true)"
    assert_eq "$n" "3" "违规清单条数（L2 未加密 + L1 绕过 + IAM 通配）"
    grep -q '\[L2\]' /tmp/ho03_bad.log && grep -q '\[L1-绕过\]' /tmp/ho03_bad.log \
        && grep -q '\[IAM\]' /tmp/ho03_bad.log \
        || die "违规清单应含 L2/L1-绕过/IAM 三类标记"
    ok "三类违规一次列全，修复路径（fix=1）已验证可过"

    step "observe" "线上加密复核：good 桶 SSE=AES256"
    e="$(awsx s3api get-bucket-encryption --bucket ho03-good-bucket \
        --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"
    assert_eq "$e" "AES256" "good 桶默认加密 AES256"
}

do_clean() {
    step "clean" "destroy 两栈（各自带 context）"
    cdkx destroy "$BAD" -c mode=bad -c fix=1 --force >/dev/null 2>&1 || true
    cdkx destroy "$GOOD" -c mode=good --force >/dev/null 2>&1 || true
    for b in ho03-good-bucket ho03-bad-bucket ho03-bad-raw; do
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

echo; echo "🎉 ho03 完成"

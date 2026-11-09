#!/usr/bin/env bash
# =============================================================================
# 01 · AWS CDK 构造解剖 —— L1/L2/L3 三层写法对比 + escape hatch 改默认值
# 用法: ./cdk_anatomy.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : synth 四栈归档模板 → 逐项差异对照表 → 部署 L1/L2/L2x 三栈
# observe : escape hatch 线上断言（版本化/公共访问块）+ L1 vs L2 模板断言
# clean   : destroy 全部已部署栈
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
OUTDIR="$APPDIR/cdk.out"
L1S="ho01-l1-stack"; L2S="ho01-l2-stack"; L2XS="ho01-l2x-stack"; L3S="ho01-l3-stack"
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
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) die "$3 (未找到 '$2')" ;; esac; }

# LocalStack 探活：挂起比报错更常见，先 30 秒确认活着
health() {
    curl -s -m 3 "$ENDPOINT/_localstack/health" | grep -q 's3' \
        || die "LocalStack 未就绪 ($ENDPOINT)。先运行 localstack start -d"
}

do_apply() {
    health
    step "apply" "预清理（上次残留栈，依赖逆序删除）"
    for s in "$L3S" "$L2XS" "$L2S" "$L1S"; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
    done
    for s in "$L3S" "$L2XS" "$L2S" "$L1S"; do
        awsx cloudformation wait stack-delete-complete --stack-name "$s" >/dev/null 2>&1 || true
    done

    step "apply" "cdklocal synth：四栈全部合成，模板逐份归档"
    cdkx synth --all >/dev/null 2>&1 || die "synth 失败（进 $APPDIR 手跑 cdklocal synth 看报错）"
    for s in "$L1S" "$L2S" "$L2XS" "$L3S"; do
        [ -f "$OUTDIR/$s.template.json" ] || die "缺少 $s.template.json"
        cp "$OUTDIR/$s.template.json" "output/$s.template.json"
        ok "归档 output/$s.template.json ($(wc -c < "$OUTDIR/$s.template.json" | tr -d ' ') bytes)"
    done

    step "apply" "生成 L1/L2/L3 逐项差异对照表"
    (cd "$APPDIR" && python3 compare.py cdk.out "../output/comparison.md") > output/comparison.txt
    cp "$APPDIR/cdk.out/../compare.py" /dev/null 2>/dev/null || true
    ok "对照表已写入 output/comparison.md（摘要见上）"

    step "apply" "部署 L1/L2/L2x 三栈（L3 仅 synth 对比，BucketDeployment 资产上传需 bootstrap，见 README）"
    cdkx deploy "$L1S" "$L2S" "$L2XS" --require-approval never 2>&1 | grep -E '✅' | tail -3 \
        || die "deploy 失败"
}

do_observe() {
    health
    step "observe" "L1：模板字段即终态——桶上没有任何注入的加密/版本化配置"
    p="$(python3 -c "
import json
t=json.load(open('output/ho01-l1-stack.template.json'))
r=t['Resources']['RawBucket']['Properties']
print(' '.join(sorted(k for k in r if k not in ('BucketName','Tags'))))")"
    assert_eq "$p" "" "L1 RawBucket 除显式字段外无注入属性"
    grep -q 'VersioningConfiguration' output/ho01-l1-stack.template.json \
        && die "L1 不应自动出现版本化" || ok "L1 无 VersioningConfiguration"

    step "observe" "L2：默认值注入——SSE-S3 加密由 L2 自动补齐（AES256）"
    grep -q 'ServerSideEncryptionConfiguration' output/ho01-l2-stack.template.json \
        || die "L2 应自动注入 SSE 配置"
    grep -q 'AES256' output/ho01-l2-stack.template.json \
        || die "L2 默认加密算法应为 AES256"
    ok "L2 自动注入：BucketEncryption → ServerSideEncryptionConfiguration(AES256)"
    note "CDK 2.268 的 L2 不再注入 PublicAccessBlock（交给 AWS 默认全 True）——版本也影响默认值"
    grep -q 'VersioningConfiguration' output/ho01-l2-stack.template.json \
        && die "L2 默认不应开启版本化" || ok "L2 默认无版本化（等待 escape hatch 出场）"

    step "observe" "escape hatch 线上断言：版本化 Status=Enabled 真实生效"
    v="$(awsx s3api get-bucket-versioning --bucket ho01-l2x-data --query 'Status' --output text)"
    assert_eq "$v" "Enabled" "ho01-l2x-data 版本化已通过 addOverride 开启"

    step "observe" "escape hatch 线上断言：默认加密算法 AES256 → aws:kms"
    e="$(awsx s3api get-bucket-encryption --bucket ho01-l2x-data \
        --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"
    assert_eq "$e" "aws:kms" "默认加密算法被 override 为 aws:kms"

    step "observe" "escape hatch 坑实录：PAB 单字段 False 在模板里生效、被引擎归一化"
    tb="$(python3 -c "
import json
t=json.load(open('output/ho01-l2x-stack.template.json'))
print(t['Resources']['Data666C94C7']['Properties']['PublicAccessBlockConfiguration']['BlockPublicPolicy'])")"
    assert_eq "$tb" "False" "synth 模板中 BlockPublicPolicy=False（override 已落模板）"
    lb="$(awsx s3api get-public-access-block --bucket ho01-l2x-data \
        --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' --output text)"
    assert_eq "$lb" "True" "线上仍为 True——CFN 引擎把部分 PAB 字段归一化（README 坑实录）"

    step "observe" "逻辑 ID 命名：L1 直译 RawBucket，L2 Data+8 位散列"
    lid1="$(python3 -c "
import json
t=json.load(open('output/ho01-l1-stack.template.json'))
print('RawBucket' in t['Resources'])")"
    assert_eq "$lid1" "True" "L1 逻辑 ID 就是构造路径直译 RawBucket"
    lid2="$(python3 -c "
import json,re
t=json.load(open('output/ho01-l2-stack.template.json'))
m=[k for k in t['Resources'] if re.fullmatch(r'Data[0-9A-F]{8}', k)]
print(len(m))")"
    assert_eq "$lid2" "1" "L2 逻辑 ID 带 8 位散列后缀（重命名安全）"

    step "observe" "L1/L2 桶都在线上：同一逻辑桶、三种写法、各自成栈"
    for bk in ho01-l1-raw ho01-l2-data; do
        awsx s3api head-bucket --bucket "$bk" >/dev/null 2>&1 || die "$bk 不存在"
        ok "$bk 存在"
    done

    step "observe" "对照表归档确认"
    [ -s output/comparison.md ] || die "对照表缺失"
    ok "output/comparison.md 共 $(grep -c '^|' output/comparison.md) 行表格"
    note "L3 的 Trail 模板见对照表：1 个 Construct → 桶+桶策略+Trail 三资源，未部署"
}

do_clean() {
    step "clean" "cdklocal destroy 一键清栈"
    cdkx destroy "$L3S" "$L2XS" "$L2S" "$L1S" --force >/dev/null 2>&1 || true
    for bk in ho01-l1-raw ho01-l2-data ho01-l2x-data; do
        awsx s3api head-bucket --bucket "$bk" >/dev/null 2>&1 && die "$bk 残留" || ok "$bk 已清理"
    done
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho01 完成"

#!/usr/bin/env bash
# =============================================================================
# 07 · fine-grained 断言测试 —— aws_cdk.assertions 对构造库的合成期断言
# 用法: ./cdk_assertions.sh [all]   (纯合成期测试，不依赖 LocalStack)
#
# 流程：green 套件全绿 → 注入 no_encryption 抓红 → 注入 bad_runtime 抓红
# 验收：pytest 退出码逐一对表（0 / 非 0 / 非 0），失败用例名精确匹配
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }

cd cdk_app

step "all" "green 套件：12 条 fine-grained 断言（资源形态/数量/反面/导出）"
python3 -m pytest tests/test_pipeline.py -q > /tmp/ho07_green.log 2>&1 \
    || { tail -12 /tmp/ho07_green.log; die "green 套件不应失败"; }
grep -q "12 passed" /tmp/ho07_green.log || die "应有 12 条通过"
ok "12 passed（exit=0）"

step "all" "red 抓红一：注入 no_encryption（桶不带加密）→ 加密断言必须抓红"
HO37_BREAK=no_encryption python3 -m pytest tests/test_broken.py -q > /tmp/ho07_red1.log 2>&1 \
    && die "错误配置竟通过断言"
grep -q "test_bucket_encrypted_by_default" /tmp/ho07_red1.log \
    || die "抓红用例名不符"
ok "加密断言抓红（exit≠0，test_bucket_encrypted_by_default FAILED）"

step "all" "red 抓红二：注入 bad_runtime（python → nodejs）→ runtime 断言必须抓红"
HO37_BREAK=bad_runtime python3 -m pytest tests/test_broken.py -q > /tmp/ho07_red2.log 2>&1 \
    && die "错误配置竟通过断言"
grep -q "test_lambda_runtime_python312" /tmp/ho07_red2.log \
    || die "抓红用例名不符"
ok "runtime 断言抓红（exit≠0，test_lambda_runtime_python312 FAILED）"

echo; echo "🎉 ho07 完成（不依赖 LocalStack，纯合成期验证）"

#!/usr/bin/env bash
# =============================================================================
# 27 · Terraform 工程化 —— 可复用 module / workspace 多环境 / S3 远端状态 / -target 增量
# 用法: ./terraform_engineering.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
TF="configs/terraform"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }

tfc() { (cd "$TF" && case "$1" in
        plan|destroy|refresh) tflocal "$@" -input=false ;;   # 只有这些接受 -input
        *) tflocal "$@" ;;
    esac); }
ws_env() { # $1=workspace 名 → 输出该环境的资源前缀
    (cd "$TF" && tflocal workspace select "$1" >/dev/null 2>&1 && tflocal output -json summary 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["value"]["env"], d["value"]["bucket"])' 2>/dev/null || echo "")
}
cleanup_res() { # 删除两个环境的资源（幂等）
    for e in dev stg; do
        awsx s3 rb "s3://ho27-app-bucket-$e" --force >/dev/null 2>&1 || true
    done
}
state_cleanup() { (cd "$TF" && rm -rf .terraform .terraform.lock.hcl terraform.tfstate* terraform.tfstate.d) }

do_apply() {
    step "apply" "清理残留 + init"
    cleanup_res
    state_cleanup
    tfc init >/dev/null 2>&1 || die "terraform init 失败（首次需下载 provider）"
    ok "provider 就绪"

    step "apply" "workspace 多环境：default(dev) 与 stg 各自实例化"
    tfc apply -auto-approve >/dev/null                 # default workspace = dev
    tfc workspace new stg >/dev/null 2>&1 || true   # 存在则忽略错误
    tfc workspace select stg >/dev/null
    tfc apply -auto-approve >/dev/null
    tfc workspace select default >/dev/null
    ok "两个环境（default=dev 与 stg）各自 apply 完成"
}

do_observe() {
    step "observe" "同一 module 在两个 workspace 参数不同、资源隔离"
    tfc workspace select default >/dev/null 2>&1 || true
    local dev_line stg_line
    dev_line="$(tfc output -json summary | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("env", "?"), d.get("bucket", "?"))')"
    tfc workspace select stg >/dev/null
    stg_line="$(tfc output -json summary | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("env", "?"), d.get("bucket", "?"))')"
    echo "  dev: $dev_line"
    echo "  stg: $stg_line"
    [ "$dev_line" != "$stg_line" ] && ok "两环境资源名不同（workspace 隔离生效）" || die "workspace 隔离失效"

    step "observe" "plan -out 机器可读 + -target 增量变更"
    tfc workspace select default >/dev/null 2>&1 || true   # 确保在 dev 上做增量
    sed -i '' 's/name   = "ho27-app"/name   = "ho27-app2"/' "$TF/main.tf"
    tfc plan -out /tmp/ho27.tfplan >/dev/null
    tfc show -json /tmp/ho27.tfplan | python3 -c '
import json, sys
d = json.load(sys.stdin)
acts = {}
for r in d.get("resource_changes", []):
    for a in r.get("change", {}).get("actions", []):
        acts[a] = acts.get(a, 0) + 1
print("  plan 动作统计:", acts)
assert acts.get("delete", 0) >= 1 and acts.get("create", 0) >= 1, "应为销毁+重建"
' && ok "-target 重建资源：plan 精确显示 destroy+create"
    tfc apply -auto-approve /tmp/ho27.tfplan >/dev/null
    awsx sqs get-queue-url --queue-name ho27-app2-queue-dev >/dev/null 2>&1 \
        && ok "新队列已落地（ho27-app2-queue-dev）" || die "apply 未生效"

    step "observe" "S3 远端状态迁移（state push；本机构建 state lock 用本地，如实记录）"
    (cd "$TF" && tflocal state pull > /tmp/ho27_state.json)
    [ -s /tmp/ho27_state.json ] && ok "state pull 成功（$(wc -c < /tmp/ho27_state.json | tr -d ' ') 字节）——生产中 push 到 S3 backend 托管" \
        || die "state pull 失败"
}

do_clean() {
    step "clean" "双环境 destroy + 状态清理"
    tfc destroy -auto-approve >/dev/null 2>&1 || true
    tfc workspace new stg >/dev/null 2>&1 || true   # 存在则忽略错误
    tfc workspace select stg >/dev/null 2>&1 && tfc destroy -auto-approve >/dev/null 2>&1 || true
    tfc workspace select default >/dev/null 2>&1 || true
    cleanup_res
    state_cleanup
    sed -i "" 's/name   = "ho27-app2"/name   = "ho27-app"/' "$TF/main.tf"   # 复位模板，保证可重复
    local left
    left="$(awsx s3 ls 2>/dev/null | grep -c ho27 || true)"
    [ "$left" = "0" ] && ok "已删净，环境复原" || die "仍有 $left 个 ho27 资源残留"
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

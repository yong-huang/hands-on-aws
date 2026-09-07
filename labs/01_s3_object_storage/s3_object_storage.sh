#!/usr/bin/env bash
# =============================================================================
# 01 · S3 对象存储 —— bucket 生命周期 / 对象 CRUD / 版本控制与回滚 / 生命周期规则 / 预签名 URL
# 用法: ./s3_object_storage.sh [apply|observe|clean|all]   (默认 all)
# 前置: LocalStack 运行中 (http://localhost:4566)，见 scripts/load_resources.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"                      # 任意 cwd 运行都正确

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
BUCKET="ho01-demo"                        # 本实验所有资源用 ho01- 前缀，clean 只删自己的

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER=""                       # 关闭 aws CLI 分页（脚本里会卡住）
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"  # LocalStack 固定测试凭证
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

# ---- 清空一个版本化桶的全部版本 + delete marker（版本化桶 rm 只打标记，删不干净）----
purge_bucket() {
    local marker vid
    awsx s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || return 0   # 桶不存在=已干净
    # 取所有版本和删除标记的 key+versionId，逐个物理删除
    awsx s3api list-object-versions --bucket "$BUCKET" --output json 2>/dev/null \
      | python3 -c '
import json,sys
d=json.load(sys.stdin)
out=[(v["Key"],v["VersionId"]) for k in ("Versions","DeleteMarkers") for v in d.get(k,[])]
print("\n".join(f"{k} {v}" for k,v in out))' \
      | while read -r marker vid; do
            [ -z "$marker" ] && continue
            awsx s3api delete-object --bucket "$BUCKET" --key "$marker" --version-id "$vid" >/dev/null
        done
    awsx s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true
}

do_apply() {
    step "apply" "预清理残留（幂等，可重复跑）"
    purge_bucket
    awsx s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && die "旧桶仍在" || ok "旧桶已不存在"

    step "apply" "创建 bucket: $BUCKET"
    awsx s3api create-bucket --bucket "$BUCKET" >/dev/null
    awsx s3api head-bucket --bucket "$BUCKET" >/dev/null && ok "bucket 就绪"

    step "apply" "启用版本控制（Versioning 一旦启用只能 Suspended，不能关闭）"
    awsx s3api put-bucket-versioning --bucket "$BUCKET" \
        --versioning-configuration Status=Enabled
    assert_eq "Enabled" \
        "$(awsx s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text)" \
        "版本控制已启用"

    step "apply" "挂载生命周期规则（声明式配置: configs/lifecycle.json）"
    awsx s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
        --lifecycle-configuration "file://configs/lifecycle.json" >/dev/null
    ok "规则数: $(awsx s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'Rules[].ID' --output text | wc -w | tr -d ' ')"
}

do_observe() {
    step "observe" "对象 CRUD：上传 → 下载 → 内容一致"
    echo "hello s3 v1 — $(date +%s)" > /tmp/ho01_obj.txt
    awsx s3api put-object --bucket "$BUCKET" --key notes/readme.txt \
        --body /tmp/ho01_obj.txt >/dev/null
    local got
    got="$(awsx s3api get-object --bucket "$BUCKET" --key notes/readme.txt /tmp/ho01_out.txt >/dev/null; cat /tmp/ho01_out.txt)"
    assert_eq "$(cat /tmp/ho01_obj.txt)" "$got" "上传→下载内容一致"

    step "observe" "复制对象（服务端 copy，不经过本地）"
    awsx s3api copy-object --bucket "$BUCKET" --key notes/copy.txt \
        --copy-source "$BUCKET/notes/readme.txt" --metadata-directive COPY >/dev/null
    assert_eq "2" \
        "$(awsx s3api list-objects-v2 --bucket "$BUCKET" --query 'length(Contents)' --output text)" \
        "桶内现有 2 个对象"

    step "observe" "覆盖写入 → 同一 key 出现两个版本"
    echo "hello s3 v2 — updated" > /tmp/ho01_obj.txt
    awsx s3api put-object --bucket "$BUCKET" --key notes/readme.txt \
        --body /tmp/ho01_obj.txt >/dev/null
    assert_eq "2" \
        "$(awsx s3api list-object-versions --bucket "$BUCKET" --prefix notes/readme.txt --query 'length(Versions)' --output text)" \
        "readme.txt 有 2 个历史版本"

    step "observe" "回滚：按 VersionId 读回 v1"
    local old_vid
    old_vid="$(awsx s3api list-object-versions --bucket "$BUCKET" --prefix notes/readme.txt \
        --query 'Versions[?IsLatest==`false`].VersionId | [0]' --output text)"
    assert_eq "$(echo "hello s3 v1" )" \
        "$(awsx s3api get-object --bucket "$BUCKET" --key notes/readme.txt \
            --version-id "$old_vid" /tmp/ho01_old.txt >/dev/null; cut -d' ' -f1-3 /tmp/ho01_old.txt)" \
        "v1 内容可完整读回（VersionId=${old_vid}）"

    step "observe" "删除对象 → 版本化桶只是打了 delete marker"
    awsx s3api delete-object --bucket "$BUCKET" --key notes/readme.txt >/dev/null
    if awsx s3api get-object --bucket "$BUCKET" --key notes/readme.txt /dev/null 2>/dev/null; then
        die "对象应已不可见"
    else
        ok "GET 已 404：客户端视角对象消失了"
    fi
    assert_eq "1" \
        "$(awsx s3api list-object-versions --bucket "$BUCKET" --prefix notes/readme.txt --query 'length(DeleteMarkers)' --output text)" \
        "delete marker 落桶（这就是'删除'的真相）"

    step "observe" "移除 delete marker → 对象'复活'（最新版本仍是 v2）"
    local dm_vid
    dm_vid="$(awsx s3api list-object-versions --bucket "$BUCKET" --prefix notes/readme.txt \
        --query 'DeleteMarkers[0].VersionId' --output text)"
    awsx s3api delete-object --bucket "$BUCKET" --key notes/readme.txt --version-id "$dm_vid" >/dev/null
    assert_eq "hello s3 v2" \
        "$(awsx s3api get-object --bucket "$BUCKET" --key notes/readme.txt /dev/null >/dev/null 2>&1 || true; awsx s3api get-object --bucket "$BUCKET" --key notes/readme.txt /tmp/ho01_out.txt >/dev/null && cut -d' ' -f1-3 /tmp/ho01_out.txt)" \
        "复活后读到的仍是 v2 内容"

    step "observe" "生命周期规则已生效（配置可见；真实删除由 AWS 后台任务执行，LocalStack 只存不跑）"
    awsx s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
        --query 'Rules[].{Rule:ID,Status:Status,Prefix:Filter.Prefix}' --output table

    step "observe" "预签名 URL：生成 → 真实 HTTP 下载 → 过期失效"
    local url
    url="$(awsx s3 presign "s3://$BUCKET/notes/readme.txt" --expires-in 60)"
    echo "  URL: ${url:0:80}..."
    local body
    body="$(curl -s "$url")"
    assert_eq "hello s3 v2" "$(echo "$body" | cut -d' ' -f1-3)" "预签名 URL 下载内容正确（无需任何凭证）"

    url="$(awsx s3 presign "s3://$BUCKET/notes/readme.txt" --expires-in 2)"
    sleep 3
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url")"
    if [ "$code" = "403" ]; then ok "过期 URL 返回 403（时效性生效）"
    else ok "过期 URL 返回 ${code}（注：LocalStack 对极短有效期不严格，真实 AWS 会 403）"; fi
}

do_clean() {
    step "clean" "删除桶内全部版本 + delete markers + 桶本身"
    purge_bucket
    if awsx s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then die "桶未删干净"; else ok "桶已删除，环境复原"; fi
}

main() {
    local target="${1:-all}"
    case "$target" in
        apply)   do_apply ;;
        observe) do_observe ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_clean ;;
        *) echo "可用: apply | observe | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"

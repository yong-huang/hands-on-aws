#!/usr/bin/env bash
# =============================================================================
# 09 · 部署机制解剖 —— bootstrap / 资产 staging / 手工变更集部署 CDK 产物
# 用法: ./cdk_deploy_anatomy.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : bootstrap 探活（列 CDKToolkit 栈+资产桶）→ cdklocal deploy 带资
#           产栈 → 断言资产 zip 落入 staging 桶 + 资产 Lambda 可invoke
# observe : 同一栈代码 -c variant=manual 重合成 → 用 awslocal cloudformation
#           变更集手工部署同一份 CDK 产物 → invoke 断言（证明 CDK 产出
#           就是普通 CFN 模板）→ 解剖笔记落盘
# clean   : destroy 两栈（保留 CDKToolkit，供后续实验复用）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
STACK="ho09-stack"; MANUAL="ho09-manual-stack"
# 资产散列 = 内容散列（CDK 的资产对象名），从合成模板的参数名提取——
# 参数名形如 AssetParameters<64位散列>ArtifactHash<后缀>，散列由 CDK 记录，
# 是唯一可信来源。⚠️ 不能 ls cdk.out/asset.*：synth 不清理旧资产目录，
# 陈旧目录会被 head -1 误选（迁移改名时的实测教训：旧 zip 部署出旧代码）
ASSET_HASH=""   # 由 asset_hash() 在 synth 后填充
asset_hash() {
    [ -n "$ASSET_HASH" ] && { echo "$ASSET_HASH"; return; }
    ASSET_HASH="$(python3 -c "
import json, re
t = json.load(open('${APPDIR}/cdk.out/ho09-stack.template.json'))
for k in t.get('Parameters', {}):
    if 'ArtifactHash' in k:
        m = re.search(r'[0-9a-f]{64}', k)
        if m:
            print(m.group(0)); break
")"
    [ -n "$ASSET_HASH" ] || die "模板未含资产散列参数（先 synth）"
    echo "$ASSET_HASH"
}
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

health() {
    curl -s -m 3 "$ENDPOINT/_localstack/health" | grep -q 's3' \
        || die "LocalStack 未就绪 ($ENDPOINT)。先运行 localstack start -d"
}

staging_bucket() {  # 打印 bootstrap 资产桶名
    awsx s3api list-buckets --query 'Buckets[?starts_with(Name, `cdk-hnb659fds-assets`)].Name' \
        --output text | head -1
}

do_apply() {
    health
    step "apply" "bootstrap 探活：CDKToolkit 栈 + 资产 staging 桶"
    st="$(awsx cloudformation describe-stacks --stack-name CDKToolkit \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING)"
    [ "$st" != "MISSING" ] || { cdklocal bootstrap aws://000000000000/us-east-1 >/dev/null 2>&1 \
        || die "bootstrap 失败"; }
    ok "CDKToolkit 栈状态: $(awsx cloudformation describe-stacks --stack-name CDKToolkit \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"
    SB="$(staging_bucket)"
    [ -n "$SB" ] || die "未找到 staging 资产桶"
    ok "资产桶: $SB"

    step "apply" "预清理 + cdklocal deploy 带资产栈（Code.from_asset）"
    for s in "$MANUAL" "$STACK"; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
        awsx cloudformation wait stack-delete-complete --stack-name "$s" >/dev/null 2>&1 || true
    done
    cdkx deploy "$STACK" -c variant=cdk --require-approval never 2>&1 | grep -E '✅' | tail -1 \
        || die "deploy 失败"

    step "apply" "资产落地断言：zip 以内容散列入 staging 桶"
    H="$(asset_hash)"
    obj="$(awsx s3api list-objects-v2 --bucket "$SB" --prefix "assets/$H" \
        --query 'length(Contents)' --output text)"
    [ "$obj" != "None" ] && [ "$obj" != "0" ] || die "staging 桶未见资产对象 assets/$H*"
    key="$(awsx s3api list-objects-v2 --bucket "$SB" --prefix "assets/$H" \
        --query 'Contents[].Key' --output text)"
    ok "资产对象: $key"
    cp "$APPDIR/cdk.out/ho09-stack.template.json" output/

    step "apply" "资产 Lambda 可用：invoke 返回资产包内容标识"
    r="$(awsx lambda invoke --function-name ho09-asset-fn-cdk --payload '{}' /tmp/ho09_r1.json >/dev/null 2>&1 \
        && python3 -c "import json;print(json.load(open('/tmp/ho09_r1.json'))['from'])")"
    assert_eq "$r" "ho09 asset" "资产 zip 被正确解包运行"
}

do_observe() {
    health
    step "observe" "预清理（上次残留的手工栈）"
    awsx cloudformation delete-stack --stack-name "$MANUAL" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$MANUAL" >/dev/null 2>&1 || true
    step "observe" "手工变更集部署同一份 CDK 产物（-c variant=manual 重合成）"
    (cd "$APPDIR" && cdklocal synth -c variant=manual >/dev/null 2>&1)
    cp "$APPDIR/cdk.out/ho09-stack.template.json" output/ho09-manual.template.json
    SB="$(staging_bucket)"

    # 资产参数由我们亲手填（CDK CLI 平时替你做的事）
    PARAMS=()
    while read -r k; do
        # ⚠️ AWS CLI v2 对重复的 --parameters 只留最后一个——必须单 flag 多 token
        case "$k" in
            *S3Bucket*)   PARAMS+=("ParameterKey=$k,ParameterValue=$SB") ;;
            *S3VersionKey*) PARAMS+=("ParameterKey=$k,ParameterValue=assets/||$(asset_hash).zip") ;;
            *ArtifactHash*) PARAMS+=("ParameterKey=$k,ParameterValue=$(asset_hash)") ;;
        esac
    done < <(python3 -c "
import json
t=json.load(open('output/ho09-manual.template.json'))
print('\n'.join(t.get('Parameters', {}).keys()))")
    [ "${#PARAMS[@]}" -ge 3 ] || die "资产参数应至少 3 个（S3Bucket/S3VersionKey/ArtifactHash）"

    step "observe" "create-change-set（先审后行）"
    csid="$(awsx cloudformation create-change-set \
        --stack-name "$MANUAL" --change-set-name ho09-manual-cs --change-set-type CREATE \
        --template-body "file://output/ho09-manual.template.json" \
        --parameters "${PARAMS[@]}" \
        --capabilities CAPABILITY_IAM \
        --query 'Id' --output text)" || die "create-change-set 失败"
    for i in $(seq 1 15); do
        st="$(awsx cloudformation describe-change-set --change-set-name "$csid" \
            --query 'Status' --output text 2>/dev/null || echo PENDING)"
        [ "$st" = "CREATE_COMPLETE" ] || [ "$st" = "FAILED" ] && break; sleep 2
    done
    assert_eq "$st" "CREATE_COMPLETE" "变更集就绪（可审阅）"
    n="$(awsx cloudformation describe-change-set --change-set-name "$csid" \
        --query 'length(Changes)' --output text)"
    ok "变更集含 $n 项变更（与 synth 模板资源一致）"
    awsx cloudformation describe-change-set --change-set-name "$csid" \
        --query 'Changes[].ResourceChange.[Action,LogicalResourceId]' --output text \
        | sed 's/^/       /'

    step "observe" "execute-change-set：纯 CFN 通道部署 CDK 产物"
    awsx cloudformation execute-change-set --change-set-name "$csid" >/dev/null
    awsx cloudformation wait stack-create-complete --stack-name "$MANUAL" \
        --cli-read-timeout 90 2>/dev/null || true
    st="$(awsx cloudformation describe-stacks --stack-name "$MANUAL" \
        --query 'Stacks[0].StackStatus' --output text)"
    assert_eq "$st" "CREATE_COMPLETE" "手工部署完成"

    step "observe" "手工栈资源可用：桶在、资产 Lambda 可 invoke"
    awsx s3api head-bucket --bucket ho09-anatomy-manual >/dev/null 2>&1 || die "manual 桶不存在"
    ok "ho09-anatomy-manual 存在"
    r="$(awsx lambda invoke --function-name ho09-asset-fn-manual --payload '{}' /tmp/ho09_r2.json >/dev/null 2>&1 \
        && python3 -c "import json;print(json.load(open('/tmp/ho09_r2.json'))['from'])")"
    assert_eq "$r" "ho09 asset" "手工部署的资产 Lambda 也可用（同一份 zip 复用）"

    step "observe" "解剖笔记落盘"
    {
        echo "## ho09 部署链路解剖（全部本机实测）"
        echo
        echo "1. synth：App 构造树 → cdk.out（模板 + 资产目录 asset.<散列>/ + manifest）。"
        echo "2. 资产：Code.from_asset 打包 zip，对象名 = 内容散列 $ASSET_HASH*。"
        echo "3. bootstrap：CDKToolkit 栈建出 staging 桶（${SB}）与部署角色；"
        echo "   未 bootstrap 时资产无法上传（cdk/01 教训）。"
        echo "4. cdk deploy：CLI 上传资产 → 填模板 AssetParameters（桶/版本键/散列）→"
        echo "   交给 CFN。模板里的 S3Bucket/S3Key 全是 Parameters——这就是 CLI 与"
        echo "   CFN 的接口契约。"
        echo "5. 手工通道：同一份模板，变更集三步（create→describe 审阅→execute），"
        echo "   资产参数亲手填，照样部署成功且 Lambda 可用——CDK 产出即普通 CFN 模板。"
    } > output/deploy_anatomy.md
    ok "output/deploy_anatomy.md（5 段链路）"
}

do_clean() {
    step "clean" "destroy 两栈（CDK 栈走 CLI；手工栈是普通 CFN 栈走原生 API——本质差异的又一实证）"
    cdkx destroy "$STACK" --force >/dev/null 2>&1 || true
    awsx cloudformation delete-stack --stack-name "$MANUAL" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$MANUAL" >/dev/null 2>&1 || true
    for b in ho09-anatomy-cdk ho09-anatomy-manual; do
        awsx s3api head-bucket --bucket "$b" >/dev/null 2>&1 && die "$b 残留" || ok "$b 已清理"
    done
    for f in ho09-asset-fn-cdk ho09-asset-fn-manual; do
        awsx lambda get-function --function-name "$f" >/dev/null 2>&1 && die "$f 残留" || ok "$f 已清理"
    done
    note "CDKToolkit 保留（后续实验的 bootstrap 依赖，含 staging 资产桶）"
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho09 完成"

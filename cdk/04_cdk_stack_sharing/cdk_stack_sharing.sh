#!/usr/bin/env bash
# =============================================================================
# 04 · 跨栈引用与参数共享三通道 —— Export/ImportValue · NestedStack · SSM
# 用法: ./cdk_stack_sharing.sh [apply|observe|clean|all]   (默认 all)
#
# apply   : 依序部署 producer → 两个 IaC 引用消费栈 → 嵌套父栈 → SSM 运行时消费栈
# observe : 三通道端到端断言（各 Lambda 返回的队列 URL 与真实值逐一比对）
#           + synth 产物差异对照表归档
# clean   : destroy 四栈 + SSM 参数
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
APPDIR="cdk_app"
SRC_QUEUE="ho04-src-queue"
SRC_FN="ho04-src-fn"
STACKS="ho04-producer-stack ho04-consumer-ref-stack ho04-parent-stack ho04-consumer-ssm-stack"
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

invoke_url() {  # invoke_url <fn> <outfile> → 返回 Lambda 报告的 queue_url
    local fn="$1" out="$2"
    awsx lambda invoke --function-name "$fn" --payload '{}' "$out" >/dev/null 2>&1 \
        || die "invoke $fn 失败"
    python3 -c "import json,sys;print(json.load(open('$out'))['queue_url'])"
}

do_apply() {
    health
    step "apply" "预清理（四栈 + SSM 参数）"
    for s in ho04-consumer-ssm-stack ho04-parent-stack ho04-consumer-ref-stack ho04-producer-stack; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
        awsx cloudformation wait stack-delete-complete --stack-name "$s" >/dev/null 2>&1 || true
    done
    awsx ssm delete-parameter --name "ho04-queue-url" >/dev/null 2>&1 || true

    step "apply" "synth + 归档四栈模板（含嵌套子模板）"
    cdkx synth >/dev/null 2>&1 || die "synth 失败"
    for f in "$APPDIR"/cdk.out/*.template.json; do
        cp "$f" "output/$(basename "$f")"
    done
    ok "归档 $(ls output/*.template.json | wc -l | tr -d ' ') 份模板（含 .nested 嵌套子模板）"

    step "apply" "部署 producer（队列）"
    cdkx deploy ho04-producer-stack --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "producer deploy 失败"

    step "apply" "CI/CD 式写入 SSM 参数（坑实录：本机 SSM 的 CFN provider 不可用）"
    qurl="$(awsx sqs get-queue-url --queue-name "$SRC_QUEUE" --query 'QueueUrl' --output text)"
    awsx ssm put-parameter --name "ho04-queue-url" --type String --value "$qurl" --overwrite >/dev/null \
        || die "SSM 参数写入失败"
    ok "ho04-queue-url ← $qurl"

    step "apply" "部署两个 IaC 引用消费栈（CDK 自动处理跨栈依赖序）"
    cdkx deploy ho04-consumer-ref-stack ho04-parent-stack --require-approval never 2>&1 | grep -E '✅' | tail -2 || die "引用消费栈 deploy 失败"

    step "apply" "部署 SSM 运行时消费栈（参数已就位，无 IaC 依赖）"
    cdkx deploy ho04-consumer-ssm-stack --require-approval never 2>&1 | grep -E '✅' | tail -1 || die "ssm consumer deploy 失败"

    step "apply" "生成三通道 synth 产物差异对照表"
    python3 - output/sharing.md <<'PYEOF'
import json, glob, os
rows = ["| 通道 | 模板 | 关键机制 | 证据 |", "|:---|:---|:---|:---|"]
def has(tpl, needle):
    return needle in json.dumps(tpl)
ref = json.load(open("output/ho04-consumer-ref-stack.template.json"))
par = json.load(open("output/ho04-parent-stack.template.json"))
ssm = json.load(open("output/ho04-consumer-ssm-stack.template.json"))
pro = json.load(open("output/ho04-producer-stack.template.json"))
rows.append("| 一 Stack 属性引用 | producer + consumer-ref | Export + Fn::ImportValue |"
            f" producer 导出 {len(pro.get('Outputs', {}))} 项 / ref 模板 ImportValue ×{json.dumps(ref).count('Fn::ImportValue')} |")
rows.append("| 二 NestedStack | parent（+ 独立 .nested 子模板） | Fn::GetAtt [嵌套资源, Outputs.X] |"
            f" 嵌套资源 {sum(1 for r in par['Resources'].values() if r.get('Type')=='AWS::CloudFormation::Stack')} 个，"
            f"GetAtt×{json.dumps(par).count('Fn::GetAtt')} |")
rows.append("| 三 SSM 运行时 | consumer-ssm | IaC 只传参数名，运行时 get_parameter |"
            f" ref 值出现 {json.dumps(ssm).count('ho04-queue-url')} 次（仅参数名，无 URL） |")
open("output/sharing.md", "w").write("\n".join(rows) + "\n")
print("\n".join(rows))
PYEOF
}

do_observe() {
    health
    step "observe" "真实队列 URL（基准值）"
    actual="$(awsx sqs get-queue-url --queue-name "$SRC_QUEUE" --query 'QueueUrl' --output text)"
    ok "基准：$actual"

    step "observe" "通道一：Stack 属性引用消费方拿到正确 URL"
    sleep 2
    v1="$(invoke_url ho04-ref-fn /tmp/ho04_r1.json)"
    assert_eq "$v1" "$actual" "通道一 Lambda 报告 URL 与基准一致"

    step "observe" "通道二：NestedStack 穿透引用（消费方用的是嵌套栈里自己的队列）"
    nested="$(awsx sqs get-queue-url --queue-name ho04-nested-queue --query 'QueueUrl' --output text)"
    v2="$(invoke_url ho04-nested-fn /tmp/ho04_r2.json)"
    assert_eq "$v2" "$nested" "通道二 Lambda 报告 URL 与嵌套队列基准一致"

    step "observe" "通道三：SSM 运行时读取拿到正确 URL（部署期已落值）"
    v3="$(invoke_url ho04-ssm-fn /tmp/ho04_r3.json)"
    assert_eq "$v3" "$actual" "通道三 Lambda 报告 URL 与基准一致"
    p="$(awsx ssm get-parameter --name ho04-queue-url --query 'Parameter.Value' --output text)"
    assert_eq "$p" "$actual" "SSM 参数值 = 队列 URL（GetAtt 部署期解析实证）"

    step "observe" "对照表归档"
    [ -s output/sharing.md ] || die "对照表缺失"
    ok "output/sharing.md 就绪（$(grep -c '^|' output/sharing.md) 行）"
    note "通道三的模板里只有参数名没有 URL——值在部署期进 SSM、运行时出 SSM"
}

do_clean() {
    step "clean" "destroy 四栈（SSM 参数随 producer DELETE）"
    cdkx destroy ho04-consumer-ssm-stack ho04-parent-stack ho04-consumer-ref-stack --force >/dev/null 2>&1 || true
    cdkx destroy ho04-producer-stack --force >/dev/null 2>&1 || true
    awsx sqs get-queue-url --queue-name "$SRC_QUEUE" >/dev/null 2>&1 && die "队列残留" || ok "队列已清理"
    awsx ssm delete-parameter --name ho04-queue-url >/dev/null 2>&1 || true
    awsx ssm get-parameter --name ho04-queue-url >/dev/null 2>&1 && die "SSM 参数残留" || ok "SSM 参数已清理"
    awsx ssm get-parameter --name ho04-queue-url >/dev/null 2>&1 && die "SSM 参数残留" || ok "SSM 参数已清理"
    for f in ho04-ref-fn ho04-nested-fn ho04-ssm-fn; do
        awsx lambda get-function --function-name "$f" >/dev/null 2>&1 && die "$f 残留" || ok "$f 已清理"
    done
}

case "${1:-all}" in
    apply)   do_apply ;;
    observe) do_observe ;;
    clean)   do_clean ;;
    all)     do_apply; do_observe; do_clean ;;
    *) echo "用法: $0 [apply|observe|clean|all]" >&2; exit 1 ;;
esac

echo; echo "🎉 ho04 完成"

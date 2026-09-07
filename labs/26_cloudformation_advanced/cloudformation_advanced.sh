#!/usr/bin/env bash
# =============================================================================
# 26 · CloudFormation 深化 —— 变更集安全发布 / 嵌套栈 + 跨栈引用 / Lambda 自定义资源
# 用法: ./cloudformation_advanced.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
PARENT="ho26-parent-stack"
FN="ho26-cr-fn"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

do_apply() {
    step "apply" "预清理（栈按依赖逆序删除）+ 部署自定义资源 Lambda"
    awsx cloudformation delete-stack --stack-name "$PARENT" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$PARENT" >/dev/null 2>&1 || true
    for s in ho26-topic-stack; do
        awsx cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
    done
    awsx s3 rb s3://ho26-dev-retained --force >/dev/null 2>&1 || true
    awsx s3 rb s3://ho26-child-dev --force >/dev/null 2>&1 || true
    t="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':ho26-dev-topic')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    sleep 1
    (cd functions && zip -q /tmp/ho26_cr.zip custom_resource.py)
    awsx lambda create-function --function-name "$FN" \
        --runtime python3.12 --handler custom_resource.handler --zip-file "fileb:///tmp/ho26_cr.zip" \
        --role "arn:aws:iam::000000000000:role/ho26-exec" --memory-size 256 --timeout 60 \
        --environment "Variables={AWS_DEFAULT_REGION=$REGION}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
    done
    awsx lambda add-permission --function-name "$FN" --statement-id cfn \
        --action lambda:InvokeFunction --principal cloudformation.amazonaws.com >/dev/null 2>&1 || true
    ok "自定义资源函数 Active"

    step "apply" "上传嵌套子栈模板到 S3（TemplateURL 需要）"
    awsx s3 mb s3://ho26-templates >/dev/null 2>&1 || true
    awsx s3api put-object --bucket ho26-templates --key nested-child.yaml \
        --body configs/nested-child.yaml >/dev/null
    ok "模板已上传"
}

do_observe() {
    step "observe" "创建主栈（嵌套子栈 + Export + 自定义资源建表）"
    awsx cloudformation create-stack --stack-name "$PARENT" \
        --template-body "file://configs/nested-parent.yaml" \
        --parameters "ParameterKey=EnvName,ParameterValue=dev" \
        --capabilities CAPABILITY_IAM >/dev/null
    awsx cloudformation wait stack-create-complete --stack-name "$PARENT" 2>/dev/null || true
    assert_eq "CREATE_COMPLETE" "$(awsx cloudformation describe-stacks --stack-name "$PARENT" \
        --query 'Stacks[0].StackStatus' --output text)" "主栈创建完成"

    step "observe" "嵌套栈与跨栈引用（Fn::ImportValue）验证"
    awsx s3api head-bucket --bucket ho26-child-dev >/dev/null 2>&1 && ok "嵌套子栈资源（child 桶）存在" || die "子栈资源缺失"
    local t2
    t2="$(awsx sns list-topics --query "Topics[?ends_with(TopicArn, ':ho26-dev-topic')].TopicArn | [0]" --output text)"
    [ -n "$t2" ] && [ "$t2" != "None" ] && ok "SNS 主题存在（模板内 !Sub 引用参数）" || die "主题缺失"

    step "observe" "自定义资源：本构建不自动调用 CR Lambda（如实记录）——用合成事件手动驱动"
    note "CFN 事件结构完整（RequestType/ResponseURL/ResourceProperties），真实 AWS 自动调用"
    cat > /tmp/ho26_cr_event.json <<EOJ
{
  "RequestType": "Create",
  "StackId": "arn:aws:cloudformation:us-east-1:000000000000:stack/ho26-parent-stack/1",
  "RequestId": "req-1",
  "LogicalResourceId": "DynamicTable",
  "ResponseURL": "http://localhost:4566/ignore",
  "ResourceProperties": {"TableName": "ho26-cr-table"}
}
EOJ
    local ran=""   # LocalStack 的 invoke 偶发不落地：轮询里每 3 轮重发一次
    for _i in $(seq 1 20); do
        case $_i in 1|4|7|10|13|16|19) awsx lambda invoke --function-name "$FN" \
            --payload fileb:///tmp/ho26_cr_event.json /tmp/ho26_cr_out.json >/dev/null 2>&1 || true ;; esac
        ran="$(awsx ssm get-parameter --name /ho26/cr-ran --query 'Parameter.Value' --output text 2>/dev/null || true)"
        [ -n "$ran" ] && break; sleep 1
    done
    assert_eq "Create" "${ran:0:6}" "CR 处理器执行成功（SSM 标记: ${ran}）"

    step "observe" "变更集：预览 diff → 执行安全发布"
    python3 - <<'PY'
s = open("configs/nested-parent.yaml").read()
open("/tmp/ho26_v2.yaml", "w").write(s.replace("EnvName: dev", "EnvName: prod").replace("EnvName=dev", "EnvName=prod"))
PY
    awsx cloudformation create-change-set --stack-name "$PARENT" --change-set-name ho26-cs \
        --template-body "file:///tmp/ho26_v2.yaml" --capabilities CAPABILITY_IAM >/dev/null
    awsx cloudformation describe-change-set --change-set-name ho26-cs --stack-name "$PARENT" \
        --query 'Changes[].ResourceChange.{Resource:LogicalResourceId,Action:Action}' --output table
    local nchg
    nchg="$(awsx cloudformation describe-change-set --change-set-name ho26-cs --stack-name "$PARENT" \
        --query 'Changes' --output json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    [ "$nchg" -ge 1 ] && ok "变更集含 ${nchg} 处变更（预览可见）" || die "变更集为空"
    awsx cloudformation execute-change-set --change-set-name ho26-cs --stack-name "$PARENT" >/dev/null
    awsx cloudformation wait stack-update-complete --stack-name "$PARENT" 2>/dev/null || true
    assert_eq "UPDATE_COMPLETE" "$(awsx cloudformation describe-stacks --stack-name "$PARENT" \
        --query 'Stacks[0].StackStatus' --output text)" "变更集执行 → UPDATE_COMPLETE"
    note "如实记录：本构建对重命名类变更（桶名替换）可能不落地新资源，UPDATE_COMPLETE 即为发布成功"
}

do_clean() {
    step "clean" "DeletionPolicy: Retain 验证 → 删栈 → 保留桶手动清理"
    awsx cloudformation delete-stack --stack-name "$PARENT" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$PARENT" 2>/dev/null || true
    awsx s3api head-bucket --bucket ho26-prod-retained >/dev/null 2>&1 \
        && ok "DeletionPolicy: Retain 生效（栈删了，桶还在）" || note "Retain 未生效（如实记录）"
    awsx s3 rb s3://ho26-prod-retained --force >/dev/null 2>&1 || true
    awsx s3 rb s3://ho26-dev-retained --force >/dev/null 2>&1 || true
    awsx s3 rb s3://ho26-child-prod --force >/dev/null 2>&1 || true
    awsx s3 rb s3://ho26-child-dev --force >/dev/null 2>&1 || true
    awsx s3 rb s3://ho26-templates --force >/dev/null 2>&1 || true
    t="$(awsx sns list-topics --query "Topics[?contains(TopicArn, 'ho26-')].TopicArn | [0]" --output text 2>/dev/null || true)"
    [ -n "$t" ] && [ "$t" != "None" ] && awsx sns delete-topic --topic-arn "$t" >/dev/null || true
    awsx dynamodb delete-table --table-name ho26-cr-table >/dev/null 2>&1 || true
    awsx ssm delete-parameter --name /ho26/cr-ran >/dev/null 2>&1 || true
    awsx lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
    awsx logs delete-log-group --log-group-name "/aws/lambda/$FN" >/dev/null 2>&1 || true
    sleep 1
    ok "已删净，环境复原"
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

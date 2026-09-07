#!/usr/bin/env bash
# =============================================================================
# 09 · 基础设施即代码 —— Terraform(tflocal) apply/增量/destroy + CloudFormation 栈生命周期
# 用法: ./terraform_cloudformation.sh [apply|observe|clean|all]   (默认 all)
# 依赖: terraform + tflocal（pip3 install terraform-local），aws CLI
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
TF_DIR="configs/terraform"
CFN_DIR="configs/cloudformation"
STACK="ho09-cfn-stack"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

tf_res_exists() { # Terraform 管理的资源是否真实存在
    awsx s3api head-bucket --bucket ho09-tf-data >/dev/null 2>&1 \
        && awsx sqs get-queue-url --queue-name ho09-tf-jobs >/dev/null 2>&1 \
        && awsx sns get-topic-attributes --topic-arn "arn:aws:sns:$REGION:000000000000:ho09-tf-events" >/dev/null 2>&1
}
cfn_res_exists() {
    awsx s3api head-bucket --bucket ho09-cfn-data >/dev/null 2>&1 \
        && awsx sqs get-queue-url --queue-name ho09-cfn-jobs >/dev/null 2>&1
}
tf_clean() { # 删 Terraform 资源与其状态（幂等）
    (cd "$TF_DIR" && tflocal destroy -auto-approve >/dev/null 2>&1) || true
    rm -rf "$TF_DIR/.terraform" "$TF_DIR/.terraform.lock.hcl" "$TF_DIR/terraform.tfstate"*
    awsx s3 rb s3://ho09-tf-data --force >/dev/null 2>&1 || true
}
cfn_clean() {
    awsx cloudformation delete-stack --stack-name "$STACK" >/dev/null 2>&1 || true
    awsx cloudformation wait stack-delete-complete --stack-name "$STACK" >/dev/null 2>&1 || true
    awsx s3 rb s3://ho09-cfn-data --force >/dev/null 2>&1 || true
}

do_apply() {
    step "apply" "预清理残留（两套栈都复位，幂等）"
    tf_clean; cfn_clean; ok "无残留"

    step "apply" "[Terraform] init + plan（tflocal 自动把 provider 指向 LocalStack）"
    (cd "$TF_DIR" && tflocal init -input=false >/dev/null 2>&1) || die "terraform init 失败（首次需下载 provider，检查网络）"
    (cd "$TF_DIR" && tflocal plan -input=false) | grep -E 'Plan: .* to add' && ok "plan 预告 3 个新增资源"

    step "apply" "[Terraform] apply → 资源真实落进 LocalStack"
    (cd "$TF_DIR" && tflocal apply -auto-approve -input=false >/dev/null)
    tf_res_exists && ok "S3/SQS/SNS 三件真实存在" || die "Terraform apply 后资源缺失"

    step "apply" "[CloudFormation] create-stack（同构模板: configs/cloudformation/template.yaml）"
    awsx cloudformation create-stack --stack-name "$STACK" \
        --template-body "file://$CFN_DIR/template.yaml" >/dev/null
    awsx cloudformation wait stack-create-complete --stack-name "$STACK"
    cfn_res_exists && ok "CFN 栈资源就位" || die "CFN 栈资源缺失"
}

do_observe() {
    step "observe" "[Terraform] 增量更新：env=dev→prod + 队列 delay 0→5，只变 2 处"
    sed -i '' 's/delay_seconds = 0/delay_seconds = 5/' "$TF_DIR/main.tf"   # 模板本身也演进
    (cd "$TF_DIR" && tflocal plan -var env=prod -input=false) | grep -E '0 to add, 2 to change' \
        && ok "plan 精确预告 0 add / 2 change" || die "增量 plan 不符合预期"
    (cd "$TF_DIR" && tflocal apply -auto-approve -var env=prod -input=false >/dev/null)
    assert_eq "5" "$(awsx sqs get-queue-attributes --queue-url "$(awsx sqs get-queue-url --queue-name ho09-tf-jobs --query QueueUrl --output text)" --attribute-names DelaySeconds --query 'Attributes.DelaySeconds' --output text)" "队列 DelaySeconds 增量生效"

    step "observe" "[CloudFormation] 更新：DelaySeconds 0→5，栈级等待"
    python3 - <<'PY'
s = open("$CFN_DIR/template.yaml".replace("$CFN_DIR", "configs/cloudformation"))
open("/tmp/ho09_template_v2.yaml", "w").write(s.read().replace("DelaySeconds: 0", "DelaySeconds: 5"))
PY
    awsx cloudformation update-stack --stack-name "$STACK" \
        --template-body "file:///tmp/ho09_template_v2.yaml" >/dev/null
    awsx cloudformation wait stack-update-complete --stack-name "$STACK"
    assert_eq "5" "$(awsx sqs get-queue-attributes --queue-url "$(awsx sqs get-queue-url --queue-name ho09-cfn-jobs --query QueueUrl --output text)" --attribute-names DelaySeconds --query 'Attributes.DelaySeconds' --output text)" "CFN 更新生效"
    awsx cloudformation describe-stack-events --stack-name "$STACK" \
        --query 'StackEvents[0:4].[LogicalResourceId,ResourceStatus]' --output table

    step "observe" "两种 IaC 的状态对账（谁在管什么）"
    echo "  Terraform: 状态文件本地自持（terraform.tfstate），plan 是 diff 预告"
    echo "  CloudFormation: 状态在服务端（栈），describe-stack-events 是变更流水"
}

do_clean() {
    step "clean" "[Terraform] destroy → 资源全部消失"
    sed -i '' 's/delay_seconds = 5/delay_seconds = 0/' "$TF_DIR/main.tf"   # 模板复位，可重复运行
    tf_clean
    tf_res_exists && die "Terraform 资源未删净" || ok "Terraform 三件已删净"

    step "clean" "[CloudFormation] delete-stack → 栈与资源消失"
    cfn_clean
    cfn_res_exists && die "CFN 资源未删净" || ok "CFN 栈已删净，环境复原"
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

#!/usr/bin/env bash
# =============================================================================
# 06 · Step Functions 状态机编排 —— Choice 分支 / Parallel 并行 / Retry 重试 / Catch 补偿
# 用法: ./stepfunctions_state_machine.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
SM="ho06-order-sm"

export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"   # 防本机代理(如 :7890)劫持 boto3/CLI
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

wait_fn_active() {
    for _ in $(seq 1 60); do
        [ "$(awsx lambda get-function --function-name "$1" --query 'Configuration.State' --output text 2>/dev/null || echo NONE)" = "Active" ] && return 0
        sleep 1
    done
    die "Lambda $1 未 Active"
}
# 启动执行并轮询到终态（LocalStack 执行很快，重试场景留足 60s）
run_sm() { # $1=输入JSON $2=输出文件
    local arn arn_out
    arn_out="$(awsx stepfunctions start-execution --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$SM" \
        --input "$1" --query 'executionArn' --output text)"
    for _ in $(seq 1 60); do
        local st
        st="$(awsx stepfunctions describe-execution --execution-arn "$arn_out" --query 'status' --output text)"
        [ "$st" = "SUCCEEDED" ] || [ "$st" = "FAILED" ] || [ "$st" = "ABORTED" ] || { sleep 1; continue; }
        awsx stepfunctions describe-execution --execution-arn "$arn_out" --output json > "$2"
        echo "$arn_out" > /tmp/ho06_last_arn
        echo "$st"
        return 0
    done
    echo "TIMEOUT"; return 1
}

do_apply() {
    step "apply" "预清理残留（状态机/函数/日志，幂等）"
    awsx stepfunctions delete-state-machine --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$SM" >/dev/null 2>&1 || true
    for f in validate charge notify audit; do
        awsx lambda delete-function --function-name "ho06-$f" >/dev/null 2>&1 || true
        awsx logs delete-log-group --log-group-name "/aws/lambda/ho06-$f" >/dev/null 2>&1 || true
    done
    sleep 1; ok "无残留"

    step "apply" "打包并部署 4 个 Lambda（validate / charge / notify / audit）"
    for f in validate charge notify audit; do
        rm -f "/tmp/ho06_$f.zip"
        (cd functions && zip -q "/tmp/ho06_$f.zip" "$f.py")
        awsx lambda create-function --function-name "ho06-$f" \
            --runtime python3.12 --handler "$f.handler" --zip-file "fileb:///tmp/ho06_$f.zip" \
            --role "arn:aws:iam::000000000000:role/ho06-exec" --memory-size 256 --timeout 15 >/dev/null
    done
    for f in validate charge notify audit; do wait_fn_active "ho06-$f"; done
    ok "4 个函数 Active"

    step "apply" "创建状态机（声明式 ASL: configs/state-machine.asl.json）"
    awsx stepfunctions create-state-machine --name "$SM" \
        --definition "file://configs/state-machine.asl.json" \
        --role-arn "arn:aws:iam::000000000000:role/ho06-sfn" >/dev/null
    assert_eq "ACTIVE" "$(awsx stepfunctions describe-state-machine \
        --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$SM" \
        --query 'status' --output text)" "状态机 Active"
}

do_observe() {
    step "observe" "成功路径 seed=2：校验过 → 收款 → Parallel 双分支 → fulfilled"
    local st out
    st="$(run_sm '{"seed":2}' /tmp/ho06_run2.json)"
    assert_eq "SUCCEEDED" "$st" "执行成功"
    out="$(python3 -c 'import json; d=json.load(open("/tmp/ho06_run2.json")); print(d["output"])' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["decision"], d["fanout"][0]["notified"], d["fanout"][1]["audited"])')"
    assert_eq "fulfilled True True" "$out" "输出含 decision + 双分支结果"

    step "observe" "分支路径 seed=0：校验不过 → Choice 走 Rejected"
    st="$(run_sm '{"seed":0}' /tmp/ho06_run1.json)"
    assert_eq "SUCCEEDED" "$st" "执行成功"
    assert_eq "rejected" "$(python3 -c 'import json; print(json.load(open("/tmp/ho06_run1.json"))["output"])' | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')" "Choice 分支正确"

    step "observe" "重试+补偿路径 seed=3：收款失败 → Retry×2 耗尽 → Catch 进补偿"
    st="$(run_sm '{"seed":3}' /tmp/ho06_run3.json)"
    assert_eq "SUCCEEDED" "$st" "补偿后整体成功（不是 FAILED）"
    assert_eq "compensated" "$(python3 -c 'import json; print(json.load(open("/tmp/ho06_run3.json"))["output"])' | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')" "走到补偿分支"
    local arn
    arn="$(cat /tmp/ho06_last_arn)"
    # LocalStack 用旧版事件名（LambdaFunctionFailed 而非 TaskFailed），按失败次数验证重试
    local failures
    failures="$(awsx stepfunctions get-execution-history --execution-arn "$arn" \
        --query 'length(events[?type==`LambdaFunctionFailed`])' --output text)"
    assert_eq "3" "$failures" "Charge 失败 3 次（首跑 + Retry×2），重试真实发生"
}

do_clean() {
    step "clean" "删状态机与全部函数/日志"
    awsx stepfunctions delete-state-machine --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$SM" >/dev/null 2>&1 || true
    for f in validate charge notify audit; do
        awsx lambda delete-function --function-name "ho06-$f" >/dev/null 2>&1 || true
        awsx logs delete-log-group --log-group-name "/aws/lambda/ho06-$f" >/dev/null 2>&1 || true
    done
    sleep 1
    awsx stepfunctions list-state-machines --query "stateMachines[?name=='$SM']" --output text | grep -q . \
        && die "状态机仍存在" || ok "已删净，环境复原"
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

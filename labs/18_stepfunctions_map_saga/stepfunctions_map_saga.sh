#!/usr/bin/env bash
# =============================================================================
# 18 · Step Functions 深化 —— Map 动态并行 / Saga 补偿 / 错误分类 Retry / 回调探活
# 用法: ./stepfunctions_map_saga.sh [apply|observe|clean|all]   (默认 all)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="us-east-1"
SM="ho18-order-sm"

export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
awsx() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }

step()  { echo; echo "=====> [$1] $2"; }
ok()    { echo "  ✅ $*"; }
note()  { echo "  ⚠️  $*"; }
die()   { echo "  ❌ $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || die "$3 (期望 '$1' 实际 '$2')"; }

run_sm() { # $1=input $2=outfile
    local arn_out
    arn_out="$(awsx stepfunctions start-execution --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$SM" \
        --input "$1" --query 'executionArn' --output text)"
    for _ in $(seq 1 60); do
        local st
        st="$(awsx stepfunctions describe-execution --execution-arn "$arn_out" --query 'status' --output text)"
        case "$st" in SUCCEEDED|FAILED|ABORTED)
            awsx stepfunctions describe-execution --execution-arn "$arn_out" --output json > "$2"
            echo "$arn_out" > /tmp/ho18_arn; echo "$st"; return 0 ;;
        esac
        sleep 1
    done
    echo TIMEOUT
}

do_apply() {
    step "apply" "预清理 + 部署三个 Lambda（reserve/ship/cancel）"
    awsx stepfunctions delete-state-machine --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$SM" >/dev/null 2>&1 || true
    for f in reserve ship cancel; do
        awsx lambda delete-function --function-name "ho18-$f" >/dev/null 2>&1 || true
        awsx logs delete-log-group --log-group-name "/aws/lambda/ho18-$f" >/dev/null 2>&1 || true
    done
    sleep 1
    for f in reserve ship cancel; do
        rm -f "/tmp/ho18_$f.zip"
        (cd functions && zip -q "/tmp/ho18_$f.zip" "$f.py")
        awsx lambda create-function --function-name "ho18-$f" \
            --runtime python3.12 --handler "$f.handler" --zip-file "fileb:///tmp/ho18_$f.zip" \
            --role "arn:aws:iam::000000000000:role/ho18-exec" --memory-size 256 --timeout 15 >/dev/null
    done
    for f in reserve ship cancel; do
        for _ in $(seq 1 60); do
            [ "$(awsx lambda get-function --function-name "ho18-$f" --query 'Configuration.State' --output text)" = "Active" ] && break; sleep 1
        done
    done
    ok "三个函数 Active"

    step "apply" "创建状态机（Map + 补偿: configs/state-machine.asl.json）"
    awsx stepfunctions create-state-machine --name "$SM" \
        --definition "file://configs/state-machine.asl.json" \
        --role-arn "arn:aws:iam::000000000000:role/ho18-sfn" >/dev/null
    ok "状态机 Active"
}

do_observe() {
    step "observe" "成功路径：Map 并行发货 3 件（MaxConcurrency=2）"
    local st
    st="$(run_sm '{"seed":"good","items":[{"sku":"a","qty":1},{"sku":"b","qty":2},{"sku":"c","qty":1}]}' /tmp/ho18_g.json)"
    assert_eq "SUCCEEDED" "$st" "执行成功"
    assert_eq "fulfilled 3" \
        "$(python3 -c 'import json; d=json.loads(json.load(open("/tmp/ho18_g.json"))["output"]); print(d["decision"], d["count"])')" \
        "Map 全部完成，输出 3 件发货结果"

    step "observe" "失败路径：Reserve 失败（Retry 1 次耗尽）→ Compensate 取消"
    st="$(run_sm '{"seed":"bad","items":[{"sku":"x"}]}' /tmp/ho18_b.json)"
    assert_eq "SUCCEEDED" "$st" "补偿后整体成功"
    assert_eq "compensated" \
        "$(python3 -c 'import json; print(json.loads(json.load(open("/tmp/ho18_b.json"))["output"])["decision"])')" \
        "Saga 补偿路径生效"
    local arn; arn="$(cat /tmp/ho18_arn)"
    local reserve_fails
    reserve_fails="$(awsx stepfunctions get-execution-history --execution-arn "$arn" \
        --query 'length(events[?type==`LambdaFunctionFailed`])' --output text)"
    assert_eq "2" "$reserve_fails" "Reserve 失败 2 次（首跑 + Retry 1 次）"

    step "observe" "waitForTaskToken 回调模式探活"
    if awsx stepfunctions create-state-machine --name ho18-cb-probe \
        --definition '{"StartAt":"WaitTask","States":{"WaitTask":{"Type":"Task","Resource":"arn:aws:states:::lambda:invoke.waitForTaskToken","Parameters":{"FunctionName":"ho18-ship","Payload":{"token.$":"$$.Task.Token"}},"TimeoutSeconds":5,"End":true}}}' \
        --role-arn "arn:aws:iam::000000000000:role/ho18-sfn" >/dev/null 2>&1; then
        ok "回调模式状态机可创建（SendTaskSuccess 回调在本机可演练）"
        awsx stepfunctions delete-state-machine --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:ho18-cb-probe" >/dev/null 2>&1 || true
    else
        note "waitForTaskToken 模式此构建不支持（如实记录）"
    fi
}

do_clean() {
    step "clean" "删状态机/函数/日志"
    for sm in "$SM" ho18-cb-probe; do
        awsx stepfunctions delete-state-machine --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:$sm" >/dev/null 2>&1 || true
    done
    for f in reserve ship cancel; do
        awsx lambda delete-function --function-name "ho18-$f" >/dev/null 2>&1 || true
        awsx logs delete-log-group --log-group-name "/aws/lambda/ho18-$f" >/dev/null 2>&1 || true
    done
    sleep 1
    awsx stepfunctions list-state-machines --query "stateMachines[?starts_with(name, 'ho18')]" --output text | grep -q . \
        && die "仍有状态机残留" || ok "已删净，环境复原"
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

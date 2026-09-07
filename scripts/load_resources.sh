#!/usr/bin/env bash
# =============================================================================
# load_resources.sh — LocalStack 环境体检与启动（所有实验的公共前置）
#
# 用法:
#   bash scripts/load_resources.sh            # 体检：docker → 容器 → 健康端点 → 服务探针
#   bash scripts/load_resources.sh start      # 体检 + 自动启动未运行的 LocalStack
#   source scripts/load_resources.sh          # 在你的 shell 里获得 aws_local / wait_active 等函数
#
# 为什么需要它: LocalStack 最常见的坑不是"报错"而是"挂起"——调用读超时、
# 永不返回。开工前 30 秒探活，比跑到一半卡死省半小时。
# =============================================================================
set -euo pipefail

# 防本机代理(如 Clash :7890)劫持到 LocalStack 的连接——实测会导致挂起/ wedge
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_REGION:-us-east-1}"
CONTAINER="${LOCALSTACK_CONTAINER:-localstack-main}"

# 包装 aws CLI：自动指向 LocalStack + 防挂起超时 + 关闭分页
aws_local() {
    AWS_PAGER="" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" \
    aws --endpoint-url="$ENDPOINT" --region "$REGION" \
        --cli-connect-timeout 3 --no-cli-pager "$@"
}

# 等 DynamoDB 表到达 ACTIVE（LocalStack 建表是异步的，立刻查询偶发 ValidationError）
wait_active() { # $1=表名
    for _ in $(seq 1 20); do
        local st
        st="$(aws_local dynamodb describe-table --table-name "$1" --query 'Table.TableStatus' --output text 2>/dev/null || echo NONE)"
        [ "$st" = "ACTIVE" ] && return 0
        sleep 0.5
    done
    echo "❌ 表 $1 20 秒内未到 ACTIVE" >&2; return 1
}

# 等 Lambda 函数到达 Active（docker 拉起运行时需要几秒）
wait_lambda_active() { # $1=函数名
    for _ in $(seq 1 40); do
        local st
        st="$(aws_local lambda get-function --function-name "$1" \
            --query 'Configuration.State' --output text 2>/dev/null || echo NONE)"
        [ "$st" = "Active" ] && return 0
        sleep 1
    done
    echo "❌ Lambda $1 40 秒内未 Active（检查 docker.sock 是否挂进 LocalStack 容器）" >&2; return 1
}

probe_service() { # $1=服务名 $2=探活子命令...
    local svc="$1"; shift
    if aws_local "$svc" "$@" >/dev/null 2>&1; then
        echo "  ✅ $svc"
    else
        echo "  ❌ ${svc}（读超时/报错——试 docker restart ${CONTAINER}）"; return 1
    fi
}

do_probe() {
    echo "== 服务探针（短超时防挂起）=="
    local fail=0
    probe_service s3api list-buckets || fail=1
    probe_service dynamodb list-tables || fail=1
    probe_service sqs list-queues || fail=1
    probe_service lambda list-functions || fail=1
    probe_service sts get-caller-identity || fail=1
    [ "$fail" = 0 ] && echo "== 全部健康，可以开工 ==" || { echo "== 有服务不健康，处置: docker restart $CONTAINER 后重跑 =="; return 1; }
}

do_start() {
    if curl -s -m 3 "$ENDPOINT/_localstack/health" >/dev/null 2>&1; then
        echo "LocalStack 已在 $ENDPOINT 运行"
    else
        echo "LocalStack 未响应，尝试启动容器 $CONTAINER ..."
        docker start "$CONTAINER" 2>/dev/null || localstack start -d
        sleep 3
    fi
    do_probe
}

do_check() {
    echo "== 1/3 Docker ==";      docker info >/dev/null 2>&1 && echo "  ✅ docker 可用" || { echo "  ❌ docker 不可用"; return 1; }
    echo "== 2/3 LocalStack 健康端点 =="
    curl -s -m 3 "$ENDPOINT/_localstack/health" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  ✅", d.get("services",{}).get("s3","?"), "…")' \
        || { echo "  ❌ $ENDPOINT 无响应——bash $0 start"; return 1; }
    echo "== 3/3 客户端 =="
    command -v aws    >/dev/null && echo "  ✅ aws     $(aws --version 2>&1 | cut -d' ' -f1)" || echo "  ⚠️ 缺 aws CLI (brew install awscli)"
    python3 -c "import boto3" 2>/dev/null && echo "  ✅ boto3" || echo "  ⚠️ 缺 boto3 (pip3 install boto3 requests)"
    do_probe
}

# DynamoDB provider 起不来（报 "gave up waiting for service dynamodb to start"）：
# 多半是 dynamodb-rust 二进制下载被截断（残片无执行位），且失败状态被进程缓存。
# 修复 = 删残片 + 重启容器 + 首个调用触发重新下载：
fix_dynamodb() {
    local bin="/var/lib/localstack/lib/dynamodb-rust/0.1.12/linux-arm64"
    echo "== 修复 DynamoDB provider =="
    docker exec "$CONTAINER" rm -f "$bin" 2>/dev/null && echo "  已删除残片(若存在): $bin"
    docker restart "$CONTAINER" >/dev/null && echo "  容器已重启"
    sleep 8
    AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
        aws --endpoint-url "$ENDPOINT" --region "$REGION" \
        --cli-connect-timeout 5 --cli-read-timeout 180 dynamodb list-tables >/dev/null \
        && echo "  ✅ DynamoDB 已恢复（二进制已重新下载）" \
        || { echo "  ❌ 仍未恢复，docker logs $CONTAINER 看详情"; return 1; }
}

case "${1:-check}" in
    check) do_check ;;
    start) do_start ;;
    probe) do_probe ;;
    fix-dynamodb) fix_dynamodb ;;
    *) echo "用法: $0 [check|start|probe|fix-dynamodb]" >&2; exit 1 ;;
esac

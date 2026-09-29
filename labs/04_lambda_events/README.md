# 04 · Lambda 函数与事件驱动：从手动调用到自动触发

> AWS Lambda 是一种"上传函数代码、由事件触发执行"的无服务器计算服务：不管理
> 服务器，按调用计费。本实验在本机完成函数部署、同步调用、S3 与 DynamoDB
> Streams 两种事件源接入、错误演示与日志验证，共 10 项真实断言。

## Background

在无服务器计算普及之前，让"文件一上传就处理"这类自动化靠常驻服务器：自己写
轮询脚本或消息消费者，配 systemd/supervisor 守护，空闲时也照常烧钱。

常驻方案撞上两堵墙。第一，绝大多数时间没有事件，服务器空转，成本与利用率
倒挂——守护进程要靠 systemd/supervisor（把脚本变成常驻后台服务的 Linux
工具）看管。

第二，事件量突增时要手工扩容，响应永远慢一拍。Lambda（AWS 2014 年推出）把
模型反过来：开发者只上传函数并声明"哪类事件给我哪个函数"，平台负责拉起执行
环境、投递事件、重试失败与自动扩容，计费精确到毫秒。

## What

一句话定义：Lambda 是一种事件驱动的函数计算服务——把一段代码（handler，处理
函数）与一个或多个事件源绑定，事件到达时平台以容器方式执行它。

心智模型：可以把 Lambda 想象成"按铃即跑的钟点工"——你把工位（执行环境）和
技能（代码）备好，铃（事件）一响它就出现，做完即走。但和真实钟点工不同的是：
同时来 100 个铃它会雇 100 个临时工并行处理，而铃响过两次就可能让同一个工重复
劳动（至少一次投递），所以处理逻辑要能容忍重复。

三种入口决定了调用语义：

- **同步调用**（`invoke`）：调用方等待返回值，错误直接抛给调用方。
- **异步调用**：事件源触发，失败自动重试，重试耗尽进死信目的地。
- **事件源映射**：平台替你从流（如 DynamoDB Streams）按序拉取并批量调用。

## When to Use

典型场景：

- 粘合代码（glue code）：S3 来了张图片要生成缩略图、DynamoDB 一条记录变更要
  写审计——几行逻辑不值得养一台服务器。
- 突发流量的事件处理：上传高峰、消息洪峰，Lambda 自动扩容到并发上限。
- 定时任务：配合 EventBridge（AWS 的事件路由服务，见 lab 11）做定时触发，
  替代传统的 crontab 定时任务。

何时不用：需要长连接或超长执行（单次上限 15 分钟）时用 ECS/Fargate（AWS 的
容器运行服务）；对冷启动（首次调用前拉起执行环境的延迟）
延迟极端敏感（<100ms）的高频 API 用常驻服务；函数间需要频繁共享大量内存状态
时也不合适。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Lambda | 事件驱动、毫秒计费、15 分钟上限 | 事件处理、粘合代码、定时任务 |
| Fargate | 容器级无服务器，长任务/自定义运行时 | 长时任务、需要完整容器环境 |
| EC2 | 完全控制的虚拟机 | 常驻高负载、特定内核/网络需求 |

## Quick Start

前置条件：LocalStack 容器挂载了 docker.sock（Lambda 运行时以容器方式拉起），
本机已预载 `public.ecr.aws/lambda/python:3.12` 镜像。运行方式：

```bash
cd labs/04_lambda_events
./lambda_events.sh            # apply → observe → clean（约 60 秒，含容器冷启动）
./lambda_events.sh apply      # 部署函数 + 挂事件源
./lambda_events.sh observe    # 手动调用 / 错误 / S3 触发 / Streams 触发 / 日志
./lambda_events.sh clean      # 全部删净
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 手动调用：同步 Invoke 返回 echo 结果
  ✅ 手动调用回显正确
=====> [observe] S3 事件触发：上传 a.json（应触发）与 b.txt（后缀过滤不应触发）
  ✅ 审计表只有 1 条 s3 事件（.txt 被后缀过滤挡住）
=====> [observe] DynamoDB Streams 触发：写源表 → Lambda 消费流记录写审计表
  ✅ 审计表收到 1 条 stream 事件（INSERT）
=====> [observe] 日志验证：CloudWatch Logs 里能看到函数的结构化输出
  ✅ 日志含: S3 event processed
```

函数代码的核心是入口解析与端点处理（`lambda_function.py`）：

```python
def resolve_endpoint():
    # 运行时容器里 localhost≠LocalStack；注入变量是 LOCALSTACK_HOSTNAME（旧版/新版本名不同）
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")

def handler(event, context):
    for r in event.get("Records", []):
        if "s3" in r:            # S3 通知：r["s3"]["object"]["key"] 要 unquote_plus
            ...
        elif r.get("eventSource", "").startswith("aws:dynamodb"):   # Streams 记录
            ...   # Keys 是 DynamoDB JSON（带类型标记），eventName=INSERT/MODIFY/REMOVE
```

新手第一个失败点：函数内访问 LocalStack 服务报 `EndpointConnectionError`——
运行时是独立容器，`localhost:4566` 不是 LocalStack，必须用注入的
`LOCALSTACK_HOSTNAME` 拼端点（见下文 How It Works）。

## How It Works

![Lambda 事件驱动](images/lambda_events.svg)

> 怎么看：左侧手动 Invoke 走同步路径、立刻返回结果；中间 S3 上传 `.json`（后缀
> 过滤）和右侧 DynamoDB Streams 是两条异步事件路径，函数把"看到的事件"写进审计
> 表；每次调用都留 CloudWatch 日志。注意函数写的是**审计表**不是流源表——否则
> 自己触发自己，死循环。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/04_lambda_events/images/lambda_events.html)
> （或本地打开 [`images/lambda_events.html`](images/lambda_events.html)）。

**部署四要素与 Active 等待**：`create-function` 需要 zip 包（`--zip-file
fileb://`，二进制格式）、runtime、handler（`文件名.函数名`）和 role。

创建后函数处于 `Pending`，必须轮询到 `State=Active` 才能调用——脚本的
`wait_fn_active` 每 1 秒查一次，实测容器方式冷启动 3~5 秒。

**同步与异步的差异**：同步 `invoke` 的错误直接进响应体（带 `errorType` 堆栈，
脚本断言验证过）；事件源触发的异步调用失败会自动重试——本实验日志里能看到
同一 RequestId 隔一分钟重跑，重试耗尽后事件进死信目的地（lab 16 演示）。

**网络陷阱（本实验最大的坑）**：函数运行在独立容器里，它眼中的
`localhost:4566` 是它自己。LocalStack 向运行时注入
`LOCALSTACK_HOSTNAME=<可达地址>`（实测 `192.168.215.2`），`resolve_endpoint()`
用它拼出正确的服务端点。

排错第一入口是 CloudWatch Logs 的 ERROR 行——`EndpointConnectionError` 基本
都源于这里。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **调用报 `ResourceConflictException` / 执行超时**：函数尚未 `Active`。解法：
  轮询 `get-function --query Configuration.State`。
- **`--zip-file file://` 报 base64 错误**：zip 是二进制。解法：改用
  `fileb://`。
- **函数内连不上 LocalStack**：运行时容器网络隔离，`localhost` 指向自身。
  解法：用 `LOCALSTACK_HOSTNAME` 拼 endpoint（见 Quick Start 的代码）。
- **流处理函数触发死循环**：函数把结果写回同一张开了流的表，新写入再次触发
  自己。解法：审计写入落到另一张表（本实验的做法）。
- **S3 通知的 key 是乱码**：事件里的 key 经过 URL 编码。解法：
  `urllib.parse.unquote_plus` 还原。

深入问答：

- **Q: 冷启动是什么？如何缓解？** A: 首次调用要拉起执行环境（本实验 3~5 秒）。
  缓解手段：初始化代码放 handler 外、调大内存、Provisioned Concurrency 预热。
- **Q: 异步调用失败会怎样？** A: 自动重试 2 次（共 3 次执行），仍失败进
  OnFailure Destination（SQS/SNS/EventBridge），事件本身不丢。
- **Q: S3 通知和 EventBridge 通知怎么选？** A: 前者直连目标、配置简单；后者先
  进总线，可模式匹配、多目标、存档重放（lab 13 有对比实战）。
- **Q: DynamoDB Streams 与 Kinesis 的消费模型差异？** A: Streams 每分区一个
  迭代器、按序拉取，事件源映射代管进度；Kinesis 是通用流，分片吞吐固定、
  支持多消费者（lab 12 展开）。
- **Q: 为什么函数写源表会死循环？** A: 写入产生新流记录再次触发函数；破法是
  写别的表、按 eventName 过滤，或跳过自己产生的记录。

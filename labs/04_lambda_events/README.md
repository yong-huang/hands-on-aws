# 04 · Lambda 函数与事件驱动：从手动调用到自动触发

> 前三个实验里，所有动作都是"你"发起的。真实系统里，文件一上传就要被处理、数据
> 一变更就要被审计——**事件驱动**让代码在事件发生的瞬间自己跑起来。Lambda 就是为
> 此而生：不用管服务器，把函数挂到事件源上，剩下的交给平台。本实验在本地完成
> 部署、手动调用、两种事件源接入和日志验证。

## 1. 为什么需要它

- ** glue code**：S3 来了张图片要缩略、DynamoDB 一条记录变更要发审计——这类
  "小逻辑"不值得养一台服务器，Lambda 按调用计费到毫秒。
- **事件源模型**是 Lambda 的精髓：你不写"轮询循环"，只声明"哪个事件给我哪个函数"，
  平台负责投递、重试、扩容。
- 理解它，后面 10 个实验里的每一次"自动联动"都是同一套模型。

## 2. 总览：核心机制一图看懂

![Lambda 事件驱动](images/lambda_events.svg)

> 怎么看：左侧手动 Invoke 走同步路径、立刻返回结果；中间 S3 上传 `.json`（后缀
> 过滤）和右侧 DynamoDB Streams 是两条异步事件路径，函数把"看到的事件"写进审计
> 表；每次调用都留 CloudWatch 日志。注意函数写的是**审计表**不是流源表——否则
> 自己触发自己，死循环。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/04_lambda_events/images/lambda_events.html)
> （或本地打开 [`images/lambda_events.html`](images/lambda_events.html)）。

心智模型一句话：**函数不找事件，事件找函数；同步调用要结果，异步调用要可靠。**

## 3. 快速开始

```bash
cd labs/04_lambda_events
./lambda_events.sh            # apply → observe → clean（约 60 秒，含容器冷启动）
./lambda_events.sh apply      # 部署函数 + 挂事件源
./lambda_events.sh observe    # 手动调用 / 错误 / S3 触发 / Streams 触发 / 日志
./lambda_events.sh clean      # 全部删净
```

真实运行输出（节选）：

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

## 4. 核心概念

### 4.1 部署四要素与 Active 等待

zip 包（`fileb://` 二进制）+ runtime + handler（`文件名.函数名`，下划线）+ role
（LocalStack 不校验但结构保持真实）。创建后函数是 `Pending`，**必须轮询到
`State=Active` 才能调用**——本实验 `wait_fn_active` 每 1 秒查一次。

### 4.2 同步 vs 异步调用

- 同步（`invoke`）：结果直接返回，错误时响应体带 `errorType` 堆栈（实测）；
- 异步（事件源触发）：失败自动重试（实测日志里可见同一 RequestId 隔一分钟重跑），
  重试耗尽进 Destination/DLQ（lab 16 深化）。

### 4.3 事件源是两种"拉"法

S3 通知是**推**模型（S3 直接调函数，可按前后缀过滤）；DynamoDB Streams 是**拉**
模型（事件源映射按 ShardIterator 顺序拉流记录，天然保序、批量化）。两者在本实验
都被路由进同一个 handler——函数内部按 `Records[].eventSource` 分派。

### 4.4 函数访问 LocalStack 的网络陷阱（本实验最大的坑）

Lambda 运行时是**独立容器**，里面的 `localhost:4566` 不是 LocalStack！本机实测：
LocalStack 向运行时注入 `LOCALSTACK_HOSTNAME=192.168.215.2`，函数必须用它拼
endpoint（见 `lambda_function.py` 的 `resolve_endpoint()`）。日志里的
`EndpointConnectionError` 就是踩坑现场——这也是排错的第一入口：**先看
CloudWatch Logs 的 ERROR 行**。

## 5. 代码关键字段（lambda_function.py）

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

坑清单：

- S3 通知的 key 是 URL 编码的，中文/空格文件名必须 `unquote_plus`；
- `--zip-file` 用 `fileb://`（二进制），`file://` 会因 base64 报错；
- 流处理函数写回**同一张开流的表** = 死循环；审计写入要落到别的表；
- 内存 128MB 对 python runtime 偏紧，256MB 起步更稳。

## 6. 文件结构

```text
labs/04_lambda_events/
├── README.md               # 本文件
├── lambda_events.sh        # 主演示脚本：部署/挂事件源/四种演示/清理
├── lambda_function.py      # 真实函数代码：路由 S3 事件、Streams 记录、手动调用
└── images/
    ├── lambda_events.architecture.json  # 架构图源（Typed JSON IR）
    ├── lambda_events.html               # 交互版架构图
    └── lambda_events.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: Lambda 冷启动是什么？如何缓解？** A: 首次调用要拉起执行环境（本实验容器
  方式冷启动 3~5 秒）；缓解：内存调大、初始化放 handler 外、Provisioned
  Concurrency、Snappy 运行时。
- **Q: 异步调用失败会怎样？** A: 自动重试 2 次（共 3 次执行），仍失败进
  OnFailure Destination（SQS/SNS/EventBridge），事件本身不丢。
- **Q: S3 通知和 EventBridge 通知怎么选？** A: 前者直连目标、配置简单；后者先进
  总线，可模式匹配、多目标、存档重放（lab 13 对比实战）。
- **Q: DynamoDB Streams 与 Kinesis 的消费模型差异？** A: Streams 每分区一个
  ShardIterator、按序拉取，事件源映射帮你管理 checkpoint；Kinesis 是通用流，
  分片吞吐固定、支持多消费者（lab 12 展开）。
- **Q: 为什么函数写源表会死循环？怎么破？** A: 写入产生新流记录再次触发函数；
  破法：写别的表/前缀、按 eventName 过滤、或用过滤条件跳过自己产生的记录。

## 8. 总结

一条函数，三种入口：同步 Invoke 要结果，S3 通知做"文件到了"，Streams 做"数据
变了"——无服务器事件驱动的主干模型建立完毕。下一篇在函数前面立一扇门：API
Gateway 把 HTTP 请求路由给 Lambda，做成真正的前端可调用 REST API。

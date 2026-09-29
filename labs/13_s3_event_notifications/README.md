# 13 · S3 事件通知全景：一次上传，四路并发

> Amazon S3 的事件通知（event notification）机制允许一个桶把"对象创建/删除"
> 事件并发投递给多个目标（SQS / SNS / Lambda / EventBridge），每个目标可独立
> 配置前后缀过滤。本实验一次挂四路通知，对照验证过滤语义，并把"上传 CSV →
> 解析 → 入库"做成端到端管道。

## Background

在事件通知普及之前，"文件上传后触发处理"靠轮询：应用定时 `list-objects` 对比
上次快照，找出新增文件再处理。

轮询模式撞上三堵墙。第一，延迟与成本的跷跷板——轮询间隔短则 API 调用费钱，
间隔长则处理延迟以分钟计。第二，新增下游要改轮询代码，多个消费者互相踩脚。
第三，海量小文件时列表调用爆炸。S3 事件通知（原生支持）把模型反过来：文件
落地那一刻，S3 主动把事件推给订阅的目标——零轮询、秒级延迟、多目标并发。

## What

一句话定义：S3 事件通知是一种桶级配置——声明"哪些事件（按类型与前后缀过滤）
投递给哪些目标"，目标可以是 SQS 队列、SNS 主题、Lambda 函数或 EventBridge
总线。

心智模型：可以把通知配置想象成小区门卫的访客登记簿规则——"快递员来了通知
501 室（按前缀过滤）、外卖来了广播全楼（全量）"。但和真实门卫不同的是：规则
是机器执行的、毫秒级并发触发，而且一个规则集可以同时指定四类目标。

四路目标（本实验一次配置）：

- **SQS 队列**：后缀 `.csv` 过滤——只有 CSV 落地才投递。
- **SNS 主题 → 订阅队列**：无过滤全量投递。
- **Lambda 函数**：前缀 `data/` 过滤——只处理数据目录。
- **EventBridge**：开关型配置，事件进中央总线获得模式匹配能力。

## When to Use

典型场景：

- 文件处理管道：上传 CSV → 解析 → 数据库入库（本实验的端到端演示）。
- 多下游扇出：缩略图生成、病毒扫描、数据入湖，各自独立订阅互不阻塞。
- 事件总线接入：文件事件进 EventBridge 后获得模式匹配、多目标与归档重放
  （lab 11 的能力）。

何时不用：上游是计算任务直接产出结果（不经 S3）；只需单一下游且无过滤需求
时直接配 Lambda 目标即可，不必四路全开。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| S3 通知配置 | 直连目标、配置简单、秒级延迟 | 下游固定、目标少 |
| S3 → EventBridge | 事件进总线，模式匹配/归档重放 | 下游多、路由复杂、要重放 |
| 定时轮询 | 无事件依赖、延迟分钟级 | 存量桶、无法开通知的场景 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/13_s3_event_notifications
./s3_event_notifications.sh            # 建四路通知 → 两次上传对照 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 基线清零，然后上传 data/a.csv（2 行数据）→ 四路并发
  ✅ SQS 收到 .csv 事件（后缀过滤命中，1 条）
  ✅ SNS 订阅队列收到事件（全量 1 条）
  ⚠️  EventBridge 转发未生效（此构建范围限制），以其余三路为准
=====> [observe] Lambda 解析 CSV → DynamoDB 落库（管道端到端）
  ✅ CSV 的 2 行数据全部入库
=====> [observe] 对照：上传 other/b.txt → 只有 SNS 全量路收到
  ✅ SQS 增量 0（.txt 未过 .csv 后缀过滤）
  ✅ SNS 增量 +1（.txt 无过滤全收）
```

四路通知来自一份声明式配置（`put-bucket-notification-configuration`），核心
片段：

```jsonc
{
  "QueueConfigurations": [{
    "QueueArn": "arn:aws:sqs:...:ho13-csv-q",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {"Key": {"FilterRules": [
      {"Name": "suffix", "Value": ".csv"}     // 还可叠加 {"Name":"prefix","Value":"data/"}
    ]}}
  }],
  "EventBridgeConfiguration": {}               // 空对象 = 开关：事件进 default 总线
}
```

新手第一个失败点：SNS/SQS 目标在真实 AWS 需要资源策略授权（脚本已挂
`configs/queue-policy-sns-send.json` 的同款策略）；LocalStack 不校验但保留
正确姿势。

## How It Works

![S3 事件通知全景](images/s3_event_notifications.svg)

> 怎么看：一个 NotificationConfiguration 同时声明四路——SQS（后缀 .csv）、
> SNS（全量）、Lambda（前缀 data/）、EventBridge（总线开关）。上传 `data/a.csv`
> 四路全响（EventBridge 此构建未生效，见下）；上传 `other/b.txt` 只有 SNS 动。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/13_s3_event_notifications/images/s3_event_notifications.html)
> （或本地打开 [`images/s3_event_notifications.html`](images/s3_event_notifications.html)）。

**过滤语义如何对照验证**：脚本先清零三路目标再上传两次——`data/a.csv` 命中
SQS（.csv 后缀）、Lambda（data/ 前缀）、SNS（全量）；`other/b.txt` 只有 SNS
增量。

断言用"增量"而非绝对数，因为本构建一次 put-object 可能双发（Put+Post 两种
事件，非确定性），真实 AWS 每次上传只发一条。

**CSV 解析管道如何工作**：事件只携带指针（bucket + key），Lambda 收到后
`get_object` 拉回文件内容，`csv.DictReader` 逐行解析并 `put_item` 入
DynamoDB——实测 2 行数据全部入库且内容正确。

"事件传指针、数据自己取"是事件驱动管道的标准形状，天然幂等（同 key 重传覆盖
同主键）。

**EventBridge 路由的本机边界**：`put-rule` 能建、`EventBridgeConfiguration`
能开，但事件未到达目标队列（Community 构建范围限制，实测如实记录）。真实 AWS
中这条线与 lab 11 的总线能力完全打通。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **通知配置整体覆盖**：`put-bucket-notification-configuration` 是替换式
  API——更新前必须先 get 现有配置合并，否则会抹掉其它目标。
- **事件里的 key 是乱码/带 + 号**：事件中的 key 是 URL 编码。解法：
  `urllib.parse.unquote_plus` 还原后再取文件。
- **双发事件导致重复处理**：本构建可能对一次上传发两条事件。解法：下游幂等
  （同 key 覆盖 / 条件写），脚本断言用增量。
- **EventBridge 路由无事件**：本构建范围限制（实测如实记录）。解法：真实 AWS
  验证该路线。

深入问答：

- **Q: S3 通知与 S3→EventBridge 怎么选？** A: 单一目标、低延迟选通知配置；
  多下游、模式匹配、归档重放选 EventBridge。
- **Q: 通知会丢吗？** A: 至少一次投递，消费者要幂等；目标不可达时 S3 重试，
  持续失败可订阅"通知失败"事件。
- **Q: 海量小文件上传会打爆下游吗？** A: 会。过滤规则缩小命中面 + 队列削峰 +
  Lambda 并发上限；极端场景前置队列缓冲。
- **Q: 如何做到"恰好一次"处理？** A: 事件侧至少一次不可避免；业务侧用
  (bucket、key、etag——上传时生成的文件内容指纹——三元组作幂等键)写库，重复事件零副作用。

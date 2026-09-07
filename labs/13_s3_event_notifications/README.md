# 13 · S3 事件通知全景：一次上传，四路并发

> lab 04 里 S3 通知只有一个 Lambda 目标；真实管道要求"文件一落地，队列、主题、
> 函数、事件总线**同时**知道"。本实验一次挂四路通知（各自带前后缀过滤），并把
> "上传 CSV → 解析 → 入库"做成端到端管道。

## 1. 为什么需要它

- **一次上传、扇出到 N 个系统**：杀毒扫描、缩略图、数据入湖——各自独立、
  各有过滤，互不阻塞。
- **前后缀过滤是路由的第一道闸**：`*.csv` 进解析管道，`.txt` 不惊动任何人。
- S3→EventBridge 开关让文件事件进入中央总线（lab 11），获得模式匹配与重放能力。

## 2. 总览：核心机制一图看懂

![S3 事件通知全景](images/s3_event_notifications.svg)

> 怎么看：一个 NotificationConfiguration 同时声明四路——SQS（后缀 .csv）、
> SNS（全量）、Lambda（前缀 data/）、EventBridge（总线开关）。上传 `data/a.csv`
> 四路全响（EventBridge 此构建未生效，见 4.4）；上传 `other/b.txt` 只有 SNS 动。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/13_s3_event_notifications/images/s3_event_notifications.html)
> （或本地打开 [`images/s3_event_notifications.html`](images/s3_event_notifications.html)）。

心智模型一句话：**桶是事件源，通知配置是路由表，过滤规则决定谁被惊动。**

## 3. 快速开始

```bash
cd labs/13_s3_event_notifications
./s3_event_notifications.sh            # 建四路通知 → 两次上传对照 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] 基线清零，然后上传 data/a.csv（2 行数据）→ 四路并发
  ✅ SQS 收到 .csv 事件（后缀过滤命中，1 条）
  ✅ SNS 订阅队列收到事件（全量 1 条）
  ⚠️  EventBridge 转发未生效（此构建范围限制），以其余三路为准
  ✅ CSV 的 2 行数据全部入库
=====> [observe] 对照：上传 other/b.txt → 只有 SNS 全量路收到
  ✅ SQS 增量 0（.txt 未过 .csv 后缀过滤）
  ✅ SNS 增量 +1（.txt 无过滤全收）
```

## 4. 核心概念

### 4.1 一份配置、四类目标

`put-bucket-notification-configuration` 一次性声明 QueueConfigurations /
TopicConfigurations / LambdaFunctionConfigurations / EventBridgeConfiguration——
同一上传并发触发所有命中路径。注意是**整体替换式 API**：更新要先 GET 再合并
PUT，直接 PUT 会抹掉别的路。

### 4.2 过滤规则：前缀 × 后缀

每路目标独立配置 `FilterRules`（prefix / suffix 可组合）。本实验实测对照：
`data/a.csv` 命中 SQS（.csv）+ Lambda（data/）+ SNS；`other/b.txt` 只有 SNS。

### 4.3 CSV 解析管道

Lambda 收到事件 → `get_object` 拉回文件 → `csv.DictReader` 逐行 → `put_item`
入 DynamoDB。**事件只给"指针"（bucket+key），数据自己取**——这是事件驱动
管道的标准形状，天然幂等（同 key 重传覆盖同主键）。

### 4.4 本机实测差异（如实记录）

- EventBridge 路由：`put-rule` 能建、通知配置能开，但事件**未到达**目标队列
  （Community 构建范围限制），如实标注；S3→EventBridge 全链路在真实 AWS 验证；
- 一次 `put-object` 可能双发通知（Put+Post 两种事件，非确定性），真实 AWS 只发
  一条——断言全部用"增量"而非绝对数，消费者天然要幂等。

## 5. 配置关键字段（通知配置节选）

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

坑清单：

- 通知配置是替换式更新，先 get 再合并；
- Lambda 目标要给 `s3.amazonaws.com` 授 `lambda:InvokeFunction`（真实 AWS 必须）；
- SNS/SQS 目标同样要资源策略授权（lab 03 的 queue policy 套路）；
- 事件里的 key 是 URL 编码，取文件前必须 `unquote_plus`。

## 6. 文件结构

```text
labs/13_s3_event_notifications/
├── README.md                       # 本文件
├── s3_event_notifications.sh       # 主演示脚本：四路通知 + 对照实验 + 管道验证
├── csv_parser.py                   # 管道 Lambda：CSV → DynamoDB
└── images/
    ├── s3_event_notifications.architecture.json  # 图源（Typed JSON IR）
    ├── s3_event_notifications.html               # 交互版
    └── s3_event_notifications.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: S3 通知与 S3→EventBridge 怎么选？** A: 单一目标、低延迟选通知配置；
  多目标/模式匹配/跨账户/归档重放选 EventBridge（事件先进总线再路由）。
- **Q: 通知会丢吗？** A: S3 至少一次投递，消费者要幂等；SQS/SNS 目标不可达时
  S3 会重试，持续失败可配通知失败事件。
- **Q: 大量小文件上传会打爆下游吗？** A: 会。过滤规则缩小命中面 + 下游队列削峰
  （Lambda 并发上限）+ EventBridge 缓冲归档。
- **Q: 同名覆盖上传触发几次 ObjectCreated？** A: 每次成功写一次；分片上传有
  CompleteMultipartUpload 事件，按需订阅（本机 mock 的 Put+Post 双发是模拟器
  特性，真实 AWS 不会）。
- **Q: 如何做到"文件处理恰好一次"？** A: 事件侧至少一次不可避免；业务侧用
  (bucket,key,etag) 作幂等键写库（条件写），重复事件零副作用。

## 8. 总结

四路并发通知 + 过滤路由 + CSV 解析入库——"文件落地即处理"的完整管道成型，
事件只传指针、数据自己拉取、消费天然幂等三个原则全部落地。下一篇专攻消息的
可靠性工程：幂等、毒丸、重驱与 FIFO 深水区。

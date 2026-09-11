# 21 · CloudWatch Logs：结构化日志与实时管道

> print 出来的日志散在各处只是"看见了"；可观测性要求日志**可查询、可聚合、可
> 订阅**。本实验把 CloudWatch Logs 的全家桶跑通：结构化 JSON 写入、Metric Filter
> 变指标、Subscription Filter 实时清洗落库、保留策略控成本。

## 1. 为什么需要它

- 排错时 grep 是奢侈品，`{ $.level = "ERROR" }` 这样的**字段查询**才是常态——
  前提是日志是结构化 JSON。
- ERROR 计数应该自动变成指标、触发告警（lab 22），而不是人肉翻页。
- 新日志实时推给清洗函数入库，是日志分析平台的"进水口"（lab 30 的地基）。

## 2. 总览：核心机制一图看懂

![CloudWatch Logs](images/cloudwatch_logs.svg)

> 怎么看：应用把 JSON 日志写进日志组（实线主路径）；Metric Filter 挂在日志组上
> 把 ERROR 行变成 CloudWatch 指标；Subscription Filter 把每条日志实时推给清洗
> Lambda 落库（虚线）；保留策略管整组的生命周期。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/21_cloudwatch_logs/images/cloudwatch_logs.html)
> （或本地打开 [`images/cloudwatch_logs.html`](images/cloudwatch_logs.html)）。

心智模型一句话：**日志组是容器，过滤器是两条旁路——一条变指标，一条进管道。**

## 3. 快速开始

```bash
cd labs/21_cloudwatch_logs
./cloudwatch_logs.sh            # 建组 → 写日志/挂过滤器 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] 写入结构化 JSON 日志（含 ERROR 级别）
  ✅ 日志可查询（3 条）
=====> [observe] Subscription Filter → Lambda 实时清洗（支持度探活）
  ✅ Subscription Filter 生效：Lambda 清洗落库（1 条）
=====> [observe] 保留策略：设 7 天过期
  ✅ 保留策略 7 天生效
```

## 4. 核心概念

### 4.1 组 / 流 / 事件三级结构

LogGroup（应用级）→ LogStream（实例/日期级）→ LogEvents（逐条）。写事件必须
指定流；同流内按时间有序。本实验按日期建流 `app-YYYYMMDD`。

### 4.2 Metric Filter：日志变指标

`{ $.level = "ERROR" }` 按**字段值**匹配 JSON 日志，命中即向 `AppErrors` 指标
贡献 1。它让"错误率"可以直接进告警（lab 22），无需改应用代码。

### 4.3 Subscription Filter：日志的实时出口

匹配的日志（空 pattern = 全量）实时投给 Lambda——本机实测：新写的 ERROR 日志
被清洗函数解析后落进 DynamoDB。投递的数据是 gzip+base64 的封装，函数里要解包。

### 4.4 保留策略

默认**永不过期**（账单刺客），生产按合规要求设 7~90 天。实测 put-retention-
policy 后 describe 可见 7。

## 5. 命令关键字段

```bash
awslocal logs put-log-events --log-group-name /ho21/app \
  --log-stream-name app-20260907 --log-events file://events.json

awslocal logs put-metric-filter --filter-name err \
  --filter-pattern '{ $.level = "ERROR" }' \
  --metric-transformations '[{"metricName":"AppErrors","metricNamespace":"Ho21","metricValue":"1"}]'

awslocal logs put-subscription-filter --filter-name to-lambda \
  --destination-arn arn:aws:lambda:...:ho21-cleaner
```

坑清单：

- **容器时钟漂移**：put-log-events 的时间戳"太新"会被静默拒绝（tooNewLogEvent），
  本机实测需回拨 3 小时——写日志必须检查 rejectedLogEventsInfo；
- 事件 JSON 里嵌引号，CLI 直接拼必炸——用 python 构造 payload 文件；
- Subscription 投递体是 gzip+base64，Lambda 里 `gzip.decompress` 解包；
- Metric Filter 只对**新写入**的日志生效，历史日志不会补算。

## 6. 文件结构

```text
labs/21_cloudwatch_logs/
├── README.md              # 本文件
└── cloudwatch_logs.sh     # 主脚本：建组 → 写日志/双过滤器/保留 → 清理
                           # 清洗 Lambda 由脚本生成（/tmp），核心逻辑见脚本内嵌
```

> 注：图片三件套见 `images/`。

## 7. 深入要点

- **Q: 结构化日志的好处？** A: 字段级查询/过滤/聚合、Metric Filter 直接解析、
  采集管道免正则——纯文本日志的可观测性成本高一个数量级。
- **Q: Metric Filter 与应用埋点的取舍？** A: Filter 免改代码、按模式统计；
  埋点语义更丰富（维度、单位）。高频核心指标埋点，长尾问题用 Filter。
- **Q: Subscription Filter 的投递语义？** A: 近实时、至少一次；Lambda 目标限流
  时会重试，下游要幂等。
- **Q: 日志成本治理？** A: 保留策略、日志级别动态调整、Agent 过滤冷字段、
  大字段进 S3（log 本体只留引用）。
- **Q: 为什么日志时间戳会被拒绝？** A: put-log-events 要求时间戳单调且在合法
  窗口内（默认 2 小时前后）；容器/宿主时钟漂移是经典事故源。

## 8. 总结

结构化写入、两条过滤器旁路、保留策略——日志从"看得见"升级为"可计算、可流转"。
下一篇把指标变成告警：Alarm 状态机与通知闭环。

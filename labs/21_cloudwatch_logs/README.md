# 21 · CloudWatch Logs：结构化日志与实时管道

> Amazon CloudWatch Logs 是托管日志服务：日志按"组—流—事件"三级组织，支持
> 字段级查询、从日志提取指标、订阅实时投递。本实验跑通结构化 JSON 写入、
> Metric Filter 变指标、Subscription Filter 实时清洗落库与保留策略，共 7 项
> 真实断言。

## Background

在托管日志服务普及之前，应用日志靠"写本地文件 + 自建采集"：应用 print 到
stdout 或文件，采集脚本（rsyslog/Filebeat 类）搬运到自建 Elasticsearch。

自建管道撞上三堵墙。第一，查询靠正则：日志是纯文本，提取"某个请求的错误数"
要写脆弱的正则。第二，检索与存储要自己运维：ES 集群的扩容、分片（把数据切开存到多台机器）、保留期全是
运维负担。第三，实时消费要自建消息管道。

CloudWatch Logs（AWS 原生）把这些
产品化：结构化 JSON 日志支持字段级查询语法，Metric Filter 可以把匹配行变成
CloudWatch 指标，Subscription Filter 把日志实时推给 Lambda。

## What

一句话定义：CloudWatch Logs 是一种三级结构的托管日志服务——日志组（log
group，应用级容器，保留策略挂在这）包含日志流（log stream，实例/日期级的
有序追加序列），流内是逐条日志事件。

心智模型：可以把日志组想象成一本活页账本——每一页是一个日志流，每行是一条
带时间戳的事件；Metric Filter 和 Subscription Filter 是夹在账本里的两张透明
滤纸：一张把 ERROR 行计数成指标，一张把每行复印一份寄给清洗函数。但和真实
滤纸不同的是：它们只对"新写入"生效，历史日志不会补算。

两级过滤器：

- **Metric Filter**：按字段值匹配（如 `$.level = "ERROR"`），命中即向指定
  指标贡献数值——日志变成告警的数据源。
- **Subscription Filter**：匹配的日志实时推给 Lambda/Kinesis——日志变成
  管道的输入。

## When to Use

典型场景：

- 应用日志集中化：所有服务的 stdout 收进日志组，统一查询与保留。
- 错误率指标化：Metric Filter 把 ERROR 行变成指标，供告警（lab 22）使用。
- 实时清洗管道：日志推给 Lambda 解析后入 DynamoDB/分析库（lab 30 平台的
  进水口）。

何时不用：超大体量的长期检索与聚合（应导出到 S3 + Athena（用 SQL 直接查询 S3 上文件的服务，按扫描量计费）（用 SQL 直接查询 S3 上文件的服务，按扫描量计费），Logs 的查询按扫描
计费不便宜）；需要完整文本搜索生态（自建 ES 更灵活）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CloudWatch Logs | AWS 原生、字段查询、与告警无缝 | AWS 应用的默认日志方案 |
| 自建 ELK | 功能强、运维重 | 已有 ES 运维体系、复杂检索 |
| Loki | 标签索引、便宜，查询能力弱 | Kubernetes 场景、日志量大 |
| S3 + Athena | 便宜存储、按查询扫描计费 | 冷数据长期保留与分析 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/21_cloudwatch_logs
./cloudwatch_logs.sh            # 建组 → 写日志/双过滤器/保留 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 写入结构化 JSON 日志（含 ERROR 级别）
  ✅ 日志可查询（3 条）
=====> [observe] Metric Filter：ERROR 关键字 → 自定义指标
  ✅ Metric Filter 已挂载（ERROR 日志 → AppErrors 指标）
=====> [observe] Subscription Filter → Lambda 实时清洗（支持度探活）
  ✅ Subscription Filter 生效：Lambda 清洗落库（1 条）
=====> [observe] 保留策略：设 7 天过期
  ✅ 保留策略 7 天生效
```

写日志事件的命令要点（脚本用 python 构造 JSON 避免引号嵌套出错）：

```bash
awslocal logs put-log-events --log-group-name /ho21/app \
  --log-stream-name app-20260907 --log-events file:///tmp/events.json
```

新手第一个失败点：事件被**静默拒绝**——put-log-events 返回的
`rejectedLogEventsInfo` 里有 `tooNewLogEventStartIndex`，原因是容器时钟落后
宿主机约 3 小时（脚本已把时间戳回拨）。

## How It Works

![CloudWatch Logs](images/cloudwatch_logs.svg)

> 怎么看：应用把 JSON 日志写进日志组（实线主路径）；Metric Filter 挂在日志组
> 上把 ERROR 行变成 CloudWatch 指标；Subscription Filter 把每条日志实时推给
> 清洗 Lambda 落库（虚线）；保留策略管整组的生命周期。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/21_cloudwatch_logs/images/cloudwatch_logs.html)
> （或本地打开 [`images/cloudwatch_logs.html`](images/cloudwatch_logs.html)）。

**Metric Filter 如何把日志变指标**：过滤模式 `{ $.level = "ERROR" }` 按 JSON
字段值匹配，命中即向 `AppErrors` 指标贡献 1——实测 describe-metric-filters
可见规则挂载。只对新写入的日志生效，历史日志不补算。

**Subscription Filter 如何实时投递**：空 pattern（全量）把每条日志 gzip+
base64 封装后推给 Lambda；实测新写入的 ERROR 日志被清洗函数解析并落进
DynamoDB（断言 1 条入库）。

**保留策略如何控成本**：默认**永不过期**（账单刺客）。实测
`put-retention-policy --retention-in-days 7` 后 describe 可见 7——生产按
合规要求设 7~90 天。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **日志被静默拒绝**：时间戳"太新"（容器时钟落后宿主机约 3 小时）。解法：
  时间戳回拨，并检查 `rejectedLogEventsInfo`。
- **事件 JSON 引号嵌套炸 CLI**：message 内含双引号。解法：用 python 构造
  payload 文件，不手拼字符串。
- **订阅投递的 Lambda 解析失败**：投递体是 gzip+base64 封装。解法：
  `gzip.decompress(base64.b64decode(data))` 解包。
- **Metric Filter 对历史日志无效**：只对新写入生效。解法：挂好过滤器再产生
  日志，或重新写入测试行。

深入问答：

- **Q: 结构化日志的好处？** A: 字段级查询/过滤/聚合、Metric Filter 直接解析、
  采集管道免正则——纯文本日志让人看不清系统内部发生了什么（可观测性差），排障成本高一个数量级。
- **Q: Metric Filter 与应用埋点的取舍？** A: Filter 免改代码、按模式统计；
  埋点语义更丰富（维度、单位）。核心指标埋点，长尾问题用 Filter。
- **Q: Subscription Filter 的投递语义？** A: 近实时、至少一次；Lambda 目标
  限流时会重试，下游要幂等。
- **Q: 日志成本怎么治理？** A: 保留策略、日志级别动态调整、大字段进 S3 留
  引用、定期审查无主日志组。

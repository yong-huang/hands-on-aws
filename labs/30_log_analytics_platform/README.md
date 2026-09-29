# 30 · 终极实战：实时日志分析平台

> 本实验把 lab 11-29 的能力拧成一台平台级系统：生成器灌 1000 条日志 →
> Kinesis 聚流 → 清洗 Lambda（脱敏/结构化）→ DynamoDB 明细 + S3 按天归档 →
> ERROR 告警入队 → CloudWatch 指标注册。CDK 一键部署，`make run` 一键演示，
> 共 12 项真实断言，销毁复原零残留。

## Background

在流式日志平台成熟之前，日志分析靠"定时搬运 + 批处理"：应用日志写本地文件，
采集脚本每小时搬运一次，分析靠第二天跑批。

批处理模式撞上三堵墙。第一，延迟以小时计——错误日志第二天才进分析库，告警
形同虚设。第二，多消费者各自为政——实时大屏、归档、告警各拉一份数据，格式
与进度互不兼容。第三，敏感信息随日志裸奔——手机号、卡号直接入库。

实时管道
的答案是把"采集-清洗-存储-告警"串成一条流式链路：Kinesis 做缓冲与解耦，
Lambda 做清洗与分发，DynamoDB/S3 做存储，CloudWatch 做观测——这正是 lab 30
要搭建的系统。

## What

一句话定义：本平台是一条五段流式管道——采（Kinesis 聚流）→ 洗（Lambda 脱敏
与结构化）→ 存（DynamoDB 明细 + S3 按天归档）→ 警（ERROR 推 SQS 告警队列）→
看（CloudWatch 指标），全套资源由 CDK 栈管理。

心智模型：可以把平台想象成自来水厂——原水（原始日志）先进蓄水池（Kinesis
缓冲），过滤车间（清洗 Lambda）去除杂质（脱敏）后分成两路：生活用水进千家
万户（DynamoDB 明细），原水样本留存备查（S3 归档）；

水质异常（ERROR）时
警报（告警队列）响起，仪表盘（CloudWatch 指标）记录每日处理量。

但和真实水厂
不同的是：整套水厂可以用一个 CDK 栈一键建起、一键拆除。

断言矩阵（压测的"出厂检验单"）：

| 段 | 组件 | 断言 |
|:---|:---|:---|
| 采 | Kinesis（1 分片） | put_records FailedRecordCount=0 |
| 洗 | 清洗 Lambda | Active + 事件源映射 Enabled |
| 存 | DynamoDB + S3 | 明细 ≥95% 入库；归档对象生成 |
| 警 | SQS 告警队列 | ERROR 数 100 条落队 |
| 看 | CloudWatch | Ho30 指标注册 2 条 |

## When to Use

典型场景：

- 应用日志的实时分析：错误率实时可见、明细可查、原始日志可追溯。
- 点击流/传感器数据的入湖管道：同一模式换业务字段即可复用。
- 学习事件驱动平台架构：五段各自独立、可替换（如 Kinesis 换 MSK）。

何时不用：日志量极小（直接写 CloudWatch Logs + Metric Filter，lab 21/22）；
需要复杂检索与聚合（导 S3 + Athena（直接对 S3 文件跑 SQL 查询的服务）更合适）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 自建管道（本实验） | 组件可见、可控可学 | 学习与中等规模系统 |
| Kinesis Firehose | 全托管投递 S3，无清洗逻辑 | 纯落盘不需要处理 |
| CloudWatch Logs Insights | 托管查询，按扫描计费 | 日志量中小、查询频率低 |
| ELK（Elasticsearch 日志检索套件）自建 | 功能强、运维重 | 已有运维体系与复杂检索需求 |

## Quick Start

前置条件：LocalStack 运行中；CDK 已安装（lab 28）；首次部署脚本会自动
`cdklocal bootstrap`（建 CDKToolkit 栈与资产桶）。运行方式：

```bash
cd labs/30_log_analytics_platform
make run                  # CDK 部署 → 1000 条压测 → 全链路断言 → 销毁（约 3 分钟）
make deploy               # 只部署平台
make clean                # 只销毁
```

`make run` 的真实输出（节选）：

```text
=====> [observe] 1000 条压测 + 全链路断言
  灌入 1000 条日志（run=f0f190e8，含 100 条 ERROR）
  ✅ 已写入 1000 条
  ✅ DynamoDB 明细入库（1000）
  ✅ 告警队列收到 ERROR（100）
  ✅ S3 归档对象生成（10）
  ✅ CloudWatch 指标注册（2）
=====> [clean] CDK 一键销毁平台栈
  ✅ 平台已销毁，环境复原
```

压测生成器的核心逻辑（`generate_load.py`）——批量写 + 断言等待：

```python
r = kinesis.put_records(StreamName="ho30-logs", Records=recs)
assert r.get("FailedRecordCount", 0) == 0          # 批量写要查失败计数

wait_for(lambda: 明细行数 >= n_sent * 0.95, 120, "DynamoDB 明细入库")
# wait_for 轮询谓词直到成立或超时——异步管道断言的标准姿势
```

新手第一个失败点：deploy 报"uses assets"——栈引用本地文件（Lambda 代码目录）
属于资产，需要先 `cdklocal bootstrap`（建 CDKToolkit 栈与资产桶），脚本已
自动化。

## How It Works

![实时日志分析平台](images/log_analytics_platform.svg)

> 怎么看：实线主数据路径——生成器按 run 标记灌日志进 Kinesis；清洗 Lambda
> 按批次拉取，脱敏后写 DynamoDB 明细、按天归档 S3、ERROR 推告警队列；虚线
> 观测路径——生成器打 CloudWatch 指标，全套资源由 CDK 栈管理（bootstrap 后
> deploy/destroy）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/30_log_analytics_platform/images/log_analytics_platform.html)
> （或本地打开 [`images/log_analytics_platform.html`](images/log_analytics_platform.html)）。

**清洗如何工作**：清洗 Lambda 收到 Kinesis 批次（Records 内是 base64 的
记录），逐条解析、脱敏（手机号打码）、结构化后写 DynamoDB 明细（主键 =
eventID，天然防重）；

同批次的 JSON 行汇成一个归档对象写入 S3 的
`日期/batch-<时间戳>.json`；`level=ERROR` 的记录另推一条到告警队列——实测
1000 条进、明细 1000 行、告警 100 条。

**run 标记如何保证幂等**：每轮压测生成 `run=<uuid8>` 写进每条日志——明细表
按 run 过滤统计，重跑不互相污染；S3 归档按天分前缀、按批时间戳命名，天然
幂等。

**指标如何打点**：生成器压测后向 `Ho30` 命名空间打 `LogsProcessed` 与
`LogErrors` 两个指标，时间戳用容器时钟（从 LocalStack 响应头取，lab 22 的
教训）——实测 list-metrics 注册 2 条。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **deploy 报 uses assets**：栈含本地代码资产，先 `cdklocal bootstrap`。
- **事件源映射状态值是 Enabled**：不是 Active（断言别写错）。
- **压测断言过严会闪红**：异步消费有批次延迟，明细断言留 5% 容差（≥95%）。
- **清洗 Lambda 批内一条毒日志拖全批**：按条 try 吞掉坏行并计数上报，不做
  整批失败。

深入问答：

- **Q: 为什么用 Kinesis 而不直接写 DynamoDB？** A: 削峰、缓冲、多消费者——
  写入侧不感知下游容量，明细/归档/告警共用一条流。
- **Q: 1000 条/分片能撑多久？** A: 1 分片写 1MB/s（约 1000 条/s 小日志）；
  按峰值 × 安全系数规划分片，监控 WriteProvisionedThroughputExceeded。
- **Q: 清洗 Lambda 批内毒日志怎么办？** A: 按条 try 吞掉坏行并计数上报；或
  bisect-on-error 二分定位（分级容错）。
- **Q: 平台的 SLO 怎么定？** A: 端到端延迟 P99、告警时效、归档完整性——三者在
  断言矩阵里已有雏形，生产化时变成正式的 SLI（服务指标）与 SLO（指标目标值）。

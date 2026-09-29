# 12 · Kinesis Data Streams：分片、迭代器与重放

> Amazon Kinesis Data Streams 是一种分片化的持久有序日志流：记录写入后按保留
> 期存储，多个消费者各自用自己的进度（迭代器）读取，还能定点重放历史。本实验
> 跑通批量写入、三种迭代器消费、分区键顺序保证与 Lambda 自动消费，共 8 项真实
> 断言。

## Background

在流式日志服务普及之前，日志与点击流的收集靠写文件再批量导入：应用把日志追加
到本地文件，采集脚本定时搬运到 HDFS（Hadoop 分布式文件系统）或数据库。

文件搬运模式撞上三堵墙。第一，多消费者无解——同一份日志给了实时大屏就不能再
给离线数仓，或者要复制多份。第二，无法回放——新上线的消费者想看昨天的历史，
只能翻归档文件重新导。

第三，峰值即丢数据——写入超过消费速度时只能丢弃或阻塞。Kinesis Data Streams
（2013 年推出）把流做成"分片化的持久日志"：记录按保留期存储（24 小时起，可
延长到 365 天），消费者各持书签独立前进，互不影响。

## What

一句话定义：Kinesis Data Streams 是一种分片化的托管日志流——记录（record）
按分区键（partition key）写入分片（shard，固定吞吐的有序日志单元），消费者用
迭代器（shard iterator，指向读取位置的书签）按序读取。

心智模型：可以把流想象成一条只能从头到尾播放的电影胶片——分片是一段胶片，
写入即追加，消费者拿到的迭代器是"从第几帧开始看"的书签，三种书签起点各有
用途（见下）。但和真实胶片不同的是：每个人可以有自己的书签（多消费者独立
消费），而且可以把书签插回任意历史时刻重看（重放）。

三种迭代器起点：

- **TRIM_HORIZON**：从分片最老的有效记录开始（回填场景）。
- **LATEST**：只看创建迭代器之后的新记录（实时场景）。
- **AT_TIMESTAMP**：从指定时刻开始（精确重放/补偿）。

## When to Use

典型场景：

- 多消费者日志/点击流：实时大屏、离线数仓、告警引擎各自独立消费、各持进度。
- 顺序敏感的事件管道：同一设备/用户的事件严格有序处理（按分区键路由）。
- 需要重放的数据源：下游 bug 修好后，从历史时间点重新消费补数。

何时不用：任务分发（一条消息一个消费者，消费即删除）选 SQS；单消费者且不需
要重放时 SQS 更简单；极低延迟（毫秒级）点查选数据库。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Kinesis Data Streams | 分片日志、可重放、按序 | 多消费者日志流、事件管道 |
| SQS | 消息队列，消费即删除 | 任务分发、单消费者 |
| MSK (Kafka) | 自管消费组与 offset，生态大 | 已有 Kafka 生态、超大吞吐 |
| Firehose | 全托管投递到 S3/Redshift（AWS 云数据仓库），无消费者逻辑 | 纯落盘不需要处理逻辑 |

## Quick Start

前置条件：LocalStack 运行中；本机构建需要先清理可能截断的 kinesis-mock 二进制（LocalStack 内部代替 Kinesis 的模拟器组件）（LocalStack 内部代替 Kinesis 的模拟器
  组件）
（重启容器即可）。运行方式：

```bash
cd labs/12_kinesis_streams
./kinesis_streams.sh            # 建表+函数 → 单进程演示全流程 → 清理（约 2 分钟）
./kinesis_streams.sh observe    # 只跑核心演示
```

脚本的真实输出（节选）：

```text
=====> [observe] 核心演示：建流/批量写/顺序/迭代器/重放/事件源映射
  ✅ 建流 ho12-kds-754b93b2（1 分片）
  ✅ PutRecords 批量写入 10 条（FailedRecordCount=0）
  ✅ TRIM_HORIZON 消费到全部 10 条（迭代器从头开始）
  ✅ 同分区键 sensor-1 严格按序: 0→1→2→3→4（跨分区键交错）
  ✅ AT_TIMESTAMP 重放历史数据：再次读到 10 条（流可回放，队列做不到）
  ✅ Lambda 事件源映射自动消费并落库 DynamoDB（AWS 的 NoSQL 数据库，本次 3 条）
```

流读取的核心代码（`kinesis_demo.py`）——建迭代器后按页读取：

```python
it = kinesis.get_shard_iterator(StreamName=stream, ShardId=shard,
                                ShardIteratorType="AT_TIMESTAMP",
                                Timestamp=t0)["ShardIterator"]
while it:
    resp = kinesis.get_records(ShardIterator=it, Limit=1000)
    payloads += [base64.b64decode(r["Data"]) for r in resp.get("Records", [])]
    it = resp.get("NextShardIterator")
```

新手第一个失败点：`put_records` 部分失败**不抛异常**——必须检查返回的
`FailedRecordCount` 并重试失败项；脚本断言其为 0。

## How It Works

![Kinesis Data Streams](images/kinesis_streams.svg)

> 怎么看：生产者按分区键写入分片（分片内严格有序）；三个消费者用三种起点
> 建迭代器——TRIM_HORIZON 从头、LATEST 只看新、AT_TIMESTAMP 定点重放；
> Lambda 事件源映射是最省事的"托管消费者"，自动拉取落库。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/12_kinesis_streams/images/kinesis_streams.html)
> （或本地打开 [`images/kinesis_streams.html`](images/kinesis_streams.html)）。

**顺序如何保证**：分区键做哈希决定记录进哪个分片，同一键永远进同一分片、
分片内严格按写入序排列。实测 sensor-1 的 5 条记录严格按 0→1→2→3→4 被消费，
与 sensor-2 的记录交错——"分片内有序、跨分片并行"。

**重放如何工作**：AT_TIMESTAMP 迭代器指向指定时刻的位置，从头读一遍历史——
实测把时间设到很早，10 条记录原样再来一遍。这是队列做不到的：队列的消息取走
即删。

**Lambda 自动消费如何工作**：`create-event-source-mapping`（StartingPosition
LATEST）后，平台替 Lambda 管理迭代器与批量拉取——实测新写入 3 条记录，自动
落进 DynamoDB 并留日志。手动消费（自管迭代器）与托管消费两种形态按需选择。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，全部为本机实测）：

- **读到的记录是乱码**：kinesis-mock 返回的 Data 字段可能是明文 JSON 或缺
  `=` 填充的 base64。解法：按形状自适应解码（脚本 `decode_data()`）。
- **删流重建后读到脏数据**：mock 的分片池残留旧记录。解法：每次运行用全新流名
  （时间戳/uuid 后缀）。
- **`NextShardIterator` 永不为 null**：活跃分片读不完。解法：按页数上限或
  "连续空页"截断（真实 AWS 读到分片关闭才返回 null）。
- **容器时钟落后宿主机约 3 小时**：AT_TIMESTAMP 用宿主机"5 分钟前"会报"在未来"。
  解法：用固定旧时间戳（脚本用 2020-01-01）。

深入问答：

- **Q: Kinesis 与 SQS 的本质区别？** A: Kinesis 是可重放的持久日志（多消费者
  独立书签、按分片有序）；SQS 是消费即删除的队列（任务分发）。多下游独立进度
  选流，单下游任务选队列。
- **Q: 分区键怎么设计？** A: 按"需要串行的最小业务单元"（设备/用户/订单）；
  键基数太低会热分片，太高失去聚合局部性。
- **Q: 消费落后了怎么办？** A: 加分片（写 1MB/s、读 2MB/s 每分片）；消费者侧
  批量拉取与异步处理；延长保留期防止读不到就丢。
- **Q: 能做到 exactly-once 吗？** A: 流本身 at-least-once；exactly-once 靠
  消费侧幂等或用 sequence number 去重（lab 14 的去重表思路直接复用）。

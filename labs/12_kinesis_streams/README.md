# 12 · Kinesis Data Streams：分片、迭代器与重放

> 队列的消息"消费即消失"，但日志/点击流需要"**回放**"——新消费者加入要从头看
> 历史。Kinesis 的答案：分片化的**持久有序日志**，消费进度（迭代器）由消费者
> 自己管理，TRIM_HORIZON 从头读、LATEST 只看新的、AT_TIMESTAMP 任意时刻重放。
> 本实验把分片模型、顺序保证、三种迭代器和 Lambda 自动消费全部跑通。

## 1. 为什么需要它

- **多条独立消费路径**：同一份点击流，实时大屏、离线数仓、告警引擎各自消费、
  各自记进度——队列做不到（消息取走就没了）。
- **顺序按分区键保证**：同一设备/用户的事件严格有序，跨分区并行——吞吐与
  有序兼得的经典设计。
- Kinesis 是 lab 30 日志平台的地基。

## 2. 总览：核心机制一图看懂

![Kinesis Data Streams](images/kinesis_streams.svg)

> 怎么看：生产者按分区键写入分片（分片内严格有序）；三个消费者用三种起点
> 建迭代器——TRIM_HORIZON 从头、LATEST 只看新、AT_TIMESTAMP 定点重放；
> Lambda 事件源映射是最省事的"托管消费者"，自动拉取落库。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/12_kinesis_streams/images/kinesis_streams.html)
> （或本地打开 [`images/kinesis_streams.html`](images/kinesis_streams.html)）。

心智模型一句话：**流是"可回放的分布式日志"，迭代器是消费者自己的书签。**

## 3. 快速开始

```bash
cd labs/12_kinesis_streams
./kinesis_streams.sh            # 建表+函数 → 单进程演示全流程 → 清理（约 2 分钟）
./kinesis_streams.sh observe    # 只跑核心演示
```

真实运行输出（节选）：

```text
=====> [observe] 核心演示：建流/批量写/顺序/迭代器/重放/事件源映射
  ✅ PutRecords 批量写入 10 条（FailedRecordCount=0）
  ✅ TRIM_HORIZON 消费到全部 10 条（迭代器从头开始）
  ✅ 同分区键 sensor-1 严格按序: 0→1→2→3→4（跨分区键交错）
  ✅ AT_TIMESTAMP 重放历史数据：再次读到 10 条（流可回放，队列做不到）
  ✅ Lambda 事件源映射自动消费并落库 DynamoDB（本次 3 条）
```

## 4. 核心概念

### 4.1 分片：容量的单位

1 分片 = 写入 1MB/s（1000 条）+ 读出 2MB/s。吞吐不够就加分片（shard-count），
分区键的哈希决定记录落进哪个分片。**同一分区键永远落在同一分片**——顺序保证
的来源。本实验 sensor-1 的 5 条记录严格按 0→4 消费（实测）。

### 4.2 三种迭代器起点

| 起点 | 语义 | 用途 |
|:---|:---|:---|
| TRIM_HORIZON | 从分片最老记录开始 | 首次上线的全量回填 |
| LATEST | 只看创建迭代器之后的新记录 | 常驻实时消费 |
| AT_TIMESTAMP | 从指定时刻开始 | 精确重放/补偿 |

重放实测：AT_TIMESTAMP 设到"很早以前"再读一遍，10 条历史记录原样再来——这是
流和队列的本质区别。

### 4.3 事件源映射：托管消费者

`create-event-source-mapping` 让 Lambda 成为流的托管消费者：平台替你管理迭代
器、批量化、失败重试。本实验映射建好后写 3 条新记录，Lambda 自动消费落进
DynamoDB（实测 3 条入库 + 日志验证）。**消费者自己管理迭代器（本实验前半段）
与托管消费（后半段）是两种典型形态**。

### 4.4 本机踩坑实录（本实验最值钱的部分，全部实测）

1. **本机代理劫持**：shell 里的代理（Clash 类 :7890）会被 boto3 继承，导致读写
   行为诡异甚至整体挂起——所有脚本第一行都 `export NO_PROXY="localhost,127.0.0.1"`。
2. **Data 字段形状不稳定**：mock 返回的 Data 有时是**明文 JSON**、有时是**缺
   `=` 填充的 base64**（`decode_data()` 按形状自适应）。
3. **删流重建读脏数据**：同名流删了再建，分片池残留旧数据——每次运行用
   全新流名（时间戳/uuid 后缀）。
4. **容器时钟漂移**：OrbStack 重启后容器时钟可落后宿主机 2 小时，AT_TIMESTAMP
   用"当前时间-5 分钟"会报"在未来"——用固定旧时间戳。
5. **NextShardIterator 永不为 null**：活跃分片读不完，按页数上限截断（真实 AWS
   是读到空/迭代器过期）。

## 5. 代码关键字段（kinesis_demo.py / kinesis_sink.py）

```python
kinesis.put_records(StreamName=stream, Records=[          # 批量写，返回 FailedRecordCount
    {"Data": json.dumps(evt).encode(), "PartitionKey": "sensor-1"}])

kinesis.get_shard_iterator(StreamName=..., ShardId=...,
    ShardIteratorType="AT_TIMESTAMP", Timestamp=t0)       # 三种起点之一

kinesis.get_records(ShardIterator=it, Limit=1000)         # 返回 Records + NextShardIterator

# sink Lambda：事件里是 base64 的 Data + partitionKey + sequenceNumber
payload = base64.b64decode(r["kinesis"]["data"]).decode()
```

坑清单：

- `put_records` 部分失败不抛异常——**必须检查 FailedRecordCount** 并重试失败项；
- 迭代器 5 分钟不用会过期（ExpiredIteratorException），长间隔消费要重建；
- 分片是吞吐上限：写入超 1MB/s 会限流，扩容要拆分分片（resharding）。

## 6. 文件结构

```text
labs/12_kinesis_streams/
├── README.md               # 本文件
├── kinesis_streams.sh      # 主演示脚本：环境编排 + 调用核心演示 + 清理
├── kinesis_demo.py         # 核心演示：建流/写/读/重放/映射（单进程单遍）
├── kinesis_sink.py         # 事件源映射的消费者 Lambda（落库 DynamoDB）
└── images/
    ├── kinesis_streams.architecture.json  # 图源（Typed JSON IR）
    ├── kinesis_streams.html               # 交互版
    └── kinesis_streams.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: Kinesis 与 SQS 的本质区别？** A: SQS 是队列（消费即删除、消息级确认）；
  Kinesis 是日志（记录保留 24h~365 天、消费进度自管、可重放、按分片有序）。
  多消费者独立进度选流，任务分发选队列。
- **Q: 分区键怎么设计？** A: 需要有序的业务实体（设备/用户/订单）作键；键基数
  太低会热分片，太高失去聚合局部性——按"有序单元"选。
- **Q: 消费落后了怎么办？** A: 分片读吞吐 2MB/s 是上限，落后就加分片；消费者
  侧批量拉取、异步处理；保留期延长避免"读不到就丢了"。
- **Q: exactly-once 可能吗？** A: 流本身 at-least-once；exactly-once 靠消费侧
  幂等或事务写（如 Redshift/跨区聚合的 sequence number 去重）。
- **Q: 事件源映射的批处理怎么调？** A: BatchSize/BatchingWindow 控制延迟与
  吞吐折中；失败重试到 TruncationConfig 或 OnFailure Destination。

## 8. 总结

一条流、三种书签、一份顺序保证——"可回放的分布式日志"模型落地完成，本机的
kinesis-mock 五个深坑也全部排掉（都写进了 4.4，遇到同类问题直接对号入座）。
下一篇回到 S3：把"文件到了"的通知做成一条多目标并发的处理管道。

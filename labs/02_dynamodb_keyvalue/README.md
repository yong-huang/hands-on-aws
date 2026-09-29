# 02 · DynamoDB 键值存储：分区键建模、条件写入与 GSI

> DynamoDB 是 AWS 的键值数据库：按主键点查个位数毫秒、任意规模可预测。本实验在
> LocalStack 里围绕一张订单表跑通建模、条件写入、Query/Scan 与二级索引，并配
> 12 项真实断言——其中还包括一次"把整个挂死的 LocalStack 救活"的实录。

## Background

在键值数据库普及之前，海量数据最常见的存放方式是关系型数据库（如 MySQL）：
数据按表组织，靠 SQL 的 JOIN 和全表扫描回答各种查询。

这种方式在数据量上去之后撞墙：全表扫描的耗时随数据量线性增长，单机磁盘与内存
很快成为瓶颈；要扩容就得分库分表，应用代码里到处是拆分逻辑。DynamoDB 是 AWS
在 2012 年给出的答案：把"按主键点查"做成个位数毫秒、容量与吞吐全部自动扩展
的托管服务，代价是要求使用者**先想清楚查询方式，再设计表结构**。

## What

一句话定义：DynamoDB 是一种全托管的键值与文档数据库，用"表—条目—属性"组织
数据，靠主键和二级索引提供可预测的查询性能。

心智模型：可以把一张表想象成一本按"客户 + 订单号"排好序的账册。主键由分区键
（partition key，决定条目存到哪个物理分区）和排序键（sort key，让同一分区内
按序存放）组成，两者合起来必须全局唯一。

但和真实账册不同的是：想按"另一个维度"（比如渠道）查，不能翻这本账册，得查
另一本按新维度排好序的副本——这就是二级索引（GSI，Global Secondary Index，
用不同主键重排的只读投影——投影（projection）即按新键排好的一份只读副本）。

## When to Use

典型场景：

- 海量键值存取：会话、购物车、用户配置，按主键点查个位数毫秒，规模增长不换架构。
- 高并发写入：条件写入（`ConditionExpression`，写入前原子校验一个条件的机制）
  提供无锁的乐观并发控制——写入前先校验条件，失败即报错，不需要加锁。
例如两个请求同时创建同一订单号，只有一个成功，另一个收到失败信号。
- 已知查询模式的业务：订单按客户查、消息按会话查——模式固定时性能最可预测。

何时不用：需要灵活的临时查询（任意字段组合、聚合、JOIN）时，关系库或分析引擎
更合适；数据量很小（几千条）时维护成本不划算。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| DynamoDB | 键值/文档，按主键与索引查询，全托管 | 模式已知的海量键值与文档 |
| MySQL | 关系库，SQL/JOIN/事务 | 数据量中等、查询灵活多变 |
| Redis | 内存键值，微秒级，需自管持久化 | 纯缓存、计数器、可容忍丢失 |
| MongoDB | 文档数据库，二级索引与聚合 | 半结构化文档、多维临时查询 |

## Quick Start

前置条件：LocalStack 运行中；本机 DynamoDB provider 可能冷启动慢（脚本已内置
预热与重试）。运行方式：

```bash
cd labs/02_dynamodb_keyvalue
./dynamodb_keyvalue.sh            # apply → observe → clean（约 30 秒）
./dynamodb_keyvalue.sh apply      # 只建表（configs/table.json 声明式定义）
./dynamodb_keyvalue.sh observe    # 演示 CRUD/条件写/Query/Scan/GSI 并断言
./dynamodb_keyvalue.sh clean      # 删表复原
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 条件写入：attribute_not_exists 防覆盖 → 期望 ConditionalCheckFailedException
  ✅ 覆盖被拒绝：ConditionalCheckFailedException
  ✅ 原数据完好（amount=99）
=====> [observe] Query：按分区键取一个客户的全部订单，再用排序键范围缩小
  ✅ C1 共 6 单（只读一个分区，读到多少算多少）
=====> [observe] Scan + FilterExpression：全表扫描后过滤（先读后滤，读容量按扫描量计）
{
    "Scanned": 11,
    "Matched": 5
}
=====> [observe] GSI 查询：换一个访问维度（渠道+金额），无需扫表
  ✅ web 渠道且 amount>50 共 4 单（走 channel-amount-index）
```

表结构来自声明式配置 `configs/table.json`，两个关键字段——主键由分区键加排序键
组成，GSI 用另一套主键重排数据：

```jsonc
{
  "KeySchema": [
    { "AttributeName": "customer_id", "KeyType": "HASH" },   // 分区键：决定放哪个分区
    { "AttributeName": "order_id",    "KeyType": "RANGE" }   // 排序键：分区内有序、可 BETWEEN
  ],
  "GlobalSecondaryIndexes": [{
    "IndexName": "channel-amount-index",
    "KeySchema": [ /* channel HASH + amount RANGE，与主表无关的另一套主键 */ ],
    "Projection": { "ProjectionType": "ALL" }  // ALL=全属性投影；KEYS_ONLY/INCLUDE 省容量
  }]
}
```

新手第一个失败点：建表命令成功后立刻读写会报 `ResourceNotFound`——建表是异步
的，要等 `describe-table` 返回 `ACTIVE`（脚本的 `wait_active` 已处理）。

## How It Works

![DynamoDB 键值建模](images/dynamodb_keyvalue.svg)

> 怎么看：主表按 `customer_id`（分区键）+ `order_id`（排序键）组织——同一个
> 客户的订单物理相邻、按单号有序；右侧 GSI 是同一份数据按 `channel + amount`
> 重排的"投影"。Scan（虚线）是那条昂贵的兜底路径。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/02_dynamodb_keyvalue/images/dynamodb_keyvalue.html)
> （或本地打开 [`images/dynamodb_keyvalue.html`](images/dynamodb_keyvalue.html)）。

**条件写入如何工作**：`put-item` 带 `ConditionExpression: attribute_not_exists
(order_id)` 时，"检查存在性"与"写入"是一次原子操作。

Quick Start 里看到的 `ConditionalCheckFailedException`，就是三个并发消费者抢写
同一条记录时，唯一成功者之外的失败信号——数据不被触碰，无需加锁。

**Query 与 Scan 的区别如何量化**：Query 沿主键定位到一个分区，读多少算多少
（实测 C1 的 6 单）；Scan 把整表读出后再用 `FilterExpression` 过滤——实测
`Scanned: 11, Matched: 5`，读容量按 11 计而非 5。表越大，这条差距越贵。

**GSI 如何工作**：写入条目时，DynamoDB 自动向 `channel-amount-index` 投影一份，
按 `channel + amount` 重排。于是"web 渠道且 amount>50"从全表扫描变成一次分区
点查（实测 4 单）。

注意没写 `channel` 属性的条目不会出现在 GSI 里——这是稀疏索引特性，有时反而
可利用（故意让部分条目不进索引）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **建表后立刻读写报 `ResourceNotFound`**：建表异步，状态从 `CREATING` 到
  `ACTIVE` 需要几秒。解法：轮询 `describe-table` 直到 `ACTIVE`（脚本
  `wait_active`）。
- **本机首次建表把 LocalStack 拖挂**：根因是 DynamoDB 的 `dynamodb-rust`
  provider 二进制下载被截断且失败状态被进程缓存。解法：
  `bash scripts/load_resources.sh fix-dynamodb`（删残片 → 重启容器 → 触发重新
  下载）；修好后事务/TTL 也一并可用。
- **`AttributeDefinitions` 多声明属性直接报错**：只允许声明"被键或索引用到"的
  属性，多一个都不行（不是警告）。解法：删掉没用的声明。
- **容器冷启动后第一个 DynamoDB 调用极慢**：provider 是懒加载子进程。解法：
  先发一次 `list-tables` 预热（脚本已内置）。

深入问答：

- **Q: 分区键怎么选？** A: 选"高基数 + 访问模式命中"的属性——既让负载均匀打散
  到各分区，又让高频查询都是单分区 Query。
- **Q: LSI 和 GSI 的区别？** A: LSI 与主表共用分区键、换排序键，强一致但必须
  建表时定义且每表最多 5 个；GSI 完全另起主键，最终一致，可随时添加。
- **Q: 事务和条件写的区别？** A: 条件写只保护单条目；`TransactWriteItems` 最多
  100 条目全成全败（2 倍容量成本）。本机修复 provider 后事务实测可用；TTL（Time To Live，为属性声明到期时间、
到点自动删除）也在本机可用。
- **Q: FilterExpression 为什么省不了多少读容量？** A: 它在数据读出之后才过滤，
  容量按 ScannedCount 计；想省容量就把过滤条件建模进键或索引。
- **Q: 热分区怎么办？** A: 写入键加随机后缀/时间桶（write sharding）打散，或用
  DAX（AWS 为 DynamoDB 提供的官方缓存服务）缓存；读侧优先把高频维度降维到
  GSI。

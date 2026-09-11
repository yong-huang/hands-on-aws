# 02 · DynamoDB 键值存储：分区键建模、条件写入与 GSI

> S3 解决"整存整取"，但"查出这个客户金额大于 100 的所有订单"这类问题，扫桶就像
> 大海捞针。DynamoDB 的答案是**先设计访问模式，再设计表**：分区键决定数据放哪，
> 排序键决定怎么有序取，二级索引让你"换一个维度查询"不用扫全表。本实验把这套
> 建模思路在本地全部跑一遍。

## 1. 为什么需要它

- 海量键值场景下，关系库的 JOIN/全表扫描都是奢侈品；DynamoDB 把"按主键点查"
  做到个位数毫秒、任意规模。
- 它没有 SQL 的灵活，换来的是**可预测的性能**：Query 只读一个分区，成本与结果
  大小成正比，与表大小无关。
- 条件写入给了你无锁的乐观并发控制——三个消费者抢写同一条记录，只有一个成功。

## 2. 总览：核心机制一图看懂

![DynamoDB 键值建模](images/dynamodb_keyvalue.svg)

> 怎么看：主表按 `customer_id`（分区键）+ `order_id`（排序键）组织——同一个客户
> 的订单物理相邻、按单号有序；右侧 GSI 是同一份数据按 `channel + amount` 重排的
> "投影"，让"按渠道查"不用扫主表。Scan（虚线）是那条昂贵的兜底路径。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/02_dynamodb_keyvalue/images/dynamodb_keyvalue.html)
> （或本地打开 [`images/dynamodb_keyvalue.html`](images/dynamodb_keyvalue.html)）。

心智模型一句话：**主键是唯一索引，其它一切查询要么用 GSI，要么付出 Scan 的代价。**

## 3. 快速开始

```bash
cd labs/02_dynamodb_keyvalue
./dynamodb_keyvalue.sh            # apply → observe → clean（约 30 秒）
./dynamodb_keyvalue.sh apply      # 只建表（configs/table.json 声明式定义）
./dynamodb_keyvalue.sh observe    # 演示 CRUD/条件写/Query/Scan/GSI 并断言
./dynamodb_keyvalue.sh clean      # 删表复原
```

真实运行输出（节选）：

```text
=====> [observe] 条件写入：attribute_not_exists 防覆盖 → 期望 ConditionalCheckFailedException
  ✅ 覆盖被拒绝：ConditionalCheckFailedException
  ✅ 原数据完好（amount=99）
=====> [observe] Query：按分区键取一个客户的全部订单，再用排序键范围缩小
  ✅ C1 共 6 单（只读一个分区，O(结果数)）
=====> [observe] Scan + FilterExpression：全表扫描后过滤（先读后滤，读容量按扫描量计）
{
    "Scanned": 11,
    "Matched": 5
}
=====> [observe] GSI 查询：换一个访问维度（渠道+金额），无需扫表
  ✅ web 渠道且 amount>50 共 4 单（走 channel-amount-index）
```

## 4. 核心概念

### 4.1 表 = 分区键 + 排序键

`customer_id (HASH) + order_id (RANGE)`：HASH 决定条目落在哪个物理分区，RANGE
让同一分区内按序存放。**主键组合必须全局唯一**——这就是"防覆盖"的基石。

### 4.2 条件写入：乐观锁

`ConditionExpression: attribute_not_exists(order_id)` 让"已存在则拒绝"成为一次
原子判断。失败抛 `ConditionalCheckFailedException`，数据不被触碰——本实验两次
断言验证了"拒绝"和"原数据完好"。

### 4.3 Query vs Scan：教学点最密的一对

本实验实测：`amount > 100` 匹配 5 条，但 `ScannedCount = 11`——Filter 是**先读
后滤**，读容量按扫描量计。表越大，Scan 越贵；这就是为什么访问模式必须"能落进
主键或索引"。

### 4.4 GSI：换维度重排的投影

`channel-amount-index` 以 `channel` 为分区键、`amount` 为排序键。GSI 是最终一致
的独立数据结构（可以没有排序键、可以只投影部分属性）。本实验用它把"web 渠道且
金额>50"变成一次分区点查。

> ⚠️ 易错点：GSI 的键属性必须出现在每个条目里——没写 `channel` 的订单不会出现在
> GSI 中（sparse index 特性，有时反而是优点）。

## 5. 配置关键字段（configs/table.json）

```jsonc
{
  "TableName": "ho02-orders",
  "BillingMode": "PAY_PER_REQUEST",       // 按请求付费；PROVISIONED 才有固定 RCUs/WCUs
  "AttributeDefinitions": [ ... ],        // 只需声明"用进键和索引"的属性，普通属性不用
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

坑清单：

- 建表是异步的：`describe-table` 回 `CREATING`，立刻读写会 `ResourceNotFound`——
  脚本用 `wait_active` 轮询到 `ACTIVE`；
- `AttributeDefinitions` 多声明了没用的属性会直接报错（不是警告）；
- LocalStack 里 DynamoDB 是懒加载子进程：容器冷启动后**第一个调用**可能耗时
  很久甚至失败（见下面踩坑），先跑一次 `list-tables` 预热。

## 6. 文件结构

```text
labs/02_dynamodb_keyvalue/
├── README.md                 # 本文件
├── dynamodb_keyvalue.sh      # 主演示脚本：apply/observe/clean，含 wait_active 轮询
├── configs/
│   └── table.json            # 表的声明式定义（主键+GSI），apply 用 --cli-input-json 消费
└── images/
    ├── dynamodb_keyvalue.architecture.json  # 架构图源（Typed JSON IR）
    ├── dynamodb_keyvalue.html           # 交互版架构图
    └── dynamodb_keyvalue.svg            # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: 分区键怎么选？** A: 选"高基数 + 访问模式命中"的属性——既让负载均匀打散
  到各分区，又让你的高频查询都是单分区 Query。
- **Q: LSI 和 GSI 的区别？** A: LSI 与主表共用分区键、换排序键，**强一致**但必须
  建表时定义且每表最多 5 个；GSI 完全另起主键，**最终一致**，可随时加。
- **Q: DynamoDB 事务和条件写的区别？** A: 条件写只保护单条目；TransactWriteItems
  最多 100 条目全成全败（2 倍容量成本）。本机 LocalStack 对事务支持不佳（见踩坑），
  生产验证需真实环境。
- **Q: FilterExpression 为什么没有省多少读容量？** A: 它在数据读出后才过滤，
  容量按 ScannedCount 计；想省容量就把过滤条件建模进键或索引。
- **Q: 热分区怎么办？** A: 写入键加随机后缀/时间桶（write sharding），或用
  DAX 缓存；读侧优先降维到 GSI。

## 8. 总结

一张表、两种键、一个索引，撑起了"订单查询"的完整故事：点查、范围查、条件防
覆盖、维度切换全部真机验证。下一篇解决"一个动作要通知多个系统"——SQS 的点对点
与 SNS 的扇出，消息队列的双子星。

> **踩坑实录（本机 2026-09-06）**：首次建表读超时、随后整个 LocalStack 失去响应。
> 根因有两层——① DynamoDB 的 `dynamodb-rust` 二进制下载被截断成 6MiB 残片且无
> 执行位，provider 永远起不来（日志 `Installation of dynamodb-rust failed`）；
> ② 安装失败状态被进程缓存，重启容器才重试。修复：
> `bash scripts/load_resources.sh fix-dynamodb`（删残片 → 重启 → 触发重下载）。
> 这也解释了 aws.md 里"事务/TTL 挂起"的历史现象：provider 本身就没健康过。

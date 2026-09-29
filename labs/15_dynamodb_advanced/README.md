# 15 · DynamoDB 进阶：Streams、TTL、事务与单表设计

> 本实验在 lab 02 的基础上补齐 DynamoDB 的四件生产利器：Streams（变更捕获为
> 事件）、TTL（按时间戳自动过期）、事务（多操作全成全败）与单表设计（一套主键
> 模板支撑多种访问模式），共 12 项真实断言——含对本机事务/TTL 的探活验证。

## Background

掌握了基本 CRUD（增删改查） 之后，真实业务会立刻提出四类需求，而基础 API 都答不了。

第一，"数据变了要通知别人"（审计、缓存失效）——靠应用双写不可靠。第二，
"会话和验证码到点自动消失"——靠定时任务扫表既贵又慢。第三，"扣库存和建订单
必须同生共死"——单条条件写保护不了跨条目的一致性。第四，"同一份数据要按多种
维度查询"——开 N 张表就要维护 N 份数据同步。

DynamoDB 的四件利器分别作答：Streams 把每次写入变成带新旧镜像的流记录；TTL
让条目到期被后台自动清理；TransactWriteItems 让最多 100 个操作全成全败；单表
设计用主键模板把多种实体装进一张表、用 GSI（全局二级索引，按另一套键排序的表副本）
覆盖第二维度。

## What

一句话定义：这四件利器分别是——Streams（表级变更日志，可被 Lambda 等消费者
订阅）、TTL（条目级过期时间戳，后台自动删除）、事务（TransactWriteItems，
跨条目/表的原子写）、单表设计（把实体种类编进主键模板的建模方法论）。

心智模型：可以把单表想象成一本按"实体类型 + 编号"混合编码的登记册——
`USER#u1/PROFILE` 是用户资料页，`USER#u1/ORDER#2026-01-01` 是该用户某天的
订单页，同一用户的页面物理相邻。

但和真实登记册不同的是：同一行还可以同时出现在另一本按日期排的"影子登记册"
（GSI）里，而且每一页落笔时都会自动复印一份送档案馆（Streams）。

三条访问模式（本实验全部实测）：

- 点查资料：`PK`（分区键）=`USER#u1`、`SK`（排序键）=`PROFILE`。
- 查用户全部订单：`PK=USER#u1, SK begins_with ORDER#`。
- 全局订单按日期：GSI 上 `GSI1PK=ORDERS, GSI1SK=日期`。

## When to Use

典型场景：

- 变更驱动的下游：审计日志、缓存失效、跨表同步——Streams + Lambda 自动接力。
- 有生命周期的小对象：会话、验证码、临时令牌——TTL 到点自动清理。
- 跨条目一致性：扣库存 + 写订单、转账双边记账——事务全成全败。
- 多实体高关联业务：用户/订单/设备同属一个域，单表设计一张表全覆盖。

何时不用：需要任意字段临时查询与聚合时（DynamoDB 要求访问模式预先设计）；
分析型扫描负载为主时（选 Athena/Redshift 对接 S3）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| DynamoDB Streams + Lambda | 变更近实时推给消费者 | 审计、同步、事件触发 |
| DynamoDB TTL | 声明式过期，无代码 | 会话/临时数据清理 |
| TransactWriteItems | 最多 100 操作全成全败 | 跨条目一致性 |
| 关系库 | SQL 灵活，扩展受限 | 查询模式多变的中小规模 |

## Quick Start

前置条件：LocalStack 运行中（本机若 DynamoDB provider（LocalStack 内部模拟 DynamoDB 的组件）异常，先跑
`bash scripts/load_resources.sh fix-dynamodb`）。运行方式：

```bash
cd labs/15_dynamodb_advanced
./dynamodb_advanced.sh            # 建表(开流)+审计函数 → 四段演示 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] ① Streams → Lambda 审计：写入与修改都留痕
  ✅ 审计表收到 INSERT + MODIFY 两条流记录
  ✅ 审计含新镜像 name=bob-2（NEW_AND_OLD_IMAGES 生效）
=====> [observe] ② 单表设计：PK/SK 模板 + GSI 支撑三种访问模式
  ✅ 访问模式①：某用户的全部订单（begins_with）
  ✅ 访问模式②：某用户的资料（点查）
  ✅ 访问模式③：全局订单按日期排序（GSI）
=====> [observe] ③ 事务探活（短超时，12 秒内不响应即降级）
  ✅ TransactWriteItems 可用（全部成功或全部回滚）
=====> [observe] ④ TTL 探活（短超时）
  ✅ update-time-to-live 可用
```

单表设计的核心是键模板（`configs/table.json`，主表开 Streams）：

```jsonc
{
  "KeySchema": [ {PK HASH}, {SK RANGE} ],       // USER#u1 / ORDER#2026-01-01#o1
  "GlobalSecondaryIndexes": [{ "IndexName": "GSI1", ... }],
  "StreamSpecification": {
    "StreamEnabled": true,
    "StreamViewType": "NEW_AND_OLD_IMAGES"      // 流记录带新旧镜像，审计的关键
  }
}
```

新手第一个失败点：事件源映射建在流上之后，审计 Lambda 写回**同一张开了流的
表**会无限自触发——审计必须写到另一张表（本实验的 ho15-audit）。

## How It Works

![DynamoDB 进阶](images/dynamodb_advanced.svg)

> 怎么看：主表开着 Streams（写入产生带新/旧镜像的流记录，Lambda 审计落库）；
> 单表里 `USER#u1/PROFILE`、`USER#u1/ORDER#…`、`GSI1PK=ORDERS` 三种键模板支撑
> 三种查询；事务横跨多个 Put 全成全败；TTL 字段到点由后台清理。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/15_dynamodb_advanced/images/dynamodb_advanced.html)
> （或本地打开 [`images/dynamodb_advanced.html`](images/dynamodb_advanced.html)）。

**Streams 如何产生审计**：表开启 `NEW_AND_OLD_IMAGES` 后，put-item 与
update-item 各产生一条流记录（eventName 分别为 INSERT/MODIFY），事件源映射
推给审计 Lambda。

实测审计表恰好收到 2 条，且 MODIFY 记录的新镜像里能看到改后的 `name=bob-2`。

**事务如何探活与降级**：`transact-write-items` 一次提交两个 Put；本机曾出现
挂起（aws.md 历史问题），脚本用 12 秒短超时探活——实测本机（修复 provider 后）
直接可用；若不可用则自动降级为条件写组合并如实记录。

**TTL 如何声明**：`update-time-to-live` 指定 `expire_at` 属性（Number 类型的
秒级时间戳）后，条目到期由后台清理——实测标记成功；注意清理是"到期后数天内"
的尽力而为，不能当精确定时器。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **审计表收到重复流记录**：事件源映射至少一次投递。解法：审计条目按"事件名
  + 键"做幂等主键，重放不重复入库。
- **事务挂起拖垮后续调用**：本机历史问题（provider 二进制残片，lab 02 已修）。
  解法：探活短超时 + 降级路径，绝不让脚本卡死。
- **TTL 字段类型写错**：必须是 Number 类型的秒级 epoch。解法：写入时用
  `str(int(timestamp))`。
- **GSI 忘记投影属性**：默认只投影键。解法：`ProjectionType: ALL` 或 INCLUDE
  按需声明。

深入问答：

- **Q: 单表设计的收益与代价？** A: 收益是极少请求拼装、单一热点管理；代价是
  学习曲线与"一张表看不懂业务"——必须以访问模式清单驱动设计。
- **Q: Streams 的四种 ViewType？** A: KEYS_ONLY / NEW_IMAGE / OLD_IMAGE /
  NEW_AND_OLD_IMAGES；审计要新旧对比选最后者，容量成本翻倍。
- **Q: 事务与条件写的边界？** A: 单条目保护用条件写（1 倍成本）；多条目原子性
  用事务（2 倍成本、上限 100 操作）。
- **Q: TTL 能当精确定时器吗？** A: 不能，清理是"到期后数天内"的尽力而为；
  精确定时用 Streams + Lambda 或 Step Functions 的 Wait。

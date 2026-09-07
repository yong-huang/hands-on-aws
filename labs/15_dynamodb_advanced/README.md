# 15 · DynamoDB 进阶：Streams、TTL、事务与单表设计

> lab 02 会用 DynamoDB 了，但四件生产利器还没碰：**Streams**（变更捕获）、
> **TTL**（自动过期）、**事务**（多表 ACID）、**单表设计**（一套主键支撑多种
> 访问模式）。本实验逐一做实——包括对"本机事务/TTL 曾挂起"的探活与降级实录。

## 1. 为什么需要它

- **Streams**：把"数据变了"变成事件（审计、缓存失效、跨表同步）——CDR 的起点。
- **TTL**：会话、验证码、临时令牌的自动清理，不写一行删除代码。
- **事务**：扣库存 + 建订单必须同生共死。
- **单表设计**：DynamoDB 的建模正统——主键模板化，一张表服务整个应用。

## 2. 总览：核心机制一图看懂

![DynamoDB 进阶](images/dynamodb_advanced.svg)

> 怎么看：主表开着 Streams（写入产生带新/旧镜像的流记录，Lambda 审计落库）；
> 单表里 `USER#u1/PROFILE`、`USER#u1/ORDER#…`、`GSI1PK=ORDERS` 三种键模板支撑
> 三种查询；事务横跨多个 Put 全成全败；TTL 字段到点由后台清理。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/15_dynamodb_advanced/images/dynamodb_advanced.html)
> （或本地打开 [`images/dynamodb_advanced.html`](images/dynamodb_advanced.html)）。

心智模型一句话：**单表设计 = 把"访问模式"翻译成主键模板；Streams/TTL/事务是三个独立开关。**

## 3. 快速开始

```bash
cd labs/15_dynamodb_advanced
./dynamodb_advanced.sh            # 建表(开流)+审计函数 → 四段演示 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] ① Streams → Lambda 审计：写入与修改都留痕
  ✅ 审计表收到 INSERT + MODIFY 两条流记录
  ✅ 审计含新镜像 name=bob-2（NEW_AND_OLD_IMAGES 生效）
=====> [observe] ② 单表设计：PK/SK 模板 + GSI 支撑三种访问模式
  ✅ 访问模式①：某用户的全部订单（begins_with）
  ✅ 访问模式③：全局订单按日期排序（GSI）
=====> [observe] ③ 事务探活（短超时，12 秒内不响应即降级）
  ✅ TransactWriteItems 可用（全部成功或全部回滚）
=====> [observe] ④ TTL 探活（短超时）
  ✅ update-time-to-live 可用
```

## 4. 核心概念

### 4.1 Streams：变更即事件

建表时开 `NEW_AND_OLD_IMAGES`，每次 INSERT/MODIFY/REMOVE 都产生带新旧镜像的流
记录。本实验：put + update → 审计表精确收到 INSERT 与 MODIFY 两条，且 MODIFY
的新镜像里能看到 `name=bob-2`。消费侧用事件源映射（lab 04/12 同款）。

### 4.2 单表设计：键模板

| 访问模式 | 键 |
|:---|:---|
| 某用户的资料 | `PK=USER#u1, SK=PROFILE` |
| 某用户的订单 | `PK=USER#u1, SK begins_with ORDER#` |
| 全局订单按日期 | `GSI1PK=ORDERS, GSI1SK=日期` |

实测三种 Query 全部命中。要点：**实体的"种类"编进 SK 前缀，"跨实体查询"编进
GSI**——一张表、零 Scan。

### 4.3 事务与探活降级

`TransactWriteItems` 最多 100 条目全成全败。aws.md 记录本机事务曾挂起——本脚本
用 12 秒短超时**先探活**：本机实测通过（lab 02 修复 provider 后事务一并恢复）；
若不可用，自动降级为"条件写组合"（`attribute_not_exists` 防重复）并如实记录。

### 4.4 TTL：声明式过期

`update-time-to-live` 声明 `expire_at` 字段后，条目到期由后台清理。注意两点：
TTL 按**秒级时间戳**（Number 类型）；删除是"通常在到期后数天内"的尽力而为，
不能当精确定时器。本机实测：标记成功；过期清理按需执行。

## 5. 配置关键字段（configs/table.json）

```jsonc
{
  "KeySchema": [ {PK HASH}, {SK RANGE} ],
  "GlobalSecondaryIndexes": [{ "IndexName": "GSI1", ... }],
  "StreamSpecification": {
    "StreamEnabled": true,
    "StreamViewType": "NEW_AND_OLD_IMAGES"   // 流记录带新旧镜像，审计的关键
  }
}
```

坑清单：

- 事件源映射要等表 ACTIVE 且流已创建（LatestStreamArn 存在）后再建；
- 审计条目按"事件名+键"做幂等主键，重放不重复入库；
- 事务条目数上限 100、总大小 4MB，超了拆批；
- TTL 字段名随意但类型必须是 Number（秒级 epoch）。

## 6. 文件结构

```text
labs/15_dynamodb_advanced/
├── README.md                    # 本文件
├── dynamodb_advanced.sh         # 主脚本：建表/审计函数 → 四段演示（含探活降级）→ 清理
├── stream_audit.py              # 流审计 Lambda（NEW_AND_OLD_IMAGES 落审计表）
├── configs/
│   └── table.json               # 主表声明式定义（键+GSI+Stream）
└── images/
    ├── dynamodb_advanced.architecture.json  # 图源（Typed JSON IR）
    ├── dynamodb_advanced.html               # 交互版
    └── dynamodb_advanced.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: 单表设计的收益与代价？** A: 收益是极少的请求拼装、单一热点管理；代价是
  学习曲线与"一张表看不懂业务"——必须以访问模式清单驱动设计。
- **Q: Streams 的四种 ViewType？** A: KEYS_ONLY / NEW_IMAGE / OLD_IMAGE /
  NEW_AND_OLD_IMAGES；审计要新旧对比选最后者，容量成本翻倍。
- **Q: 事务与条件写的边界？** A: 单条目保护用条件写（1 倍成本）；多条目原子性
  用事务（2 倍成本、上限 100 条）。
- **Q: TTL 的可靠性定位？** A: "最终会删"的非关键机制，不能做精确调度；需要
  精确定时用 DynamoDB Streams + Lambda 或 Step Functions Wait。
- **Q: 热分区在单表设计里怎么办？** A: 写键加后缀打散（write sharding），读侧
  并行查询再聚合；或把高频读挪进 GSI/缓存。

## 8. 总结

Streams 让数据"会说话"（变更即事件），TTL 让数据"会谢幕"，事务让操作"同生共
死"，单表设计让一表撑起全部访问模式——DynamoDB 的进阶武器库验收完毕，其中
事务与 TTL 在修复 provider 后本机直接可用。下一篇进入第五阶段：Lambda 的
工程化进阶（Layers、版本灰度、异步死信）。

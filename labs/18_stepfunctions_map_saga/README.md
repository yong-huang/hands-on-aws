# 18 · Step Functions 深化：Map 动态并行与 Saga 补偿

> 在 lab 06 的状态机基础上引入三件进阶武器：Map（对数组动态并行执行子流程）、
> Saga 补偿（失败时反向取消已完成步骤）、按错误类型分类的重试。本实验以订单
> "扣库存 → 并行发货"流程做实，共 8 项真实断言。

## Background

lab 06 的订单状态机只有单件商品。真实业务的订单有 N 个 SKU（最小库存单位，此处即单件商品），要求并行发货；且
当"扣了库存但发货失败"时，需要把库存退回去——这正是分布式事务经典难题的
Saga 解法（把大事务拆成本地事务序列，失败时反向执行补偿）。

用普通代码实现会撞上两堵墙。第一，并行度与失败聚合要手工管理：N 个发货任务、
部分失败怎么算、并发上限多少，全是容易出错的细节。第二，补偿逻辑与正向逻辑
耦合：重构正向流程常常忘了同步改补偿。

Step Functions 用 Map 状态解决前者，
用 Catch 分支 + 反向任务解决后者——补偿本身也是状态图的一部分，重构时一眼
可见。

## What

一句话定义：Map 是 Step Functions 的动态并行状态——对输入数组每个元素执行
同一子状态机，`MaxConcurrency` 控制并发上限，输出为各分支结果的数组。

心智模型：可以把 Map 想象成流水线上的并排工位——传送带（输入数组）上每件
商品都过一个工位（ShipOne），工位数上限是 MaxConcurrency。但和真实流水线
不同的是：工位数随商品数自动伸缩（3 件开 3 个、100 件最多也只开 2 个），而且
每件商品的执行结果会按顺序汇集成结果数组交给下一站。

三个进阶机制：

- **Map**：动态并行，元素数运行时决定。
- **Saga 补偿**：Catch 捕获失败后，调用反向任务（退回库存）——执行整体仍是
  SUCCEEDED。
- **分类重试**：`States.TaskFailed`（业务失败）重试，`States.Timeout` 不重试。

## When to Use

典型场景：

- 批量处理：订单多 SKU 发货、文件批转码、账号批初始化——数量运行时才知道。
- 需要失败补偿的多步流程：扣款/发货/通知链上任一环失败，反向取消已执行步骤。
- 不同错误不同策略：业务冲突重试、系统超时直接补偿。

何时不用：元素需要严格全局有序（Map 并行不保序，改串行 Task 或 FIFO（先进先出队列，保证顺序））；
流程只有固定几个固定分支（Parallel 更直观）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Map | 元素数运行时决定，子流程可复杂 | 批量同构处理 |
| Parallel | 固定分支编译期确定 | 固定的几条并行线 |
| 单 Task + 内部并发 | 函数内自己开线程池 | 简单批处理、不需逐步审计 |
| Distributed Map | 子任务量超大（>1 万）时读写 S3 | 海量批处理（真实 AWS 特性） |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/18_stepfunctions_map_saga
./stepfunctions_map_saga.sh            # 部署 → 成功/失败两路径 → 探活 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 成功路径：Map 并行发货 3 件（MaxConcurrency=2）
  ✅ 执行成功
  ✅ Map 全部完成，输出 3 件发货结果
=====> [observe] 失败路径：Reserve 失败（Retry 1 次耗尽）→ Compensate 取消
  ✅ 补偿后整体成功
  ✅ Saga 补偿路径生效
  ✅ Reserve 失败 2 次（首跑 + Retry 1 次）
=====> [observe] waitForTaskToken 回调模式探活
  ✅ 回调模式状态机可创建（SendTaskSuccess 回调在本机可演练）
```

状态机的核心片段（`configs/state-machine.asl.json`）——Map 与分类重试：

```jsonc
"ShipAll": {
  "Type": "Map",
  "ItemsPath": "$.items",              // 待遍历数组
  "MaxConcurrency": 2,                 // 并发上限
  "Iterator": { "StartAt": "ShipOne", "States": { ... } },   // 子状态机
  "ResultPath": "$.shipped",           // 结果数组合并进输入
  "Next": "Done"
},
"Reserve": {
  "Retry": [
    { "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 1, "MaxAttempts": 1 },  // 业务失败：重试 1 次
    { "ErrorEquals": ["States.Timeout"], "MaxAttempts": 0 }                            // 超时：不重试
  ]
}
```

新手第一个失败点：Map 的 `Iterator` 是**独立子状态机**，内部状态的 End/Next
只作用于子流程；写成引用外层状态名会直接校验失败。

## How It Works

![Step Functions Map 与 Saga](images/stepfunctions_map_saga.svg)

> 怎么看：Reserve 失败走红色补偿支线（Compensate 取消已扣库存）；成功则进入
> Map 框——对 items 数组每个元素并行执行 ShipOne 子状态机（MaxConcurrency=2），
> 结果数组汇入 Done。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/18_stepfunctions_map_saga/images/stepfunctions_map_saga.html)
> （或本地打开 [`images/stepfunctions_map_saga.html`](images/stepfunctions_map_saga.html)）。

**成功路径如何并行**：seed=good（脚本注入的故障开关，good=成功）时 Reserve 扣库存成功，Map 把
`items=[{sku:a},{sku:b},{sku:c}]` 交给最多 2 个并发的 ShipOne——实测输出数组
`count=3`，执行历史可看到并行调度的记录。

**补偿如何被证实**：seed=bad 时 Reserve 抛 `inventory conflict`，按声明重试
1 次后 Catch 触发，Compensate 调用取消函数，输出 `decision=compensated`。

**执行状态仍是 SUCCEEDED**——失败被业务路径消化，这就是 Saga 的失败消化
语义。

**回调模式探活**：`lambda:invoke.waitForTaskToken` 让状态机暂停等待外部
`SendTaskSuccess`——本机构建可创建该状态机（实测通过），完整回调演练可作为
自学延伸。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **Map 内引用外层状态报校验错**：Iterator 是独立子状态机，只能引用自己内部
  的状态。解法：需要的字段先由父流程放进每个元素。
- **Map 分支失败整体失败**：默认语义。解法：要"部分成功"就把容错写进 Iterator
  内部（分支自带 Catch）。
- **补偿失败没人管**：Compensate 自身也要配 Retry，且失败进死信/告警。
- **ResultPath 忘配**：Map 结果覆盖整个输入（lab 06 老坑），后续状态拿不到
  seed 字段。

深入问答：

- **Q: Map 与 Parallel 的区别？** A: Parallel 是固定几条分支（编译期确定）；
  Map 对运行时数组循环，元素数任意，天然适合批处理。
- **Q: Saga 与分布式事务（2PC，两阶段提交，强一致但需阻塞等待协调者）的区别？** A: Saga 无锁、最终一致、每步本地
  事务 + 显式补偿；2PC 强一致但阻塞——长流程高并发几乎都选 Saga。
- **Q: 补偿失败怎么办？** A: 补偿设计成幂等可重入（幂等：同一操作重复执行，结果不变），失败进告警人工介入；严苛
  场景记录补偿日志表对账。
- **Q: MapRun 是什么？** A: Map 执行的运行实例，有独立历史与失败容忍度
  （ToleratedFailurePercentage），可对整个 MapRun 告警。

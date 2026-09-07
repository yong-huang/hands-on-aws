# 18 · Step Functions 深化：Map 动态并行与 Saga 补偿

> lab 06 的状态机是"一条线几个岔口"；真实工作流还要**批量并行**（100 个订单
> 逐个发货）和**失败回滚**（扣了库存但发货炸了要退回去）。本实验引入 Map 状态、
> 补偿任务与按错误类型分类的重试——Saga 模式的完整落地。

## 1. 为什么需要它

- **Map**：对数组每个元素跑同一子流程，MaxConcurrency 控并发——批处理的标准件。
- **补偿（Saga）**：长事务拆成本地事务，失败时反向执行已完成步骤的"取消"。
- **错误分类**：业务失败重试、超时不重试——用两条 Retry 规则表达。

## 2. 总览：核心机制一图看懂

![Step Functions Map 与 Saga](images/stepfunctions_map_saga.svg)

> 怎么看：Reserve 失败走红色补偿支线（Compensate 取消已扣库存）；成功则进入
> Map 框——对 items 数组每个元素并行执行 ShipOne 子状态机（MaxConcurrency=2），
> 结果数组汇入 Done。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/18_stepfunctions_map_saga/images/stepfunctions_map_saga.html)
> （或本地打开 [`images/stepfunctions_map_saga.html`](images/stepfunctions_map_saga.html)）。

心智模型一句话：**Map 是"对数组的 for 循环"，Compensate 是"失败时倒着走一遍"。**

## 3. 快速开始

```bash
cd labs/18_stepfunctions_map_saga
./stepfunctions_map_saga.sh            # 部署 → 成功/失败两路径 → 清理
```

真实运行输出：

```text
=====> [observe] 成功路径：Map 并行发货 3 件（MaxConcurrency=2）
  ✅ Map 全部完成，输出 3 件发货结果
=====> [observe] 失败路径：Reserve 失败（Retry 1 次耗尽）→ Compensate 取消
  ✅ 补偿后整体成功
  ✅ Reserve 失败 2 次（首跑 + Retry 1 次）
=====> [observe] waitForTaskToken 回调模式探活
  ✅ 回调模式状态机可创建
```

## 4. 核心概念

### 4.1 Map：动态并行

`ItemsPath` 指向输入数组，`Iterator` 是每个元素的子状态机，`MaxConcurrency`
限并发。本实验 3 个 SKU 两并发发货，输出是各分支结果的数组（实测 count=3）。
元素数量运行时才知——这就是"动态"。

### 4.2 补偿：把 Saga 写成 Catch 分支

Reserve 的 Catch 指向 Compensate 任务（调用取消 Lambda），执行仍以 SUCCEEDED
收尾、decision=compensated。多步骤 Saga 的通用形态：每个正向步骤配反向步骤，
Catch 链按已完成的顺序反向触发。

### 4.3 错误分类重试

```jsonc
"Retry": [
  { "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 1, "MaxAttempts": 1 },  // 业务失败：重试 1 次
  { "ErrorEquals": ["States.Timeout"],    "MaxAttempts": 0 }                          // 超时：不重试
]
```

实测 seed=bad 恰好失败 2 次（首跑+重试 1 次）后进入补偿——执行历史可逐条核对。

### 4.4 回调模式（waitForTaskToken）

Task Resource 用 `lambda:invoke.waitForTaskToken`，把 Task.Token 交给人类/外部
系统，事后 `SendTaskSuccess` 带回结果。本机探活：状态机可创建 ✅（完整回调演练
可作为自学延伸）。

## 5. 配置关键字段（configs/state-machine.asl.json）

```jsonc
"ShipAll": {
  "Type": "Map",
  "ItemsPath": "$.items",          // 待遍历数组
  "MaxConcurrency": 2,             // 并发上限
  "Iterator": { "StartAt": "ShipOne", "States": { ... } },   // 子流程
  "ResultPath": "$.shipped",       // 结果数组合并进输入
  "Next": "Done"
},
"Reserve": {
  "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "Compensate" }]
}
```

坑清单：

- Map 的 Iterator 是**独立状态机**，内部的 End/Next 只作用于子流程；
- Map 分支失败默认整体失败——要"部分成功"就把容错写进 Iterator；
- ResultPath 忘了配会覆盖整个输入（lab 06 的老坑）；
- 补偿也可能失败——生产上给 Compensate 自己加 Retry。

## 6. 文件结构

```text
labs/18_stepfunctions_map_saga/
├── README.md                          # 本文件
├── stepfunctions_map_saga.sh          # 主脚本：部署 → 双路径演练 → 探活 → 清理
├── configs/state-machine.asl.json     # 状态机定义（Map+补偿+分类重试）
├── functions/{reserve,ship,cancel}.py # 正向任务 / Map 任务 / 补偿任务
└── images/
    ├── stepfunctions_map_saga.architecture.json  # 图源（Typed JSON IR）
    ├── stepfunctions_map_saga.html               # 交互版
    └── stepfunctions_map_saga.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: Map 与 Parallel 的区别？** A: Parallel 是固定数量分支同时跑（结构编译期
  确定）；Map 对运行时数组循环，元素数任意，天然适合批处理。
- **Q: Saga 与分布式事务（2PC）的区别？** A: Saga 无锁、最终一致、每步本地事务
  + 显式补偿；2PC 强一致但阻塞——高并发长流程几乎都选 Saga。
- **Q: 补偿失败怎么办？** A: 补偿要设计成幂等可重入，失败进死信/告警人工介入；
  严苛场景记录"补偿日志表"对账。
- **Q: MapRun 是什么？** A: Map 执行的运行实例，有独立的历史与失败阈值
  （ToleratedFailurePercentage），可对整个 MapRun 设置告警。
- **Q: 回调模式适合什么场景？** A: 需要人工审批、外部系统异步回执的步骤——
  状态机"暂停"，Token 回来再继续，期间不占执行资源。

## 8. 总结

Map 让状态机"会循环"，补偿让它"会后悔"，分类重试让它"有分寸"——工作流的
三大进阶能力全部真机验证。下一篇换个端到端形态：S3 静态网站托管 + 无服务器
后端联调，做一个真的能打开的全栈应用。

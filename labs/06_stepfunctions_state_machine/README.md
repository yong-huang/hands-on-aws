# 06 · Step Functions 状态机编排：分支、并行、重试与补偿

> AWS Step Functions 是一种托管的工作流编排服务：用 JSON 状态机（Amazon States
> Language，ASL）声明多步流程的控制流，由平台驱动 Lambda 等任务按图执行。本实验
> 用一个订单状态机跑通成功、拒绝、重试补偿三条路径，共 9 项真实断言。

## Background

在编排服务普及之前，多步业务流程（校验 → 扣款 → 通知 → 审计）的控制流写在
应用代码里：顺序调用、try/catch、手写重试循环。

代码化的控制流撞上两堵墙。第一，失败处理让代码膨胀：扣款失败要重试几次？重试
耗尽去哪？每加一步业务，容错代码翻一倍。

第二，流程不可观测：线上卡在哪一步、每步的输入输出是什么，要靠翻应用日志
拼凑。Step Functions（2016 年推出）把控制流从代码里抽出来：用 ASL 这套 JSON
声明状态与转移，平台驱动执行，并为每次执行保留完整的输入输出历史。

## What

一句话定义：Step Functions 是一种以状态机（state machine，由状态与转移组成的
有向图）为核心的编排服务，按声明驱动任务执行并记录每步的输入输出。

心智模型：可以把状态机想象成一张地铁线路图——每个车站是一个状态（本实验用到
5 种：Task 调 Lambda、Choice 条件分支、Parallel 并行双线、Pass 数据加工、
终态），列车（执行）按图行驶并在每站留下车票存根（执行历史）。

但和地铁不同的是：某站故障时列车不会停在半路，而是按声明的 Retry 与 Catch
规则改道——失败被当成一种数据交给后续状态处理。

三个关键机制：

- **Retry**：声明式重试，可配次数、间隔与指数退避。
- **Catch**：重试耗尽后的分流去向，错误对象（errorType/Cause）作为数据传入
  下一个状态。
- **ResultPath**：决定任务结果合并进输入（`$.charge`）还是覆盖输入（`$`）。

## When to Use

典型场景：

- 多步业务流程：订单履约、退款审批——步骤间有依赖、有条件分支、有失败补偿。
- 需要可审计的流程：执行历史天然是"每步输入输出"的回放，排错不靠翻日志。
- 批处理：Map 状态对数组并行执行同一子流程（lab 18 深化）。

何时不用：单一 API 请求内的小逻辑（几行 if/else 能解决，直接写代码）；超高
吞吐的简单转发（每步编排有状态管理开销）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Step Functions Standard | 持久状态机、执行历史 90 天、精确一次 | 业务流程编排、长周期任务 |
| Step Functions Express | 高吞吐、便宜、至少一次 | 短平快的海量事件处理 |
| 代码内编排（temporal 等） | 自建/自托管，灵活 | 需要特定 SDK 能力或自托管 |
| 消息队列（MQ）+ 消费者 | 无流程概念，只管投递 | 单步解耦，无需多步编排 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/06_stepfunctions_state_machine
./stepfunctions_state_machine.sh            # 部署 4 函数 + 状态机 → 三条路径演示 → 清理
./stepfunctions_state_machine.sh observe    # 只跑三条路径断言（约 40 秒，含重试退避）
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 成功路径 seed=2：校验过 → 收款 → Parallel 双分支 → fulfilled
  ✅ 输出含 decision + 双分支结果
=====> [observe] 分支路径 seed=0：校验不过 → Choice 走 Rejected
  ✅ Choice 分支正确
=====> [observe] 重试+补偿路径 seed=3：收款失败 → Retry×2 耗尽 → Catch 进补偿
  ✅ 补偿后整体成功（不是 FAILED）
  ✅ Charge 失败 3 次（首跑 + Retry×2），重试真实发生
```

状态机定义在 `configs/state-machine.asl.json`，其中重试规则是最核心的一段：

```jsonc
"Retry": [
  {
    "ErrorEquals": ["States.TaskFailed"],   // 匹配"任务执行失败"这类错误
    "IntervalSeconds": 1,                   // 首次重试间隔 1 秒
    "MaxAttempts": 2,                       // 最多重试 2 次（不含首跑）
    "BackoffRate": 2.0                      // 每次间隔乘 2（1s → 2s，指数退避）
  }
]
```

新手第一个失败点：`Pass` 状态写固定 `Result` 会**整体覆盖**输入数据——要用
`Parameters` 加 `"字段.$": "$.字段"` 才能透传原输入（本实验的 Rejected/
Compensate 状态就是这么写的）。

## How It Works

![Step Functions 状态机](images/stepfunctions_state_machine.svg)

> 怎么看：主线是"校验 → 收款 → 并行(通知‖审计) → 完成"；Choice 菱形按
> `$.valid` 分流；Charge 节点挂着重试环（失败 3 次后）跳入补偿分支——**补偿后
> 整个执行仍是 SUCCEEDED**——Saga（把大事务拆成本地事务序列、失败时反向
> 执行补偿的分布式模式）的雏形。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/06_stepfunctions_state_machine/images/stepfunctions_state_machine.html)
> （或本地打开 [`images/stepfunctions_state_machine.html`](images/stepfunctions_state_machine.html)）。

**三条路径如何分别走到终点**：

- 成功（seed=2）：Validate 校验通过 → Charge 收款成功 → Parallel 并行跑通知与
  审计两个分支 → 输出 `decision=fulfilled`，实测双分支结果都进输出。
- 拒绝（seed=0）：校验不通过 → Choice 命中 `Default` → `decision=rejected`。
- 补偿（seed=3）：校验通过但收款抛错 → 按声明重试 2 次仍失败 → Catch 把错误
  放进 `$.error` → Compensate 分支输出 `decision=compensated`——**执行状态仍
  是 SUCCEEDED**，因为失败已被业务路径消化。

**重试如何被证实**：`get-execution-history` 返回每一步的事件流水。seed=3 的
执行里 `LambdaFunctionFailed` 事件恰好 3 条（首跑 + 2 次重试）——重试不是
配置上的文字，而是可数的历史记录。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **Pass 状态把输入"弄丢了"**：固定 `Result` 覆盖整个输入。解法：用
  `Parameters` + `.$` 后缀引用原输入字段（如 `"seed.$": "$.seed"`）。
- **断言重试次数查不到事件**：LocalStack 用旧版事件名
  `LambdaFunctionFailed`，不是新版的 `TaskFailed`。解法：按旧名统计。
- **Choice 未命中直接失败**：抛 `States.NoChoiceMatched`。解法：永远给
  Choice 配 `Default`。
- **`AttributeAlreadyExists` 建状态机失败**：同名状态机残留。解法：先
  `delete-state-machine`（脚本 apply 已处理）。

深入问答：

- **Q: Standard 与 Express 工作流怎么选？** A: Standard 精确一次、历史 90 天，
  适合业务流程；Express 高吞吐、至少一次、按执行计费，适合流式短任务。
- **Q: 重试耗尽后执行算失败吗？** A: 配了 Catch 就不算——错误被转成数据进入
  补偿路径，execution 仍 SUCCEEDED；没配 Catch 才会 FAILED。
- **Q: Parallel 的失败语义？** A: 一个分支失败整个 Parallel 失败；要"部分
  成功"就把容错写进每个分支内部。
- **Q: Saga 补偿如何实现？** A: 每个正向步骤配一个反向任务，Catch 触发已执行
  步骤的取消链（lab 18 有完整实现：Map 并行 + 失败自动退回库存）。

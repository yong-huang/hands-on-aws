# 06 · Step Functions 状态机编排：分支、并行、重试与补偿

> Lambda 一个函数只干一件事，但真实业务是流水账："校验 → 扣款 → 通知 + 审计 →
> 完成"，还要处理"扣款失败了怎么办"。把这些 if/else 和重试写进代码就是一坨面条；
> Step Functions 用**状态机**（Amazon States Language，一套 JSON）把流程画成图纸，
> 失败重试、并行分支、错误补偿全是声明式配置。

## 1. 为什么需要它

- **流程即配置**：ASL 一个 JSON 描述全部控制流，代码（Lambda）只负责业务动作，
  排错时执行历史就是"每一步的输入输出回放"。
- **可靠性内置**：`Retry` 声明"失败重试几次、间隔多少、指数退避"，`Catch` 声明
  "重试耗尽去哪"——不用手写重试循环。
- 本实验的三条路径（成功/拒绝/补偿）就是生产订单系统的三种真实结局。

## 2. 总览：核心机制一图看懂

![Step Functions 状态机](images/stepfunctions_state_machine.svg)

> 怎么看：主线是"校验 → 收款 → 并行(通知‖审计) → 完成"；Choice 菱形按
> `$.valid` 分流；Charge 节点挂着重试环（失败 3 次后）跳入补偿分支——**补偿后
> 整个执行仍是 SUCCEEDED**，Saga 的雏形。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/06_stepfunctions_state_machine/images/stepfunctions_state_machine.html)
> （或本地打开 [`images/stepfunctions_state_machine.html`](images/stepfunctions_state_machine.html)）。

心智模型一句话：**状态机管控制流，Lambda 管业务流；失败是数据，不是异常。**

## 3. 快速开始

```bash
cd labs/06_stepfunctions_state_machine
./stepfunctions_state_machine.sh            # 部署 4 函数 + 状态机 → 三条路径演示 → 清理
./stepfunctions_state_machine.sh observe    # 只跑三条路径断言（约 40 秒，含重试退避）
```

真实运行输出（节选）：

```text
=====> [observe] 成功路径 seed=2：校验过 → 收款 → Parallel 双分支 → fulfilled
  ✅ 输出含 decision + 双分支结果
=====> [observe] 分支路径 seed=0：校验不过 → Choice 走 Rejected
  ✅ Choice 分支正确
=====> [observe] 重试+补偿路径 seed=3：收款失败 → Retry×2 耗尽 → Catch 进补偿
  ✅ 补偿后整体成功（不是 FAILED）
  ✅ Charge 失败 3 次（首跑 + Retry×2），重试真实发生
```

## 4. 核心概念

### 4.1 ASL 六种基本状态

本实验用到 5 种：`Task`（调 Lambda）、`Choice`（按 `$.valid` 分支）、`Parallel`
（双分支同跑）、`Pass`（注入/改写数据）、`Succeed/Fail`（终态）。所有状态靠
`Next` 串成图，`ResultPath` 决定结果**合并进**输入还是覆盖输入。

### 4.2 Retry：重试是声明，不是循环

```jsonc
"Retry": [{ "ErrorEquals": ["States.TaskFailed"],
            "IntervalSeconds": 1, "MaxAttempts": 2, "BackoffRate": 2.0 }]
```

实测（seed=3）：charge 首跑失败 → 1s 后重试 → 2s 后再重试 → 仍失败 → 执行历史
里 `LambdaFunctionFailed` 恰好 3 条。`BackoffRate` 让每次间隔乘 2——指数退避。

### 4.3 Catch：失败是数据

重试耗尽后 `Catch` 把错误对象（`errorType/Cause`）放进 `$.error`，跳到
`Compensate` 分支"反向冲账"。**整个 execution 状态是 SUCCEEDED**——业务上的
失败被业务路径消化，这才叫补偿而非崩溃。

### 4.4 数据流：ResultPath 是关键旋钮

- `"ResultPath": "$.charge"`：任务结果塞进 `$.charge`，原输入保留；
- `"ResultPath": "$"`：覆盖整个输入（Validate 就这么干）；
- `Pass` 的固定 `Result` 会**整体覆盖输入**——要透传字段用 `Parameters` +
  `"seed.$": "$.seed"`（`.$` 后缀 = JSONPath 引用）。

## 5. 配置关键字段（configs/state-machine.asl.json）

```jsonc
{
  "StartAt": "Validate",
  "States": {
    "Valid?": {                       // Choice：命中 true 走 Charge，否则 Default
      "Type": "Choice",
      "Choices": [{ "Variable": "$.valid", "BooleanEquals": true, "Next": "Charge" }],
      "Default": "Rejected"
    },
    "Charge": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:function:ho06-charge",   // LocalStack 直调本机函数
      "Retry": [ /* 见 4.2 */ ],
      "Catch":  [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "Compensate" }],
      "ResultPath": "$.charge",       // 结果合并而非覆盖
      "Next": "FanOut"
    },
    "FanOut": { "Type": "Parallel", "Branches": [ /* Notify‖Audit 各自成图 */ ], "Next": "Done" }
  }
}
```

坑清单：

- **LocalStack 执行历史用旧版事件名**：`LambdaFunctionFailed/TaskFailed` 而非新版
  `TaskFailed`，按事件类型断言重试时要用旧名（本实验已处理）；
- Choice 必须有 `Default`，否则未命中直接抛 States.NoChoiceMatched；
- 函数返回异常 → 状态机视角是 `States.TaskFailed`；Lambda 本身超时/被拒才是
  `States.Timeout/Permissions`——重试规则按错误类别分开写；
- Pass 状态不带 `ResultPath` 默认覆盖整个输入，血泪坑。

## 6. 文件结构

```text
labs/06_stepfunctions_state_machine/
├── README.md                          # 本文件
├── stepfunctions_state_machine.sh     # 主演示脚本：部署 → 三条路径 → 清理
├── configs/
│   └── state-machine.asl.json         # 状态机定义（声明式，apply 直接消费）
├── functions/                         # 4 个真实 Lambda（脚本打包成 zip 部署）
│   ├── validate.py                    # seed>0 → 校验通过
│   ├── charge.py                      # seed=3 模拟收款被拒
│   ├── notify.py / audit.py           # Parallel 双分支
└── images/
    ├── stepfunctions_state_machine.workflow.json  # 图源（Typed JSON IR）
    ├── stepfunctions_state_machine.html           # 交互版
    └── stepfunctions_state_machine.svg            # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: Standard 与 Express 工作流的区别？** A: Standard 精确一次、执行历史 90 天、
  适合长流程；Express 高吞吐、至少一次、按执行时长计费，适合IoT/流式短任务。
- **Q: 重试耗尽后执行算失败吗？** A: 有 Catch 就不算——错误被Catch 转成数据进入
  补偿路径，execution 仍 SUCCEEDED；没有 Catch 才 FAILED。
- **Q: Parallel 的失败语义？** A: 一个分支失败整个 Parallel 失败（其它分支被
  取消）；需要"部分成功"就把容错写进分支内部（分支自带 Catch）。
- **Q: Saga 补偿怎么用 Step Functions 实现？** A: 每个正向步骤准备一个反向任务，
  用 Catch 触发已执行步骤的取消/退款链（lab 18 完整实现）。
- **Q: ResultPath/ResultSelector/InputPath 三兄弟？** A: InputPath 选输入、
  ResultSelector 选任务输出的投影、ResultPath 定结果合并位置——三者组合实现
  数据最小传递。

## 8. 总结

一个 ASL 文件表达了订单的三种命运：fulfilled、rejected、compensated——分支、
并行、重试、补偿全部真机验证。下一篇给数据上锁：KMS 信封加密与 Secrets Manager
的版本化机密管理。

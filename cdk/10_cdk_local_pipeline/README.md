# 10 · ⛓️ 本地 CI 流水线：CDK Pipelines 阶段语义的 make 实现

> `make pipeline` 一条命令跑完 synth → test → diff-review → deploy → smoke
> → destroy 六阶段；注入未加密桶后流水线死在 test、deploy 不发生。这是
> cdk/11 综合实战的交付通道。

## Background

CDK Pipelines 的本质不是某个服务，而是一组**阶段语义**：源变更触发合成、
质量门把关、变更审阅、分阶段部署、发布后验证。CodePipeline/CodeBuild 把
这套语义做成托管服务——但它们不在本机 LocalStack 授权内（实测
`codepipeline list-pipelines` 返回 "not included within your LocalStack
license"），也不该为学语义先买一套 CI 基础设施。

用 make 把同样的阶段语义在本地搭出来：每个阶段一个 target、失败即中止、
退出码非零——语义完整，载体不同。

## What

一句话定义：`make pipeline` 按序执行六个 target，任一失败流水线中止；
`HO40_INJECT=no_encryption` 注入坏产品后，test 阶段的断言套件抓红，
deploy 不会发生（实测栈不存在）。

心智模型：CDK Pipelines 是"带安检的机场"，make pipeline 是"同一套安检
流程的自建通道"——登机牌（synth 产物）、安检（test）、值机复核
（diff-review）、起飞（deploy）、落地确认（smoke）、清舱（destroy），
一个环节不过就停在原地。

## When to Use

典型场景：

- 本地/自建 CI（无 CodePipeline 授权或多云中立）承载 CDK 部署。
- 把"质量门"前置到合成期：坏配置在进云之前就被 pytest 拦下（cdk/07
  的断言套件在这里成为流水线的一等公民阶段）。
- 需要在阶段间插私有逻辑（审批钩子、通知、审计）而不受托管服务限制。

何时不用：团队已用 GitHub Actions/CodePipeline 且要多环境 promotion
（真实 CDK Pipelines 的 self-mutation、跨账户资产发布是 make 版替代不了的）；
需要审计级的执行历史与回滚（托管服务有完整记录）。

## Quick Start

前置：LocalStack 运行中（cdk/01-09 依赖不变）。

```bash
cd cdk/10_cdk_local_pipeline
make pipeline                          # 六阶段全绿 → 清栈归零
HO40_INJECT=no_encryption make pipeline  # 注入 → 死在 test，exit=2，deploy 不发生
make pipeline KEEP=1                   # 跳过 destroy，留栈观察
```

## How It Works

`Makefile`（~100 行，阶段即 target）与 CDK Pipelines 的语义对照：

| CDK Pipelines 概念 | 本流水线 | 拦截行为 |
|:---|:---|:---|
| Source/Build | `synth`：合成 + 产物存在性检查 | 合成失败即中止 |
| （质量门，社区惯例） | `test`：cdk/07 断言套件对**同一份 App** | 注入后 2 failed → 中止 |
| （人工审批关卡） | `diff-review`：已部署时 diff 非空即拦 | `APPROVED=1` 显式放行 |
| Stages(deploy) | `deploy`：cdklocal deploy | — |
| （发布后验证） | `make smoke`：SQS→Lambda→DDB 端到端 | 消息未落表即中止 |
| （清理） | `destroy`：清栈 + 残留探查 | 残留即非零 |

关键设计：**test 阶段合成的就是 deploy 要部署的同一个 App**（tests 导入
`app.Ho40Stack` 重建 Template，而非另写假栈）——注入才拦得住，"测的即
部署的"是流水线可信的前提。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **`$(shell wc -c ...)` 在解析期执行**：Makefile 解析时产物还没合成，
  输出空串（日志里"已合成（ bytes）"）。解法：配方内的运行期插值用
  `$$$( )`（即 shell 的 `$$(...)`），不要用 make 的 `$(shell)`。
- **CodePipeline/CodeBuild 不在 LocalStack 授权内**：即使 pro 版
  （120 服务），CodeSuite 也排除。解法：本实验的 make 降级——阶段语义
  等价，README 如实记录差异。
- **make 串行依赖顺序**：`pipeline: a b c` 无 `-j` 时严格左到右，失败
  即停——这正是流水线语义；加 `-j` 会破坏它。
- **diff 首部署陷阱**：栈不存在时 diff 是全量创建清单，"非空即拦"会
  拦住首次部署。解法：分"首部署放行 / 已部署拦变更"两种语义，与
  CDK Pipelines 的首次 StackSet 部署行为对齐。

深入问答：

- **Q: 为什么 test 放在 synth 之后而不是独立跑 pytest？** A: 测试合成的
  就是刚 synth 的同一份代码——synth 失败先于测试暴露；且保证"测的即
  部署的"，中间无第二合成路径。
- **Q: CDK Pipelines 的 self-mutation 是什么，make 版有吗？** A: 真实
  Pipelines 检测到流水线自身定义变化时会重建流水线（自变异）。make 版
  没有对应物——流水线即 Makefile，改了就生效，无需自变异。
- **Q: smoke 和 cdk/02 的冒烟有什么区别？** A: 同一链路（SQS→Lambda→
  DDB），但这里是**流水线阶段**而非一次性验证脚本——失败会中止发布，
  退出码对接 CI。
- **Q: diff-review 的 APPROVED=1 是不是形同虚设？** A: 在本地是演练
  语义；真实场景里这个开关对应审批系统的输出（如 PR approve 后注入），
  门的位置比门的解锁方式重要。

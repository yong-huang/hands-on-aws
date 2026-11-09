# 04 · 跨栈引用与参数共享三通道：Export/ImportValue · NestedStack · SSM

> 同一个队列 URL 走三条路给消费方：栈间属性引用（自动 Export/ImportValue）、
> 嵌套栈穿透（GetAtt Outputs）、SSM 运行时读取。三个消费 Lambda 各自报告拿到的
> URL，逐一与真实值比对。cdk/02 导出过的队列 ARN 在这里兑现。

## Background

cdk/02 造的构造库被两个 Stack 复用，但资源都在各自栈里。真实系统里组合
不可避免：网络栈的 VPC 要给计算栈用、队列要给另一个团队的栈消费。跨栈传值
有三条通道，适用场景各不相同：

- **Stack 属性引用**：`producer.queue.queue_url` 直接被另一个栈用——CDK 自动
  在源栈生成 `Export`、在消费栈生成 `Fn::ImportValue`。零手工，但形成隐式
  依赖（消费栈必须等源栈）。
- **NestedStack**：子栈作为父栈的资源存在，父栈引用子栈内资源 → 子模板独立
  成文件、父栈用 `Fn::GetAtt [嵌套栈资源, Outputs.X]` 取值。适合"一个部署
  单元拆多模板"，引用被限制在父栈边界内。
- **SSM Parameter Store**：IaC 只传参数名，值在部署期（写入方）与运行时
  （读取方）流转。解耦最彻底——读写双方甚至不在同一次部署里，代价是值
  不再由 IaC 端到端保证。

## What

一句话定义：四个栈验证三条通道——producer 建队列；consumer-ref 经栈属性
引用（Export/ImportValue）拿 URL；parent 栈经嵌套栈（GetAtt Outputs）拿
自己嵌套队列的 URL；consumer-ssm 的 Lambda 运行时从 SSM `get_parameter`
拿 URL。三个 Lambda 把拿到的值原样返回供断言比对。

心智模型：一栋楼（App）里接水管——属性引用是"预埋管"（部署时一次接通），
嵌套栈是"楼中楼的独立图纸"（父图纸引用子图纸的出口），SSM 是"物业登记簿"
（谁需要谁自己来查，登记和用水解耦）。

## When to Use

典型场景：

- 同一次部署内的栈间依赖 → 属性引用（自动、类型安全、diff 可见）。
- 模板过大要拆分 / 复用一组资源为部署单元 → NestedStack。
- 跨部署周期、跨团队、跨账号的共享配置（AMI ID、端点、开关）→ SSM。

何时不用：嵌套栈用于跨栈复用（改用构造库或 Export）；SSM 传"值必须与
本部署资源强一致"的内容（部署窗口内值可能漂移，上例传队列 ARN 这类
稳定标识才安全）。

## Quick Start

前置条件同 cdk/01-03，另需 `cdklocal bootstrap`（本机已实测可 bootstrap，
cdk/01 因未 bootstrap 而禁资产的限制在此解除）：

```bash
cd cdk/04_cdk_stack_sharing
cdklocal bootstrap aws://000000000000/us-east-1    # 首次一次即可
./cdk_stack_sharing.sh                             # apply → observe → clean
```

observe 阶段 8 条断言全绿即通过：三通道 URL 比对 + SSM 落值断言 +
对照表归档。产出 `output/sharing.md`（三通道 synth 产物差异对照表）。

## How It Works

四个栈五份模板（`output/` 归档）：

| 通道 | 栈 | 合成产物机制 | 断言 |
|:---|:---|:---|:---|
| 一 Stack 属性引用 | producer + consumer-ref | producer `Export` ×2；ref 模板 `Fn::ImportValue` ×1 | Lambda 返回 URL = 真实队列 URL |
| 二 NestedStack | parent（+ 独立 `.nested` 子模板） | `Fn::GetAtt [嵌套资源, Outputs.X]` ×1；子模板单独成文件 | Lambda 返回 URL = 嵌套队列 URL |
| 三 SSM 运行时 | consumer-ssm | 模板里只有参数名（出现 1 次），URL 不进模板 | Lambda `get_parameter` = 真实 URL |

部署顺序由依赖决定：producer 先行；consumer-ref/parent 与它同 App 部署时
CDK 自动排序；consumer-ssm 无 IaC 依赖，参数就位后单独部署。SSM 参数由
部署脚本以 CI/CD 方式写入（原因见踩坑第 1 条），写入值即 producer 队列
的 GetAtt 解析结果——"部署期落值、运行期取值"的通道语义不变。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **`AWS::SSM::Parameter` 的 CFN provider 不可用**：全新静态参数创建也报
  `ParameterAlreadyExists`（首次 PutParameter 成功后同操作内重试撞自己，
  静态/动态值均复现）。解法：参数写入移到部署脚本（对应真实世界 CI/CD
  写参数模式）；真实 AWS 的 CDK 写法保留在 app.py 注释中。
- **本版 LocalStack SSM `get-parameter` 对含 `/` 路径名全异常**：
  `foo/bar`、`ho04/src/queue-url` 一律 ValidationException（put 正常；
  labs/20 曾实测分层参数可用，疑为当前构建回归）。解法：参数名用无斜杠
  `ho04-queue-url`；真实 AWS 无此限制。
- **`NestedStack` 把子模板打包成资产**：无 bootstrap 时报 "This stack uses
  assets, so the toolkit stack must be deployed"。解法：`cdklocal bootstrap`
  （本机实测一次通过，CDKToolkit 栈 + 资产桶就绪）。cdk/01/32 的
  "禁资产"限制自 bootstrap 后解除。
- **通道二断言基准拿错**：嵌套消费方用的是嵌套栈里自己的队列，拿 producer
  队列当基准必然"失败"。解法：嵌套队列起显式名 `ho04-nested-queue`，
  各通道与各自的基准比对。
- **`StringParameter` L2 没有 `removal_policy`**：SSM 参数的删除策略走
  L1 `cfn_options.deletion_policy`（本实验已不用 CFN 托管参数，此坑供
  真实 AWS 迁移参考）。

深入问答：

- **Q: 三通道的删除耦合差在哪？** A: 属性引用最强——Export 被引用时源栈
  删除被拒（labs/26 验证过约束）；嵌套栈随父栈整体生灭；SSM 完全解耦，
  源栈删除后参数仍在（本实验 clean 显式删参数）。
- **Q: 什么时候 Export 会冲突？** A: Export 名全局唯一。CDK 自动生成的
  名字含栈名+逻辑 ID 散列，多实例不冲突；手工 `export_name` 才要小心。
- **Q: 嵌套栈内资源能被父栈外的栈引用吗？** A: 不能直接引用——输出提升
  到父栈后仍需父栈再 Export。嵌套是"封装边界"，不是全局共享通道。
- **Q: SSM 通道的值漂移怎么办？** A: 传稳定标识（队列名/ARN）而非易变值；
  或消费方校验值的可用性（本实验 Lambda 拿到 URL 后可发一条探活消息）。

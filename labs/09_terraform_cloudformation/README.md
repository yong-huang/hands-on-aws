# 09 · 基础设施即代码：Terraform 与 CloudFormation 双栈

> IaC（Infrastructure as Code，基础设施即代码）把云资源写成模板文件，apply 变
> 成可重复动作、destroy 一键归零。本实验用 Terraform（经 tflocal 包装）与
> CloudFormation 各搭同一套资源——对象存储 S3、消息队列 SQS、消息通知 SNS，
跑通 apply → 增量更新 → destroy 的
> 完整生命周期。

## Background

在 IaC 普及之前，云资源靠控制台点选或一条条 CLI 命令搭建。

手工搭建撞上三堵墙。第一，不可重复：环境坏了要凭记忆重建，搭两套环境细节必不
一致。第二，不可预览：改一个配置只能上线后验证，误删资源无从预警。

第三，无法协作：环境的"当前样子"只存在于某个人的脑子里。IaC 把资源声明写成
模板文件进版本库，由工具负责"让真实世界与模板一致"——Terraform（HashiCorp，
2014）与 CloudFormation（AWS 原生）是这一思路的两种代表实现。

## What

一句话定义：Terraform 与 CloudFormation 都是 IaC 工具——模板声明"要什么"，
工具对比真实与期望的差异（diff）后执行变更；两者的本质区别在状态放在哪里。

心智模型：可以把 IaC 工具想象成一位按图纸施工的装修队——模板是图纸，工具在
动工前给你看"改造清单"（Terraform 的 plan / CloudFormation 的 change set），
确认后照单施工。

但和真实装修队不同的是：施工完成后它会保留一份"已施工清单"（state），下次
动工前先核对这份清单——清单丢了，它就不认识自己建过的东西。

两种实现的分工：

- **Terraform**：状态文件（terraform.tfstate）本地自持，plan 是"模板 vs 状态"
  的本地 diff，HCL（HashiCorp 配置语言），多云通用。
- **CloudFormation**：状态托管在服务端"栈"里，`describe-stack-events` 可查
  变更流水，YAML/JSON，仅 AWS。

## When to Use

典型场景：

- 环境复现：模板进 git 后，任何人在任何 LocalStack 上一条命令重建整套资源
  （本实验双栈各含 S3+SQS+SNS）。
- 安全发布：改模板后先 plan/diff 预览，确认 destroy 计数为 0 再执行。
- 资源生命周期管理：实验/临时环境用完 `destroy`/`delete-stack` 干净退场。

何时不用：一次性探索（点控制台更快）；存量资源首次收编（需要 import 流程）；
超大规模且强多云需求之外、已深度绑定 AWS 组织能力的团队可优先 CFN 生态。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Terraform | HCL、多云、状态自持 | 多云或需要丰富表达力的团队 |
| CloudFormation | AWS 原生、状态托管 | 纯 AWS、需要服务端状态与漂移检测 |
| AWS CDK | 用编程语言生成 CFN 模板 | 偏好编程语言抽象（lab 28） |
| Pulumi | 通用语言 + 多云引擎 | 已有语言栈、要复用测试框架 |

## Quick Start

前置条件：LocalStack 运行中；Terraform + tflocal 已安装（`brew install
terraform`、`pip3 install terraform-local`）；首次 init 需下载 provider。

```bash
cd labs/09_terraform_cloudformation
./terraform_cloudformation.sh            # 双栈 apply → 增量 → destroy（约 2 分钟）
./terraform_cloudformation.sh observe    # 只跑增量更新演示
./terraform_cloudformation.sh clean      # 双栈归零
```

脚本的真实输出（节选）：

```text
=====> [observe] [Terraform] 增量更新：env=dev→prod + 队列 delay 0→5，只变 2 处
Plan: 0 to add, 2 to change, 0 to destroy.
  ✅ plan 精确预告 0 add / 2 change
  ✅ 队列 DelaySeconds 增量生效
=====> [observe] [CloudFormation] 更新：DelaySeconds 0→5，栈级等待
  ✅ CFN 更新生效
=====> [clean] [Terraform] destroy → 资源全部消失
  ✅ Terraform 三件已删净
```

Terraform 侧的核心声明（`configs/terraform/main.tf`，tflocal 会自动把 provider
端点注入 LocalStack）：

```hcl
resource "aws_sqs_queue" "jobs" {
  name          = "ho09-tf-jobs"
  delay_seconds = 0   # 增量更新演示：模板演进改为 5，plan 预告 1 处 change
}
variable "env" { type = string, default = "dev" }   # 参数化：apply 时 -var env=prod
```

新手第一个失败点：`tflocal init` 卡住或失败——首次要从 registry.terraform.io
下载 provider（约百 MB），网络不通会一直挂起；确认网络后重跑。

## How It Works

![Terraform 与 CloudFormation](images/terraform_cloudformation.svg)

> 怎么看：两条同样的资源流水——Terraform 用**本地状态文件**对账（plan 是
> "模板 vs 状态"的 diff），CloudFormation 把状态存在**服务端栈**里（事件流水
> 可查）。虚线标出两者最大的差异：状态放哪、由谁对账。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/09_terraform_cloudformation/images/terraform_cloudformation.html)
> （或本地打开 [`images/terraform_cloudformation.html`](images/terraform_cloudformation.html)）。

**Terraform 的增量如何精确**：模板改两处（tags.Env、队列 delay_seconds）后，
`plan` 输出 `Plan: 0 to add, 2 to change, 0 to destroy`——destroy 为 0 是
安全信号。

`apply -auto-approve` 后队列的 DelaySeconds 实测从 0 变 5。

**CloudFormation 的更新流水**：`update-stack` 后用 `wait stack-update-complete`
等待，`describe-stack-events` 给出每一步
（`UPDATE_IN_PROGRESS → UPDATE_COMPLETE`）。

本实验实测队列 DelaySeconds 同步变为 5。

**destroy 的干净退场**：Terraform `destroy` 与 CFN `delete-stack` 都会把资源
全部移除——脚本 clean 后逐一 head-bucket/get-queue-url 验证"确实没了"。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **DynamoDB 资源在 TF 中挂死**：本机构建下 TF 的 DynamoDB（AWS 的 NoSQL 数据库）provider 与
  LocalStack 不兼容（等待 ACTIVE 挂死）。解法：TF 部分选 S3/SQS/SNS 演示，
  DynamoDB 用 CFN 或 CLI。
- **`.tfstate` 丢失 = 资源失联**：state 是 Terraform 对账的唯一依据。解法：
  提交到远端 backend，绝不手工编辑。
- **CFN 更新后不等就查状态**：更新是异步的。解法：`wait stack-update-complete`
  显式等待。
- **CFN 固定 BucketName 删了重建**：同名桶要等旧桶真删干净。解法：等待或改用
  自动命名。

深入问答：

- **Q: plan 显示资源要 replace 怎么办？** A: 先确认能否就地改；必须替换时用
  `create_before_destroy` 生命周期钩子避免服务中断。
- **Q: 什么是漂移（drift）？** A: 有人绕过 IaC 手改了资源，模板与真实不一致。
  Terraform 靠 refresh/plan 发现，CFN 有 drift detection。
- **Q: CFN 的 DeletionPolicy: Retain 干什么用？** A: 删栈时保留该资源（如数据
  桶），防止误删生产数据（lab 26 实测本机未实现该语义，如实记录）。
- **Q: tflocal 做了什么？** A: 启动时给 AWS provider 注入 LocalStack 的
  endpoints 与测试凭证，模板零改动即可对 LocalStack 生效。

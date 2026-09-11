# 09 · 基础设施即代码：Terraform 与 CloudFormation 双栈

> 前八个实验全靠一条条 CLI 命令搭资源——搭得起，**拆不干净、说不清楚、换个人
> 就重搭不出来**。IaC 的答案：资源写成模板，apply 变成可重复的动作，destroy
> 一键归零。本实验用 Terraform（tflocal）和 CloudFormation 各搭同一套
> S3+SQS+SNS，跑通 apply → 增量 → destroy 的完整生命周期。

## 1. 为什么需要它

- **可重复**：模板进 git，任何人在任何 LocalStack 上一条命令复现整套环境；
- **可预览**：apply 前先 plan，改动几处、会不会删除资源一目了然；
- **可回滚**：destroy 干净退场。这是从"玩 AWS"到"工程化用 AWS"的分水岭。

## 2. 总览：核心机制一图看懂

![Terraform 与 CloudFormation](images/terraform_cloudformation.svg)

> 怎么看：两条同样的资源流水——Terraform 用**本地状态文件**对账（plan 是
> "模板 vs 状态"的 diff），CloudFormation 把状态存在**服务端栈**里（事件流水
> 可查）。虚线标出两者最大的差异：状态放哪、由谁对账。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/09_terraform_cloudformation/images/terraform_cloudformation.html)
> （或本地打开 [`images/terraform_cloudformation.html`](images/terraform_cloudformation.html)）。

心智模型一句话：**IaC = 模板声明"要什么"，状态记录"已有什么"，diff 驱动下一步。**

## 3. 快速开始

```bash
cd labs/09_terraform_cloudformation
./terraform_cloudformation.sh            # 双栈 apply → 增量 → destroy（约 2 分钟，首次含 provider 下载）
./terraform_cloudformation.sh observe    # 只跑增量更新演示
./terraform_cloudformation.sh clean      # 双栈归零
```

真实运行输出（节选）：

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

## 4. 核心概念

### 4.1 tflocal：给 Terraform 换总线

Terraform 的 AWS provider 默认打 amazonaws.com；`tflocal`（terraform-local 包）
启动时自动注入 `endpoints = { s3 = ..., sqs = ... }` 和测试凭证，一行不用改模板
就能对 LocalStack 生效。

### 4.2 plan：机器可读的 diff 预告

本实验实测：模板改两处（tags.Env、队列 delay_seconds）后
`Plan: 0 to add, 2 to change, 0 to destroy`——**destroy 计数为 0** 是安全发布的
关键信号。apply 严格按计划执行，队列 DelaySeconds 从 0 变 5 实测生效。

### 4.3 CloudFormation 栈：状态在服务端

`create-stack → wait stack-create-complete → update-stack → wait stack-update-
complete → delete-stack`。更新时无需本地状态——模板传上去，服务端自己 diff，
`describe-stack-events` 给出每一步的变更流水（本实验打印了
UPDATE_IN_PROGRESS → UPDATE_COMPLETE）。

### 4.4 选型速记

| 维度 | Terraform | CloudFormation |
|:---|:---|:---|
| 状态 | 本地/远端文件（自己管） | 服务端栈（托管） |
| 语言 | HCL | YAML/JSON |
| 多云 | 支持 | 仅 AWS |
| 预览 | plan（本地 diff） | change set（lab 26） |

> ⚠️ 实测提醒：**DynamoDB 的 Terraform provider 与本机 LocalStack 不兼容**
> （等待 ACTIVE 挂死），TF 部分选 S3/SQS/SNS 演示——这也是"先探活再开工"的价值。

## 5. 配置关键字段（configs/terraform/main.tf）

```hcl
resource "aws_sqs_queue" "jobs" {
  name          = "ho09-tf-jobs"
  delay_seconds = 0   # 增量更新演示：模板演进改为 5，plan 预告 1 处 change
}
variable "env" { type = string, default = "dev" }   # 参数化：apply 时 -var env=prod
tags = { Env = var.env, Managed = "terraform" }      # 打资源归属标签，对账用
```

坑清单：

- 首次 `tflocal init` 要下载 provider（约百 MB），网络不通会卡在 init；
- TF 的 `.tfstate` 是唯一事实源——别手改、别丢失（生产放远端后端）；
- CFN 的 `wait stack-*-complete` 可能等几十秒，脚本必须显式等待而不是裸 sleep；
- CFN `BucketName` 固定命名时删除重建同名桶要等原桶真删干净。

## 6. 文件结构

```text
labs/09_terraform_cloudformation/
├── README.md                       # 本文件
├── terraform_cloudformation.sh     # 主演示脚本：双栈 apply/增量/destroy
├── configs/
│   ├── terraform/main.tf           # Terraform 声明（S3+SQS+SNS + 变量）
│   └── cloudformation/template.yaml # CFN 同构模板（YAML）
└── images/
    ├── terraform_cloudformation.architecture.json  # 图源（Typed JSON IR）
    ├── terraform_cloudformation.html               # 交互版
    └── terraform_cloudformation.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: Terraform state 的作用？丢了会怎样？** A: state 是"真实世界与模板"的
  对账本；丢了 Terraform 就不认识自己建的资源——只能手工 import 或重建。
- **Q: plan 显示资源要 replace 怎么办？** A: 先问"能不能就地改"；必须 replace 时
  用 create_before_destroy 生命周期钩子避免停机。
- **Q: CFN 的 DeletionPolicy: Retain 干什么用？** A: 删栈时保留该资源（如数据桶）
  不跟着删，防止误删生产数据（lab 26 实战）。
- **Q: drift（漂移）是什么？** A: 有人绕过 IaC 手改了资源，模板与真实不再一致；
  Terraform 靠 refresh/plan 发现，CFN 有 drift detection。
- **Q: 为什么 TF 选 HCL 而不是 YAML？** A: HCL 有表达式/函数/循环（count/for_each），
  模板可组合；YAML 强在 CFN 的服务端校验与生态集成。

## 8. 总结

同一套资源用两种 IaC 各写了一遍：plan 的 diff 预告、栈事件的变更流水、destroy
的干净退场都真机验证过——手工运维时代结束。下一篇收官上半场：把 1-9 的全部
能力串成一条完整的电商订单事件流水线。

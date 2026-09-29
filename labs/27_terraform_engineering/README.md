# 27 · Terraform 工程化：module、workspace 与状态管理

> 在 lab 09 的基础上回答 Terraform（HashiCorp 出品的 IaC 工具）的三个工程化问题：模板怎么复用（module）、
> 多环境怎么隔离（workspace）、状态怎么托管与迁移（state backend）。本实验以
> sqsbucket/snsdemo 两个模块 × dev/stg 两个环境做实，共 7 项真实断言。

## Background

在模块化实践之前，Terraform 的日常用法是"一个 main.tf 打天下"：所有资源堆在
一个文件里，换环境靠复制粘贴整个目录，改一处要同步三份。

复制粘贴模式撞上三堵墙。第一，组合不可复用："队列+桶+通知"这套标准组合每
个环境都要重写一遍。第二，环境边界模糊：dev 与 staging 的资源混在同一个状态
文件里，一次误操作波及所有环境。第三，状态孤岛：state 文件躺在某人的笔记本
上，换台电脑项目就"失联"。

Terraform 的 module（可引用的模板单元）、
workspace（同一配置的隔离状态实例）与 state 管理（pull/push/远端 backend）
分别回应这三堵墙。

## What

一句话定义：module 是可复用的 Terraform 模板单元（有自己的 variable 与
output）；workspace 是同一配置的多份隔离状态（每个环境一个）；state 是记录
"真实世界已有什么"的对账文件。

心智模型：可以把 module 想象成乐高积木块——每个块有自己的插槽（variable）
和凸点（output），根模块负责拼装。但和真实积木不同的是：同一套积木可以在
多个"桌面"（workspace）上各自拼一遍，每个桌面的拼装结果（state）完全独立，
互不可见。

三个机制：

- **module**：`source` 引用子目录，variable 传参，output 上抛结果。
- **workspace**：`workspace new/select` 切换，状态存于 terraform.tfstate.d。
- **state 操作**：`state pull` 导出对账文件（生产中 push 到远端 backend）。

## When to Use

典型场景：

- 标准组合复用：队列+桶+通知的组合在多环境、多项目反复出现。
- 多环境隔离：dev 与 staging 参数不同但结构相同，workspace 一套配置两个
  世界（实测资源名带环境后缀互不干扰）。
- 状态审计与迁移：`state pull` 导出对账文件，迁移到 S3 远端 backend（对象存储 S3 上的托管状态桶）。

何时不用：单一环境且资源少（模块化收益低于成本）；环境差异大到结构都不同
（用目录分层 + tfvars（每环境一份变量文件） 而非 workspace）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| workspace | 同配置多状态实例 | 环境同构、差异只在参数 |
| 目录分层 + tfvars | 每环境独立目录与状态 | 环境差异大、发布节奏不同 |
| Terragrunt | 在 TF 之上加 DRY 包装 | 大规模多环境、重复配置多 |

## Quick Start

前置条件：LocalStack 运行中；Terraform + tflocal（把 Terraform 指向 LocalStack 的包装命令）已安装。运行方式：

```bash
cd labs/27_terraform_engineering
./terraform_engineering.sh            # init → 双环境 apply → 增量 → state → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 同一 module 在两个 workspace 参数不同、资源隔离
  dev: dev ho27-app-bucket-dev
  stg: stg ho27-app-bucket-stg
  ✅ 两环境资源名不同（workspace 隔离生效）
=====> [observe] plan -out 机器可读 + -target 增量变更
  plan 动作统计: {'delete': 3, 'create': 3}
  ✅ -target 重建资源：plan 精确显示 destroy+create
=====> [observe] S3 远端状态迁移（state push；本机构建 state lock 用本地，如实记录）
  ✅ state pull 成功（7592 字节）——生产中 push 到 S3 backend 托管
```

module 的引用方式（`configs/terraform/main.tf`，workspace 名决定环境）：

```hcl
locals { env = terraform.workspace == "default" ? "dev" : terraform.workspace }

module "sqsbucket" {
  source = "./modules/sqsbucket"   # 相对路径模块；生产可用 Git tag/Registry 版本
  name   = "ho27-app"
  env    = local.env
}
```

新手第一个失败点：`workspace select -or-create` 在本机 TF 1.15 报
"Expected a single argument"——用 `new || select` 组合替代；

且 `workspace`
与 `output` 子命令不接受 `-input=false`（脚本的 tfc 包装函数已按子命令区分）。

## How It Works

![Terraform 工程化](images/terraform_engineering.svg)

> 怎么看：根模块通过 source 引用两个子模块；同一 module 在 dev 与 stg
> workspace 各自实例化（资源名带环境后缀，实测 ho27-app-bucket-dev / -stg）；
> plan -out 精确预告 3 destroy + 3 create。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/27_terraform_engineering/images/terraform_engineering.html)
> （或本地打开 [`images/terraform_engineering.html`](images/terraform_engineering.html)）。

**workspace 隔离如何验证**：default（dev）与 stg 两个 workspace 各自 apply
后，output 显示 `ho27-app-bucket-dev` 与 `ho27-app-bucket-stg`——同一模板在
两个世界各自实例化，互不干扰。

**增量变更如何预告**：模板改名（ho27-app→ho27-app2，资源名是不可变属性）后
`plan -out` 显示 `3 destroy + 3 create`——destroy+create 组合就是"重命名 =
替换"的证据，机器可读的 plan 文件交给 apply 精确执行。

**state 的托管姿势**：`state pull` 导出对账 JSON（实测 7.6KB）——生产中把它
push 到 S3 远端 backend（版本化 + 锁）。本机构建的 state lock 用本地文件，
DynamoDB 锁存在兼容问题（如实记录）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **`workspace select -or-create` 报参数错误**：本机 TF 1.15 的 select 不认
  该组合。解法：`new stg || select stg` 两步走。
- **workspace/output 子命令追加 `-input=false` 报错**：该参数只有 apply/
  plan/destroy/refresh 接受。解法：包装函数按子命令区分（脚本 tfc 已处理）。
- **`apply <plan文件>` 报参数过多**：planfile 与 `-input=false` 不能共存。
  解法：apply 时去掉 `-input`。
- **clean 不复位模板导致下轮 no-op**：观察阶段的 sed 改名要复位。解法：
  clean 里 sed 改回原值（脚本已做）。

深入问答：

- **Q: module 的 inputs/outputs 怎么设计？** A: input 只收业务语义参数（名称、
  环境），output 只暴露下游要用的值（ARN/名称）——像设计函数 API。
- **Q: workspace 与目录分层怎么选？** A: workspace 适合同构小环境；环境差异
  大到结构不同或发布节奏不同时，用目录分层 + tfvars。
- **Q: state lock 冲突怎么处理？** A: 确认无并发 apply 后 `force-unlock`；
  根治是远端 backend 的服务端锁。
- **Q: 模块版本化怎么做？** A: source 指向 Git tag/Registry 版本号；升级 =
  改版本引用 + plan 审阅 + apply，和发布软件一样。

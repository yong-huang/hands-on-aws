# 27 · Terraform 工程化：module、workspace 与状态管理

> lab 09 会用 Terraform 建资源；工程化还要回答三个问题：**模板怎么复用**
> （module）、**多环境怎么隔离**（workspace）、**状态怎么托管**（远端 backend）。
> 本实验以 sqsbucket/snsdemo 两个模块 × dev/stg 两个环境做实。

## 1. 为什么需要它

- 复制粘贴三份 main.tf 的日子=改一处忘两处；module 把资源组合封装成可复用单元。
- dev/staging 的差异应该只是"参数不同"，workspace 提供物理隔离的状态文件。
- 状态是 Terraform 的命根子——pull/push 的托管姿势必须熟练。

## 2. 总览：核心机制一图看懂

![Terraform 工程化](images/terraform_engineering.svg)

> 怎么看：根模块通过 source 引用两个子模块；同一 module 在 dev 与 stg workspace
> 各自实例化（资源名带环境后缀，实测 ho27-app-bucket-dev / -stg）；plan -out
> 精确预告 3 destroy + 3 create。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/27_terraform_engineering/images/terraform_engineering.html)
> （或本地打开 [`images/terraform_engineering.html`](images/terraform_engineering.html)）。

心智模型一句话：**module 管"怎么组合"，workspace 管"在哪儿实例化"，state 管"已经有什么"。**

## 3. 快速开始

```bash
cd labs/27_terraform_engineering
./terraform_engineering.sh            # init → 双环境 apply → 增量 → state → 清理
```

真实运行输出（节选）：

```text
=====> [observe] 同一 module 在两个 workspace 参数不同、资源隔离
  dev: dev ho27-app-bucket-dev
  stg: stg ho27-app-bucket-stg
  ✅ 两环境资源名不同（workspace 隔离生效）
=====> [observe] plan -out 机器可读 + -target 增量变更
  plan 动作统计: {'delete': 3, 'create': 3}
  ✅ -target 重建资源：plan 精确显示 destroy+create
=====> [observe] S3 远端状态迁移
  ✅ state pull 成功（7592 字节）
```

## 4. 核心概念

### 4.1 module：可复用的资源组合

`modules/sqsbucket`（S3+SQS）与 `modules/snsdemo`（SNS）各有自己的
variable/output；根模块 `source` 引用并传参。模块产出的值经 output 上抛，供
根模块继续组合。

### 4.2 workspace：同一配置的多份世界

`default` 即 dev，`stg` 通过 `workspace new` 创建。`terraform.workspace` 内插
进资源名（实测两环境资源名不同、互不干扰）。注意：state_cleanup 会删除
`terraform.tfstate.d`（workspace 状态的存放处），所以 clean 后 stg 需重建。

### 4.3 plan -out 与增量

模板改名（ho27-app→ho27-app2）后 `plan -out` 显示 `3 destroy + 3 create`（重命名
= 替换），机器可读的 plan 文件交给 apply 精确执行——杜绝"看走眼"。

### 4.4 状态管理

`state pull` 导出状态 JSON（实测 7.6KB）；生产中配 S3 backend + DynamoDB 锁。
本机构建的 state lock 用本地文件（如实记录），DynamoDB state lock 存在兼容问题。

## 5. 配置关键字段（configs/terraform/main.tf）

```hcl
locals { env = terraform.workspace == "default" ? "dev" : terraform.workspace }

module "sqsbucket" {
  source = "./modules/sqsbucket"      # 相对路径模块；生产用 Git/Registry
  name   = "ho27-app"
  env    = local.env                  # 环境由 workspace 决定
}
```

坑清单：

- `workspace select -or-create` 在本机 TF 1.15 报"Expected a single argument"——
  用 `new || select` 组合替代（脚本已处理）；
- `-input=false` 只有 apply/plan/destroy/refresh 接受，workspace/output 加了会报
  "Expected a single argument"——封装函数按子命令区分（本实验 tfc 已处理）；
- `apply <planfile>` **不能**再带 `-input=false`（尾部附加会报参数过多）；
- clean 里必须复位模板（sed 改回去），否则下轮"增量"变 no-op。

## 6. 文件结构

```text
labs/27_terraform_engineering/
├── README.md                        # 本文件
├── terraform_engineering.sh         # 主脚本：init → 双环境 → 增量 → state → 清理
└── configs/terraform/
    ├── main.tf                          # 根模块：引用子模块、workspace 决定环境
    └── modules/
        ├── sqsbucket/main.tf            # S3+SQS 模块（variable/output）
        └── snsdemo/main.tf              # SNS 模块
```

> 注：图片三件套见 `images/`。

## 7. 面试要点

- **Q: module 的 inputs/outputs 怎么设计？** A: input 只收"业务语义"参数（名称、
  环境），不收实现细节；output 只暴露下游真正要用的值（ARN/名称），像函数 API。
- **Q: workspace 与目录分层的取舍？** A: workspace 适合同构小环境（同一配置
  少量差异）；大差异/不同账号用目录分层 + tfvars；两者都可配远端状态。
- **Q: 为什么重命名资源会 destroy+create？** A: 资源身份（如桶名）进入了真实
  世界的不可变属性；Terraform 只能新建再删旧——用 create_before_destroy 缩窗。
- **Q: state lock 冲突怎么处理？** A: 先确认没有并发 apply，再 `force-unlock`
  指定 LockID；根治办法是把状态放远端 backend 由服务端加锁。
- **Q: 模块版本化怎么做？** A: source 指向 Git tag/Registry 版本号；升级模块 =
  改版本引用 + plan 审阅 + apply，和发布软件一样。

## 8. 总结

模块复用、workspace 隔离、机器可读的 plan、状态的 pull/push——Terraform 从
"能用"升级到"工程化"，命令层的三个本机坑（-input/-or-create/planfile）也全部
排掉。下一篇 AWS CDK：用 Python 代码画同样的栈。

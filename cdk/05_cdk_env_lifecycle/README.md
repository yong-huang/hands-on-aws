# 05 · 多环境参数化与生命周期策略：context 分支 + CfnParameter + Retain

> 一份代码两个环境：context 决定模板形状（队列数、计费模式、版本化、删除
> 策略），`--parameters` 决定部署期取值。prod destroy 后 RETAIN 资产原地
> 存活，dev destroy 一网打尽——生命周期策略的真实分野。

## Background

cdk/02 的构造库用 Props 区分了两个实例，但那是"同一环境的两个副本"。真实
系统的 dev/prod 差异是结构性的：副本数、计费模式、备份、删除保护全不同。
IaC 处理这种差异有两层旋钮，语义完全不同：

- **context（合成期）**：`-c env=prod` 改变合成产物本身——模板形状、资源
  数量、属性值都可以分支。改 context = 可能产生 diff 的部署。
- **CfnParameter（部署期）**：模板带 `Parameters` 段，同一份模板部署时给
  不同的值。形状不变，值可调——适合"每次部署都可能变"的运营参数。

再叠一层 **RemovalPolicy/DeletionPolicy**：数据资产（表、桶）在 prod 设
RETAIN——栈删了，数据还在，但从此脱离栈管理，要人工收尾。这正是"基础设施
可以随时重建，数据不行"的 IaC 表达。

## What

一句话定义：`Ho35Stack` 按环境分支——dev 单队列/PAY_PER_REQUEST/无版本化/
全 DESTROY；prod 三队列扇出+DLQ/PROVISIONED(5,5)/版本化开启/表+桶 RETAIN。
`BatchSize` 是 CfnParameter（部署期 `--parameters` 改值不改形状）。

心智模型：context 是"选图纸"（dev 图纸和 prod 图纸本来就不是一张），
CfnParameter 是"图纸上留空的填写栏"（同一张图，每次施工填不同数），
RETAIN 是"拆楼不拆保险柜"——柜子原地不动，但钥匙得自己管。

## When to Use

典型场景：

- 环境差异是结构性资源差异（副本、计费、备份）→ context 分支。
- 运营可调参数（批大小、超时、开关）每次部署都可能变 → CfnParameter。
- 数据资产的删除保护 → RETAIN；临时环境/可重建资源 → DESTROY（本地开发
  默认，省得手动清残留）。

何时不用：context 塞"每次部署都变"的值（会频繁改模板、diff 噪声大——
那正是 CfnParameter 的活）；CfnParameter 改资源形状（它做不到，形状在
合成期就定了）；RETAIN 给可重建资源（留下一堆无人认领的孤儿资产）。

## Quick Start

前置条件同 cdk/01-34。

```bash
cd cdk/05_cdk_env_lifecycle
./cdk_env_lifecycle.sh      # apply（dev 全生命周期→prod 部署）→ observe → clean
```

observe 阶段 11 条断言全绿即通过：模板形状差异、prod 线上形态（队列数/
可见性/计费/版本化）、CfnParameter 改值、RETAIN 存活与显式清理。

## How It Works

`cdk_app/app.py`（~110 行）核心分支：

| 维度 | dev | prod |
|:---|:---|:---|
| 队列 | 1 个（可见性 15s） | 3 个扇出（可见性 60s）+ 共享 DLQ |
| 表计费 | PAY_PER_REQUEST | PROVISIONED(5,5) |
| 桶版本化 | 关 | 开 |
| 表+桶删除策略 | DESTROY | RETAIN |
| 部署期参数 BatchSize | 默认 10（`--parameters` 可改） | 同左，observe 演示 50→77 |

生命周期验证链（apply+observe 各半）：dev 部署→destroy→断言表/桶/队列
全部消失；prod 部署→destroy→断言表与桶**原地存活**（Retain 探活通过），
队列随栈消失；随后对保留资产显式收尾（版本化桶必须连删除标记一起清，
否则 BucketNotEmpty）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **`-c batch_size=77` 改不动 CfnParameter**：context 和 Parameters 是两个
  体系。解法：部署期赋值走 `cdklocal deploy --parameters BatchSize=77`；
  context 只在 app 里做形状分支。
- **`BillingModeSummary` 在 PROVISIONED 时被省略**：API 只在 PAY_PER_REQUEST
  时返回该字段。解法：查询结果为 None 视同 PROVISIONED（默认值语义）。
- **`list-queues` 空结果的三种长相**：无前缀匹配时 `length(QueueUrls)`
  可能报错（走 `|| echo 0` 兜底）——断言前先在 shell 里实测一次，别猜。
- **空结果字符串 "None" 被当对象键**：`--query ... --output text` 对空集
  输出 "None"，`read` 循环拿着 "None" 去删对象，反而在桶里造出
  `Key="None"` 的删除标记。解法：purge 用 python 显式遍历 Versions +
  DeleteMarkers，不用 shell 文本切分。
- **版本化桶必须先删全部版本+删除标记**：`s3 rb --force` 只删当前对象，
  留下历史版本 → `BucketNotEmpty`。解法：逐 VersionId 删除（本实验
  purge_assets 已内置）。
- **CfnOutput 与 CfnParameter 撞构造 ID**：`CfnParameter(self,"BatchSize")`
  + `CfnOutput(self,"BatchSize")` → `already a Construct with name`。
  解法：输出 ID 换名（cdk/03 同款坑，已成系列）。

深入问答：

- **Q: context 与 CfnParameter 怎么选？** A: 会产生模板 diff 的一律
  context；部署时才定的运营值一律 CfnParameter。检验法：改这个值需要
  "重新合成+审 diff" 还是 "重填参数直接部署"。
- **Q: RETAIN 资产的生命周期归谁？** A: 归人。脱离栈管理后 CFN 不再更新/
  删除它，账单与清理都要显式跟进——本实验的 purge_assets 就是"人工收尾"
  的脚本化替身。
- **Q: 双环境能同时部署吗？** A: 能。物理名带环境前缀（ho05-dev-*/ho05-prod-*）
  互不冲突，栈名同理。本实验为了生命周期断言串行做，命名已支持并行。
- **Q: Retain 与 CloudFormation 的关系？** A: DeletionPolicy 是模板字段，
  L2 用 `removal_policy` 参数表达；L1 用 `cfn_options.deletion_policy`。
  本机探活：两种写法的 destroy 均真实保留（cdk/01 的 PAB 归一化坑在此
  并不存在——Retain 语义被 CFN 引擎如实执行）。

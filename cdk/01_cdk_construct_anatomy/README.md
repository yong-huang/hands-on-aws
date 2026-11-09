# 01 · CDK 构造解剖：L1/L2/L3 三层写法与 escape hatch

> 同一个 S3 桶的三种造法、一张逐项差异对照表、三个 escape hatch（两个线上生效、
> 一个暴露引擎归一化坑）。本实验是 CDK 进阶线（cdk/01-03）的第一块地基。

## Background

labs/28 用 L2 写过四资源一键栈，但"为什么这么写就会多出这些配置"没有拆开看。

CDK 的三层构造模型是一级抽象阶梯：

- **L1（`CfnXxx`）**：与 CFN 模板字段一一对应的"裸资源"。你写什么模板里就是
  什么，没有任何默认值——写漏加密就是没有加密。
- **L2（`s3.Bucket`）**：带安全默认值的资源类。自动注入加密、命名散列、
  粒度更细的方法（`grant_read` 等），代价是"它替你决定了什么"不透明。
- **L3（pattern）**：把"一组资源 + 挂接关系"封装成一个声明，如 `cloudtrail.Trail`
  一个声明合成桶 + 桶策略 + Trail 三个资源。

L2 的默认值不透明在两个地方：一是随版本变（CDK 2.268 已不再注入
PublicAccessBlockConfiguration，交给 AWS 默认全 True）；二是当 L2 没暴露
某个模板字段时（或它注入的默认值不合你意时），需要 **escape hatch**——
`node.default_child` 拿到底层 L1 资源，用 `add_override` 直接改模板字段。

## What

一句话定义：本实验把"同一个桶"分别用 L1/L2/L3 三种写法合成四份模板并逐项
对比，再用三个 escape hatch 改写 L2 默认值，部署后逐项断言线上真实生效。

心智模型：L1 是"自己画施工图"，L2 是"买精装房"（格局定了，软装可换），
L3 是"拎包入住的整栋楼"。escape hatch 是砸墙改管——能改，但墙里有什么
（CFN 规范属性名、引擎归一化行为）你得自己搞清楚。

## When to Use

典型场景：

- 看不懂 L2 给你合成了什么：拿 L1 同资源对照，一眼看清注入了哪些默认值。
- L2 没暴露的冷门字段（如 `AccelerateConfiguration`）：escape hatch 直接改。
- 团队规范要求"所有资源必须显式声明加密"：要么全用 L1，要么用 Aspect 治理
  （cdk/03 的主题）。

何时不用：L1 写业务栈（所有默认值自己扛，极噪）；L3 存在时手写 L2 组合
（重复造轮子）；escape hatch 改 L2 已有高级 API 的字段（应优先用 L2 API）。

## Quick Start

前置条件：LocalStack 运行中；`npm i -g aws-cdk-local aws-cdk` 与
`pip3 install aws-cdk-lib constructs`（同 labs/28）。运行方式：

```bash
cd cdk/01_cdk_construct_anatomy
./cdk_anatomy.sh            # apply（synth+归档+对照表+部署）→ observe（断言）→ clean
```

跑完看 `output/comparison.md`（差异对照表）与 `output/*.template.json`
（四份归档模板）。observe 阶段 11 条断言全绿即通过。

## How It Works

四栈一 App（`cdk_app/app.py`），synth 出四份独立模板：

| 栈 | 写法 | 资源数 | 桶属性数 | 关键差异 |
|:---|:---|---:|---:|:---|
| ho01-l1-stack | L1 `CfnBucket` | 2 | 1 | 只有 BucketName，加密/版本化全没有 |
| ho01-l2-stack | L2 `s3.Bucket` | 2 | 2 | 自动注入 BucketEncryption(AES256)；逻辑 ID 带 8 位散列 |
| ho01-l2x-stack | L2 + 3 个 override | 2 | 4 | 版本化 Enabled + SSE aws:kms + PAB 单字段 False |
| ho01-l3-stack | L3 `cloudtrail.Trail` | 4 | — | 1 个声明 → 桶+桶策略+Trail 三资源 |

三个 escape hatch 的命运（observe 逐条断言，全部本机实测）：

1. **版本化** `VersioningConfiguration.Status=Enabled`：线上
   `get-bucket-versioning` 返回 Enabled ✅。
2. **加密算法** SSEAlgorithm `AES256 → aws:kms`：线上 `get-bucket-encryption`
   返回 aws:kms ✅。注意路径必须是 CFN 规范属性名
   `ServerSideEncryptionByDefault`——SDK 名 `ApplyServerSideEncryptionByDefault`
   不是有效模板键，会合成出重复假键被引擎静默忽略（踩坑实录见下）。
3. **PAB 单字段** `BlockPublicPolicy=False`：模板里确实变 False，但 CFN 引擎
   部署时把部分字段的 PAB 归一化成全 True，线上 `get-public-access-block`
   仍是 True——**模板 ≠ 终态**的活教材（断言按"线上仍为 True"锁定）。

逻辑 ID 规则：L1 的 `RawBucket` 是构造路径直译；L2 的 `Data666C94C7` 带
内容散列——且 L2 与 L2x 逻辑 ID 完全相同，证明散列只看构造路径不看属性。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **override 用了 SDK 属性名不报错但无效**：`ApplyServerSideEncryptionByDefault`
  在 CFN 模板里不存在，`add_override` 静默造出假键。解法：先 synth 一份看
  L2 实际输出的键名，override 瞄准 CFN 规范名。
- **PAB 单字段 override 线上被归一化**：模板 False、线上全 True。原因：
  CFN 引擎对部分字段 PAB 应用默认（全 True）。解法：要么四字段全写，
  要么接受"模板 ≠ 终态"，验收必须落在线上断言而非模板 diff。
- **`auto_delete_objects=True` 会让无 bootstrap 的部署失败**：它生成一个
  带资产的单例 Lambda。解法：LocalStack 无 bootstrap 环境移除该参数，
  桶清空后删除即可（本实验桶均为空）。
- **`BucketDeployment` 在 jsii+typeguard≥4.4 环境崩溃**：
  `InterfaceDynamicProxy has no attribute 'bind'`。解法：L3 示例改用
  `cloudtrail.Trail`（教学目标不变：一个声明合成一组资源）。
- **L3 不部署只 synth**：本机未 bootstrap，含资产的栈（如 BucketDeployment）
  无法部署；Trail 无资产可部署但非验收必需，保持 synth 对比。

深入问答：

- **Q: L2 和 L2x 逻辑 ID 为什么一样？** A: 散列输入是构造路径（stack/构造
  ID），不是属性值。所以改属性不换 ID（原地 update），改构造 ID 才换。
- **Q: escape hatch 会破坏 diff 吗？** A: 不会——override 参与 synth，diff
  如实反映。破坏的是"L2 API 承诺"，升级 CDK 后 L2 默认值变了，override
  行为要自己回归。
- **Q: 为什么 L3 行"桶属性数"是 —？** A: 对照器只统计 AWS::S3::Bucket 的
  Properties；L3 的重点是"1 声明 → 3 资源"的数量级差异，桶本体是 Trail
  自动生成的，没有手写属性。
- **Q: 生产里该选哪层？** A: 默认 L2；组合复用封 L3（cdk/02 亲手造一个）；
  L1 只在 L2 没暴露字段或合规要求显式声明时用，且尽量藏在封装里。

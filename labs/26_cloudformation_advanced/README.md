# 26 · CloudFormation 深化：变更集、嵌套栈与自定义资源

> 在 lab 09 的建栈/删栈之上，补齐 AWS CloudFormation（AWS 托管的 IaC（Infrastructure as Code，把资源写成模板文件管理）服务）的
> 三件生产武器：变更集（先审 diff 再发布）、嵌套栈与跨栈引用（模板组件化）、
> 自定义资源（让 CFN 管理原生资源之外的东西），并验证 DeletionPolicy: Retain
> 对关键资源的保护。

## Background

在变更集与嵌套栈普及之前，CFN 的日常用法是"改模板 → 直接 update-stack"：
改动内容上线后才知道，误删资源无从预警。

直接更新撞上三堵墙。第一，不可预览：一个 Replace 动作（销毁重建）藏在上百行
变更里，上线即事故。第二，模板膨胀：所有资源挤在一个 YAML 里，改一处怕碰坏
别处。

第三，能力边界：CFN 只管 AWS 原生资源，"顺手建一张 DynamoDB 表并回传
ARN"这类逻辑无处安放。

三件武器分别作答：变更集把动作（Add/Modify/Remove）
逐资源列出供人工审阅；嵌套栈把模板拆成可复用组件、用 Export/Import 在栈间
传值；自定义资源把任意逻辑接进 CFN 的创建/更新/删除生命周期。

## What

一句话定义：变更集（change set）是 CFN 的"diff 预览 + 确认执行"机制；嵌套栈
是引用 S3 上子模板的栈内组件。

自定义资源（Custom Resource）是把 Lambda（AWS 的函数计算服务：上传代码、
按事件自动运行）接入 CFN 生命周期的扩展点。

心智模型：可以把变更集想象成代码评审——execute 是 merge，变更集是 PR：改动
逐条列出（哪个资源 Add/Modify/Remove），评审人可以否决（delete change set，
栈毫发无损）。但和真实 PR 不同的是：变更集一旦执行不能撤销，所以"看清楚
Replace 再点确认"是硬纪律。

三个武器：

- **变更集**：`create-change-set → describe（审阅）→ execute`。
- **嵌套栈 + Export/Import**：`AWS::CloudFormation::Stack` 引用 S3 子模板；
  父栈 Output 带 Export 供其它栈 Import。
- **自定义资源**：`AWS::CloudFormation::CustomResource` 绑定 Lambda，CFN 按
  Create/Update/Delete 事件调用它。

## When to Use

典型场景：

- 生产发布：所有对生产栈的改动先走变更集，Replace 动作人工确认。
- 模板组件化：队列+桶+通知这类组合封装成子栈，多个项目复用。
- 补齐原生能力缺口：动态建表并回传 ARN、调用外部系统注册。

何时不用：小实验/一次性资源（直接建栈更快）；变更极简单且可见（直接 update
省一步）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 变更集 | 逐资源 diff 预览 + 确认执行 | 生产栈发布的标准姿势 |
| 直接 update-stack | 一步到位，无预览 | 实验/非关键栈 |
| Terraform plan | 本地状态对账的 diff（lab 09） | Terraform 团队 |
| 嵌套栈 vs 多栈 + Import | 部署原子性 vs 独立生命周期 | 组合复用 vs 松耦合 |

## Quick Start

前置条件：LocalStack（在本机模拟 AWS API 的开源工具，命令发往本地而非真实云）运行中。运行方式：

```bash
cd labs/26_cloudformation_advanced
./cloudformation_advanced.sh            # 建栈 → 变更集/嵌套/CR → Retain → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 嵌套栈与跨栈引用（Fn::ImportValue）验证
  ✅ 嵌套子栈资源（child 桶）存在
  ✅ SNS 主题存在（模板内 !Sub 引用参数）
=====> [observe] 自定义资源：本构建不自动调用 CR Lambda（如实记录）
  ✅ CR 处理器执行成功（SSM 标记: Create@1788743279.0701778）
=====> [observe] 变更集：预览 diff → 执行安全发布
  ✅ 变更集含 1 处变更（预览可见）
  ✅ 变更集执行 → UPDATE_COMPLETE
=====> [clean] DeletionPolicy: Retain 验证 → 删栈
  ⚠️  Retain 未生效（如实记录）
```

变更集的发布三步（脚本核心命令）：

```bash
awslocal cloudformation create-change-set --stack-name "$PARENT" \
  --change-set-name ho26-cs --template-body file:///tmp/v2.yaml
awslocal cloudformation describe-change-set   # 审阅 Changes 列表
awslocal cloudformation execute-change-set --change-set-name ho26-cs
```

新手第一个失败点：模板用了 `!Ref EnvName` 却没声明 Parameter，报
`Unresolved resource dependencies`——Parameter 必须先在模板 Parameters 段
声明（脚本已修）。

## How It Works

![CloudFormation 深化](images/cloudformation_advanced.svg)

> 怎么看：主栈一次编排四类东西——嵌套子栈（TemplateURL 引用 S3 上的模板）、
> 带 DeletionPolicy: Retain 的保护桶、声明 Export 的主题，以及一个 Lambda-backed
> 自定义资源（动态建 DynamoDB（AWS 的 NoSQL 数据库）表）。变更集对主栈做"预览→执行"的安全发布。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/26_cloudformation_advanced/images/cloudformation_advanced.html)
> （或本地打开 [`images/cloudformation_advanced.html`](images/cloudformation_advanced.html)）。

**变更集如何审阅**：create 后 `describe-change-set` 返回 Changes 列表（实测
1 处变更）——确认无危险的 Remove/Replace 后 execute，栈状态变为
UPDATE_COMPLETE。

**自定义资源在本机如何驱动**：本构建不自动调用 CR Lambda（实测如实记录）。
脚本手动 invoke 合成事件，处理器真实建出 DynamoDB 表并将执行证据写入 SSM
标记位（实测断言通过）。

迁移真实 AWS 后该调用由 CFN 自动完成。

**Retain 的语义**：模板对保护桶声明 `DeletionPolicy: Retain`——删栈时桶应
幸存（本构建未实现该语义，实测如实记录；真实 AWS 中桶会留下，需手动清理）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **模板报 Unresolved resource dependencies**：用了 `!Ref` 的参数未在
  Parameters 段声明。解法：补声明（脚本已修）。
- **CR Lambda 收不到事件**：本构建不自动调用自定义资源。解法：合成事件手动
  驱动验证处理器逻辑。
- **CR 响应必须回 ResponseURL**：CFN 靠它判断成功失败，漏发则栈卡
  IN_PROGRESS。解法：respond() 包 try/except 并总是应答。
- **嵌套子栈模板必须放 S3**：TemplateURL 不接受本地路径。解法：先上传子模板
  到桶（脚本 apply 已做）。

深入问答：

- **Q: 变更集与直接 update 的区别？** A: 只差"审阅关口"——Actions 逐资源
  列出，高危 Replace 一眼可见；确认后执行语义相同。
- **Q: 嵌套栈的回滚语义？** A: 子栈是独立栈，父栈回滚连带子栈；Export 被引用
  时删除 Export 方会报错，形成安全依赖约束。
- **Q: 自定义资源如何保证不卡栈？** A: CFN 等待 ResponseURL 回调（带超时），
  成功/失败都要应答一次；物理 ID 稳定否则更新变替换。
- **Q: Retain 与 RetainExceptOnCreate？** A: Retain 永久保留；后者首次创建
  失败也保留。保留资源脱离栈管理，账单与删除需手工跟进。

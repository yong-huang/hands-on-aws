# 26 · CloudFormation 深化：变更集、嵌套栈与自定义资源

> lab 09 会建栈/删栈；生产发布还差三件套：**变更集**（先看 diff 再执行）、**嵌套
> 栈与跨栈引用**（模板复用）、**自定义资源**（让 CFN 管理它原本管不了的东西）。
> 另附 DeletionPolicy: Retain 保护关键资源的验证。

## 1. 为什么需要它

- 直接 update-stack = 蒙眼开车；变更集让你在执行前**逐资源审阅**变更动作。
- 嵌套栈把模板拆成可复用组件；Export/Import 让栈之间安全传递输出值。
- 自定义资源把任意逻辑（建表、开服务、填默认数据）纳入 CFN 生命周期。

## 2. 总览：核心机制一图看懂

![CloudFormation 深化](images/cloudformation_advanced.svg)

> 怎么看：主栈一次编排四类东西——嵌套子栈（TemplateURL 引用 S3 上的模板）、
> 带 DeletionPolicy: Retain 的保护桶、声明 Export 的主题，以及一个 Lambda-backed
> 自定义资源（动态建 DynamoDB 表）。变更集对主栈做"预览→执行"的安全发布。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/26_cloudformation_advanced/images/cloudformation_advanced.html)
> （或本地打开 [`images/cloudformation_advanced.html`](images/cloudformation_advanced.html)）。

心智模型一句话：**变更集是 diff 预览，嵌套栈是模板组件化，自定义资源是生命周期的最后一块拼图。**

## 3. 快速开始

```bash
cd labs/26_cloudformation_advanced
./cloudformation_advanced.sh            # 建栈 → 变更集/嵌套/CR → Retain 验证 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] 自定义资源：本构建不自动调用 CR Lambda（如实记录）
  ✅ CR 处理器执行成功（SSM 标记: Create@1788743279.0701778）
=====> [observe] 变更集：预览 diff → 执行安全发布
  ✅ 变更集含 1 处变更（预览可见）
  ✅ 变更集执行 → UPDATE_COMPLETE
=====> [clean] DeletionPolicy: Retain 验证 → 删栈
  ⚠️  Retain 未生效（如实记录）
```

## 4. 核心概念

### 4.1 变更集三步舞

create-change-set → describe-change-set（审阅 Changes 列表，本实验断言含 1 处
变更）→ execute-change-set。执行后 UPDATE_COMPLETE——**不想要的变更集直接
delete，栈毫发无损**。

### 4.2 嵌套栈与跨栈引用

子栈模板先传 S3（TemplateURL 必须是 URL），父栈以 `AWS::CloudFormation::Stack`
嵌套；父栈 Output 带 `Export: {Name: ...}`，其它栈用 `Fn::ImportValue` 引用——
这是模板组件化的官方通道。

### 4.3 自定义资源与合成事件（本机实录）

本构建**不会自动调用** Lambda-backed custom resource（如实记录）。演示方式：
手工构造与 CFN 完全同构的事件（RequestType/StackId/ResponseURL/ResourceProperties）
invoke 函数——处理器逻辑真实可跑（建表成功），迁移到真实 AWS 即自动触发。
CR 的执行证据用 SSM 标记位断言（比日志可靠）。

### 4.4 DeletionPolicy: Retain 的边界

模板对保护桶声明 Retain。本机实测：删栈后桶**未**保留（LocalStack 未实现该
语义，如实记录）；真实 AWS 中 Retain 桶会在栈删除后幸存，需手动清理。

## 5. 配置关键字段（configs/nested-parent.yaml）

```yaml
Parameters:
  EnvName: { Type: String, Default: dev }   # 未声明参数会导致 Unresolved resource dependencies
Resources:
  ChildQueue:
    Type: AWS::CloudFormation::Stack        # 嵌套栈：TemplateURL 指向 S3 上的子模板
    Properties: { TemplateURL: ..., Parameters: { EnvName: !Ref EnvName } }
  ProtectedBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain                  # 删栈保留桶（本机未实现，如实记录）
Outputs:
  TopicArn: { Value: !Ref SharedTopic, Export: { Name: Ho26TopicArn } }
```

坑清单：

- 模板参数**必须声明**才能 !Ref（本实验踩过 Unresolved resource dependencies）；
- create-stack 时传参是 `ParameterKey=EnvName,ParameterValue=dev` 串格式；
- CR Lambda 的 respond 必须发回 ResponseURL，否则栈卡在 IN_PROGRESS；
- 本构建 CR 不自动触发，用合成事件演示（如实记录）。

## 6. 文件结构

```text
labs/26_cloudformation_advanced/
├── README.md                       # 本文件
├── cloudformation_advanced.sh      # 主脚本：建栈 → 变更集/嵌套/CR → Retain → 清理
├── configs/
│   ├── nested-parent.yaml          # 父栈：嵌套+Export+Retain
│   └── nested-child.yaml           # 子栈模板（部署时上传 S3）
├── functions/custom_resource.py    # CR 处理器（动态建删表 + SSM 标记）
└── images/
    ├── cloudformation_advanced.architecture.json  # 图源（Typed JSON IR）
    ├── cloudformation_advanced.html               # 交互版
    └── cloudformation_advanced.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: 变更集与直接 update 的区别？** A: 只差"审阅关口"——变更集把 Actions
  （Add/Modify/Remove）逐资源列出，高危 Replace 一眼可见；执行语义相同。
- **Q: 嵌套栈的回滚语义？** A: 子栈是独立栈，父栈回滚会连带子栈；跨栈 Export 被
  引用时删除 Export 方会报错，形成安全的依赖约束。
- **Q: 自定义资源如何保证不卡栈？** A: CFN 等待 ResponseURL 的回调（带超时）；
  必须成功/失败各发一次响应，物理 ID 稳定否则更新变替换。
- **Q: Retain 与 RetainExceptOnCreate？** A: Retain 永久保留；后者首次创建失败
  也保留，适合排障期。保留资源脱离栈管理，账单与删除都要手工跟进。
- **Q: 何时选 CFN 而非 Terraform？** A: 纯 AWS + 托管状态 + 团队 YAML 文化选
  CFN；多云/本地状态/丰富表达式选 Terraform（对比表见 lab 09）。

## 8. 总结

变更集的安全发布、嵌套栈的组件化、CR 的生命周期扩展——CFN 的生产级三件套
配齐（CR 自动触发与 Retain 语义在本机的边界如实入档）。下一篇把 Terraform
推进到工程化：模块、workspace 与远端状态。

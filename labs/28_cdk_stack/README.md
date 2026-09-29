# 28 · AWS CDK 实战：用 Python 代码定义云资源

> AWS CDK（Cloud Development Kit）是用通用编程语言定义基础设施的 IaC（Infrastructure as Code，把资源写成代码文件管理）框架
（IaC：把资源写成代码文件来管理）：
> app.py 定义四资源栈（对象存储 S3、消息队列 SQS、函数计算 Lambda、文档数据库 DynamoDB），cdklocal 完成 synth → deploy
> → diff → destroy 四连，全部在 LocalStack 上真实执行，共 6 项断言。

## Background

在 CDK 出现之前，IaC 的两种主流形态是声明式模板：CloudFormation 的 YAML 与
Terraform 的 HCL。

声明式模板撞上两堵墙。第一，缺乏抽象能力：10 个相似的队列要复制 10 段 YAML，
逻辑复用靠复制粘贴。第二，无类型检查：字段拼错、值类型错误要等部署时才暴露。


CDK（AWS，2019 年开源）把思路反转：用编程语言（Python/TypeScript/Java 等）
编写"构造树"，由工具合成（synth）为 CFN 模板——类型检查、循环、抽象全部
回归编程语言的本职。

## What

一句话定义：CDK 是一种用编程语言生成 CFN 模板的 IaC 框架——App/Stack/
Construct 三层构造树经过 synth 合成模板，deploy 交给 CFN 引擎执行。

心智模型：可以把 CDK 想象成"用代码画图纸"的建筑师工具——你用 Python 写下
建筑结构（Construct 树），它自动渲染出施工图（CFN 模板）。但和真实建筑师
不同的是：渲染出的图纸会自动带上大量工程规范（每个资源的安全默认值、命名
散列、依赖排序），而且渲染是确定性的——同一份代码永远画出同一张图。

三层构造树：

- **App**：应用的根，可包含多个 Stack。
- **Stack**：部署单元，对应一个 CFN 栈（本实验的 ho28-stack）。
- **Construct**：资源抽象，L1 是裸 CFN 资源、L2 带默认值与便利方法（本实验
  全部用 L2）。

## When to Use

典型场景：

- 资源组合复用：把"S3+SQS+Lambda+DDB"封装成一个 Construct，多个项目 import。
- 需要逻辑的模板：循环创建 10 个队列、按环境条件分支——编程语言的本职。
- 已有语言栈的团队：TypeScript/Python 工程师零门槛切换。

何时不用：团队 YAML 文化深厚且纯 AWS（CFN 直接写）；多云需求（Terraform，
lab 27）；超大规模存量 CFN 模板（迁移成本高）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CDK | 编程语言 → CFN 模板 | 纯 AWS、偏好编程抽象 |
| CDKTF (cdktf) | CDK 思路生成 Terraform 配置 | 想要 CDK 体验 + Terraform 引擎 |
| Terraform 的 HCL（HashiCorp 配置语言） | 声明式 DSL，状态自持 | 多云（lab 27） |
| CloudFormation YAML | 原生声明式 | 已有 CFN 存量与团队习惯 |

## Quick Start

前置条件：LocalStack（本机模拟 AWS API 的工具）运行中；`npm i -g aws-cdk-local aws-cdk`（CLI）与
`pip3 install aws-cdk-lib constructs`（Python 库）。运行方式：

```bash
cd labs/28_cdk_stack
./cdk_stack.sh            # synth → deploy → 资源验证 → diff → destroy
```

脚本的真实输出（节选）：

```text
=====> [apply] cdklocal deploy：一键部署四资源栈
ho28-stack.EnvName = dev
ho28-stack.Table = ho28-cdk-items
  ✅ CDK 栈（底层 CFN）CREATE_COMPLETE
=====> [observe] 资源真实存在且联动可用
  ✅ CDK 创建的 Lambda Active
=====> [observe] cdklocal diff：部署后再 diff → 无变更（状态对齐）
  ✅ diff 为空（CDK 代码与真实资源对齐）
=====> [clean] cdklocal destroy 一键清栈
  ✅ 已删净，环境复原
```

CDK 应用的核心（`cdk_app/app.py`）——四资源 Construct 与输出：

```python
bucket = s3.Bucket(self, "Data", bucket_name="ho28-cdk-data",
                   removal_policy=cdk.RemovalPolicy.DESTROY)  # destroy 时连数据删
env_name = self.node.try_get_context("env_name") or "dev"     # Context 参数化
cdk.CfnOutput(self, "Bucket", value=bucket.bucket_name)       # 栈输出
```

新手第一个失败点：app.py 报 `No module named 'aws_cdk'`——Python 侧需要
`pip3 install aws-cdk-lib constructs`（CLI 与库是两个安装）。

## How It Works

![AWS CDK 实战](images/cdk_stack.svg)

> 怎么看：app.py 定义 Ho28Stack（四资源 + Outputs）；cdklocal synth 把构造树
> 合成 CFN 模板；deploy 把模板交给 LocalStack 的 CFN（底层与 lab 09/26 同一
> 条通路）；destroy 一键清栈。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/28_cdk_stack/images/cdk_stack.html)
> （或本地打开 [`images/cdk_stack.html`](images/cdk_stack.html)）。

**synth 如何工作**：`cdklocal synth` 执行 app.py，把构造树序列化为 CFN JSON
——实测合成模板含 S3/SQS/Lambda/DynamoDB 四类资源。CDK 的真正产物就是 CFN
模板，lab 09/26 的 CFN 知识全部适用。

**diff 如何对账**：deploy 后再跑 `cdklocal diff`，实测为空——说明"代码 = 
真实世界"。改一行代码再 diff，会精确显示哪个资源的哪个属性变化。

**destroy 与 Context**：`cdklocal destroy --force` 清栈；资源声明
`RemovalPolicy.DESTROY` 后连数据一起删。

`try_get_context("env_name")` 从
cdk.json/命令行读参数——多环境部署同一份代码（实测输出 EnvName=dev）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **Python 侧报 No module named aws_cdk**：只装了 CLI 没装库。解法：`pip3
  install aws-cdk-lib constructs`。
- **含资产的栈 deploy 报"uses assets"**：栈引用本地文件（如 Lambda 代码目录）
  时需要先 `cdklocal bootstrap` 建 CDKToolkit 栈与资产桶（lab 30 实测）。
- **逻辑 ID 改名 = 销毁重建**：Construct 的 ID 决定 CFN 逻辑 ID，改名视为
  资源替换。
- **bucket_name 固定的桶删了重建**：要等旧桶真删干净。解法：等待或改用自动
  命名。

深入问答：

- **Q: L1/L2/L3 Construct 的区别？** A: L1 是裸 CFN 资源（CfnBucket）；L2 带
  默认值与便利方法（Bucket）；L3 是模式封装（桶+队列+通知一键）。优先 L2。
- **Q: CDK 如何防止资源丢失？** A: 逻辑 ID 由构造路径散列生成，改名视为替换；
  已有资源可用 cdk migrate/import 收编。
- **Q: CDK 与 Terraform 怎么选？** A: 团队强类型语言文化 + 纯 AWS 选 CDK；
  多云、状态透明、生态成熟选 Terraform——两者能表达同样架构。
- **Q: Aspect 是什么？** A: 遍历构造树统一打标/加策略的机制（如全资源加
  tags）——"策略即代码"的挂点。

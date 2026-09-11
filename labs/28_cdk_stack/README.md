# 28 · AWS CDK 实战：用 Python 代码定义云资源

> CloudFormation 写 YAML、Terraform 写 HCL，而 CDK 让你**用真正的编程语言**定义
> 基础设施：类型检查、循环抽象、IDE 补全。cdklocal 把 CDK 的合成产物（CFN 模板）
> 指向 LocalStack——synth → diff → deploy → destroy 四连完成。

## 1. 为什么需要它

- 基础设施代码化到极致：一个 Construct 类封装"S3+SQS+Lambda+DDB"，复用如函数。
- diff 是"代码 vs 真实世界"的对账：部署后再 diff，为空说明状态对齐（本实验实测）。
- 与 lab 09 对比：CFN 是声明式 YAML，CDK 是命令式语言生成声明式模板——两全其美。

## 2. 总览：核心机制一图看懂

![AWS CDK 实战](images/cdk_stack.svg)

> 怎么看：app.py 定义 Ho28Stack（四资源 + Outputs）；cdklocal synth 把构造树合成
> CFN 模板；deploy 把模板交给 LocalStack 的 CFN（底层与 lab 09/26 同一条通路）；
> destroy 一键清栈。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/28_cdk_stack/images/cdk_stack.html)
> （或本地打开 [`images/cdk_stack.html`](images/cdk_stack.html)）。

心智模型一句话：**CDK 用代码"画"出模板，剩下的交给熟悉的 CFN 引擎。**

## 3. 快速开始

```bash
cd labs/28_cdk_stack
./cdk_stack.sh            # synth → deploy → 资源验证 → diff → destroy
# 手动体验：
cd cdk_app
cdklocal synth            # 输出合成模板
cdklocal deploy --require-approval never
cdklocal destroy --force
```

真实运行输出（节选）：

```text
=====> [apply] cdklocal deploy：一键部署四资源栈
ho28-stack.EnvName = dev
ho28-stack.Table = ho28-cdk-items
  ✅ CDK 栈（底层 CFN）CREATE_COMPLETE
=====> [observe] 资源真实存在且联动可用
  ✅ CDK 创建的 Lambda Active
=====> [observe] cdklocal diff：部署后再 diff → 无变更
  ✅ diff 为空（CDK 代码与真实资源对齐）
=====> [clean] cdklocal destroy 一键清栈
  ✅ 已删净，环境复原
```

## 4. 核心概念

### 4.1 App → Stack → Construct 三层构造树

app.py 定义 App，Stack 里声明 Bucket/Queue/Table/Function 四个 L2 Construct（带
合理默认值的高级抽象）。`removal_policy=DESTROY` 让 destroy 时连数据一起删。

### 4.2 synth：构造树 → 模板

`cdklocal synth` 执行 app.py，把对象树序列化为 CFN JSON。**CDK 的真正产物是
CFN 模板**——所以 lab 09/26 学的 CFN 知识全部适用。

### 4.3 diff：代码与世界的对账

部署后 diff 为空 = 代码即真实（实测）。改一行代码再 diff，会精确显示哪个资源
哪个属性变化——Terraform plan 的 CDN 版。

### 4.4 Context 与参数化

`node.try_get_context("env_name")` 从 cdk.json/命令行读取配置（本实验输出
EnvName=dev），实现多环境部署同一份代码。

## 5. 代码关键字段（cdk_app/app.py）

```python
bucket = s3.Bucket(self, "Data", bucket_name="ho28-cdk-data",
                   removal_policy=cdk.RemovalPolicy.DESTROY)   # destroy 时连数据删
fn = _lambda.Function(self, "Fn", runtime=..., handler="index.handler",
                      code=_lambda.InlineCode("..."))          # 演示用内联代码
cdk.CfnOutput(self, "Bucket", value=bucket.bucket_name)        # 输出 = 栈的返回值
Ho28Stack(app, "ho28-stack", env=cdk.Environment(account="000000000000", region="us-east-1"))
```

坑清单：

- 需要 `pip install aws-cdk-lib constructs`（app.py 的 Python 依赖）与
  `npm i -g aws-cdk-local aws-cdk`（CLI）；
- CDK v2 的构造 ID 决定逻辑 ID，改名 = 销毁重建；
- `bucket_name` 固定命名时销毁重建要等真删干净；
- cdklocal 与 cdk 参数一致，只是底层端点不同。

## 6. 文件结构

```text
labs/28_cdk_stack/
├── README.md            # 本文件
├── cdk_stack.sh         # 主脚本：synth → deploy → 验证 → diff → destroy
├── cdk_app/
│   ├── app.py           # CDK 应用（四资源栈 + Context 参数化）
│   └── cdk.json         # CDK 配置（app 入口）
└── images/
    ├── cdk_stack.architecture.json  # 图源（Typed JSON IR）
    ├── cdk_stack.html               # 交互版
    └── cdk_stack.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: CDK 的 L1/L2/L3 Construct？** A: L1 是裸 CFN 资源（CfnBucket）；L2 带默认
  值与便利方法（Bucket）；L3 是模式封装（Bucket + 队列 + 通知一键）。优先 L2。
- **Q: CDK 如何保证资源不丢失？** A: 逻辑 ID 由构造路径散列生成，重命名=销毁
  重建；`cdk migrate`/import 可收编已有资源。
- **Q: CDK 与 Terraform 选型？** A: 团队强类型语言文化 + 纯 AWS 选 CDK；多云、
  状态透明、生态成熟选 Terraform。两者都能表达同样架构。
- **Q: aspect 和 stack synthesis 是什么？** A: Aspect 遍历构造树统一打标/加策略
  （如全部资源加 tags）；synthesis 把树合成模板——策略即代码的挂点。
- **Q: 本地开发 CDK 如何连 LocalStack？** A: aws-cdk-local 包装 CLI 注入端点，
  或者 cdktf/localstack provider；行为差异与 lab 26 的 CFN 边界一致。

## 8. 总结

用 Python 画出四资源栈、一键部署、diff 对账、一键销毁——CDK 把"基础设施即代码"
推进到"基础设施即软件"。下一篇 SAM：无服务器应用的专用脚手架。

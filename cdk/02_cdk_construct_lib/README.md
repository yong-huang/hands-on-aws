# 02 · 自定义可复用 Construct 库：OrderPipeline 一份代码两个实例

> 把 S3 + SQS(+DLQ) + Lambda + DynamoDB 封装成一个带入参校验、默认值、命名
> 隔离的 Construct，在两个 Stack 里各实例化一份并端到端冒烟。cdk/01 教了
> "看懂构造"，本实验开始"亲手造构造"。

## Background

labs/28 的四资源栈是"一次性代码"：想再造一条同样管道，只能复制粘贴改名字。
复制粘贴式 IaC 的三个老问题——改一处漏一处、命名冲突靠人肉、没有入参校验
（部署到一半才炸）——正是 Construct 抽象要解决的。

Construct 的设计要点有四条，全部是 L2 类库作者视角：

1. **入参校验前置**：非法值在 synth 期就抛出带原因的错误，比部署期失败
   便宜一个数量级。
2. **默认值可覆盖**：加密、DLQ、可见性超时给出合理默认，同时留覆盖口子。
3. **命名空间隔离**：所有物理名带调用方传入的前缀，多实例互不冲突。
4. **内部封装**：队列→Lambda→表的事件源映射、最小权限授予都在构造内部
   接好，调用方只拿资源引用。

## What

一句话定义：`OrderPipelineConstruct` 是一个"一条订单处理管道"的自定义
构造——调用方传一个 `pipeline_name`（如 alpha），就得到一整套命名隔离、
默认值齐全、端到端可用的 S3+SQS(+DLQ)+Lambda+DDB 管道。

心智模型：你在写一个"小型 L2 类库"——和 `s3.Bucket` 作者的工作完全一样：
设计 Props、写校验、定默认值、接内部关系、暴露只读属性。唯一区别是
`s3.Bucket` 服务于全球，你的服务于本团队。

## When to Use

典型场景：

- 同类基础设施出现第 2 份拷贝时（规则：第三次复制前必须抽象）。
- 团队内统一"标准管道"：安全默认值（加密、DLQ、超时）收口在构造里，
  调用方想关都关不掉——这是平台工程的雏形。
- 合成期护栏：不合法的入参在 `cdk synth` 就报错，进不了 CI 后半段。

何时不用：只用一次的资源组合（直接写在 Stack 里更直白）；还在频繁探索
的阶段（抽象太早会把接口锁死）；跨团队发布（那是 CDK construct library
打包 + 发布流程，超出本实验范围）。

## Quick Start

前置条件同 cdk/01（cdklocal + aws-cdk-lib 2.x + LocalStack 运行中）。

```bash
cd cdk/02_cdk_construct_lib
./cdk_construct_lib.sh            # apply（校验演示+部署）→ observe（隔离+冒烟）→ clean
```

observe 阶段 14 条断言全绿即通过：8 项资源存在性（2 桶/2 队列/2 表/2 函数）、
2 项默认值覆盖验证、2 项端到端落表、外加 apply 期的合成期校验演示。

## How It Works

核心代码 `cdk_app/order_pipeline.py`（~180 行）：

- `OrderPipelineProps`（dataclass）：`pipeline_name` 必填且过正则
  `^[a-z][a-z0-9-]{2,19}$`，`max_receive_count` 限 1-50；`validate()`
  在构造函数第一行调用。
- `OrderPipelineConstruct`：桶（S3_MANAGED）、表（order_id 主键）、DLQ
  （保留 7 天）、主队列（挂 DLQ）、Lambda（InlineCode + boto3 落表）。
  内部 `add_event_source(SqsEventSource(queue))` + `grant_read_write_data`。
- 两个调用方 Stack：alpha 全默认；beta 覆盖可见性超时 60s、DLQ 阈值 5——
  observe 阶段用 `get-queue-attributes` 断言两队列属性真的不同。
- 合成产物：每栈 9 个资源（含 Role/Policy/EventSourceMapping 这些"内部
  挂接"的具象化），2 实例 = 18 资源且物理名零冲突。

端到端冒烟链路：`sqs send-message {"order_id":"A-001"}` → 事件源映射触发
Lambda → boto3 按 TABLE_NAME 环境变量落表 → `dynamodb scan` 断言 Count=1。
alpha/beta 各走一遍，证明隔离的是"整套管道"而不只是名字。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **`lambda.Function` 没有 `removal_policy` 参数**：报
  `unexpected keyword argument`。Lambda 默认随栈删除，无需显式设置；
  S3/DDB/SQS 的 L2 才暴露该参数。
- **bash 消息里 `$oid（` 变 unbound variable**：多字节字符紧跟 `$var` 时
  bash 可能把无效字节并入变量名。解法：一律 `${var}` 定界。
- **事件源映射不是即时的**：deploy 成功 ≠ 映射已 Enabled。解法：冒烟前
  `sleep 3` 缓冲 + 落表断言自带 15×2s 轮询。
- **InlineCode 大小上限 4096 字符**：构造库里的函数代码超限就要走资产
  （`Code.from_asset`），而资产需要 bootstrap（cdk/01 坑）。解法：保持
  内联精简，或本地起 bootstrap。

深入问答：

- **Q: 为什么 `validate()` 放构造函数第一行而不是 `__post_init__`？**
  A: 都行；放构造函数里能拿到 cid 上下文报更友好的错，且强制"没经过校验
  的构造不存在"。
- **Q: Props 用 dataclass 还是 jsii.data_type？** A: 纯 Python 自用构造
  dataclass 足够；`@jsii.data_type` 是给要发布成 jsii 包（供 TS/Java 调）
  的构造库用的，本实验不发布。
- **Q: `export_value` 为什么导出队列 ARN？** A: 为 cdk/04 跨栈引用铺路——
  导出后其他 Stack 可 `ImportValue`。实例内部挂接不需要它，显式导出是
  库作者对未来调用方的承诺。
- **Q: 构造库怎么测？** A: 本实验用"部署 + 冒烟"测；cdk/04 会补上
  `aws_cdk.assertions` 的合成期断言测试，两层合起来才是完整测试策略。

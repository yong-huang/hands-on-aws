# 07 · fine-grained 断言测试：给 IaC 代码上一道合成期质检

> 用 `aws_cdk.assertions` 对 cdk/02 构造库写 12 条精细断言（资源形态/数量/
> 反面/导出），再用两种注入证明断言真能抓红：去掉桶加密、改错 Lambda
> runtime，各被至少 1 条测试精确命中。纯合成期验证，不依赖 LocalStack。

## Background

cdk/02 验证构造库靠"部署 + 冒烟"——那条路慢（分钟级）、贵（要起 LocalStack）、
且发现问题时资源已经建出来了。测试金字塔在 IaC 世界同样成立：部署冒烟是
"端到端"，而**合成期断言**是"单元测试"——对 synth 产物（模板 JSON）断言，
秒级、零依赖、错误配置进不了部署。

IaC 的 bug 有个特点：不报错，只是"悄悄不对"（桶没加密、runtime 错了但
代码看起来能跑）。断言测试就是把这些"不报错的不对"钉死在 CI 里。

## What

一句话定义：`Template.from_stack(...)` 把栈合成成模板，`has_resource_properties`
断言某资源带某属性、`resource_count_is` 断言数量、反面断言（count=0 +
`Match.absent()`）断言"不该存在的配置不存在"——再靠注入开关证明红得其所。

心智模型：断言是"图纸审校"——房子（模板）画完先审图纸，承重墙不能拆
（加密）、房间数要对（资源数量）、图纸上不该出现的.privacy（通配授权）
不许有。审图不过，不许开工（不进 CI 后半段）。

## When to Use

典型场景：

- 构造库/平台的"能力回归"：升级 aws-cdk-lib 后跑一遍，默认值漂移立刻现形
  （cdk/01 实测过：CDK 2.268 已不再注入 PublicAccessBlock——这类变化
  断言测试第一时间抓住）。
- 合规底线进 CI：加密、DLQ 挂接、事件源映射，缺一个合成期就红。
- 反面断言防"回归式修复"：有人"顺手"去掉加密？`count=0` 断言当场拦下。

何时不用：验证线上行为（断言只看模板不看运行时，冒烟仍是必经）；验证
CLI 部署流程本身（那是 cdk/09 的部署机制解剖）。

## Quick Start

无需 LocalStack（纯合成）：

```bash
cd cdk/07_cdk_assertions
./cdk_assertions.sh     # green 全绿 → 两种注入各抓红一次
```

验收对表：green 12 passed（exit 0）；`HO37_BREAK=no_encryption` 抓红
`test_bucket_encrypted_by_default`（exit≠0）；`HO37_BREAK=bad_runtime`
抓红 `test_lambda_runtime_python312`（exit≠0）。

## How It Works

`cdk_app/`（pytest，~160 行测试代码）：

- **lib/order_pipeline.py**：cdk/02 构造库原样复用，仅加 `inject`
  测试开关（`no_encryption` 不带加密分支、`bad_runtime` 换 NODEJS_20_X）
  ——注入走的是真实构造路径，不是另写一个假栈。
- **green 套件 12 条**：桶加密（含 AES256 算法逐层 Match）、队列
  VisibilityTimeout 30 + RedrivePolicy(maxReceiveCount=3)、DLQ 队列名、
  表分区键、Lambda runtime/handler/TABLE_NAME 环境变量、事件源映射、
  资源计数（2 队列/1 桶/1 表/1 函数/1 映射）、反面断言"无无加密桶"、
  ExportsOutput 导出存在、全部队列 DeletionPolicy=Delete。
- **red 套件**：`HO37_BREAK` 选注入模式，skipif 只跑对应断言——每一轮
  恰好 1 failed + 1 skipped，失败信息含模板实际值，方便定位。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **断言 `BatchSize: 10` 失败**："Template has 1 resources ... none match"。
  默认值不进模板——CDK 省略等于默认的字段。解法：断言只写会出现在模板
  里的字段；"默认值缺席"本身用 `Match.absent()` 正面表达。
- **`find_outputs()` 必须给 logical_id**：无参调用是 TypeError。解法：
  `to_json().get("Outputs")` 自行遍历（还要注意导出名是自动生成的
  `ExportsOutputFnGetAtt...`，不能猜名字）。
- **runtime 枚举名是 `NODEJS_20_X`**：想当然写 `NODE_JS_20_X` 直接
  AttributeError——注入配置也要拼写正确才能"错得有意义"。
- **`pytest ... | tail` 吞退出码**：管道后 `$?` 是 tail 的。解法：重定向
  到文件再看退出码（cdk/06 同款教训，已成纪律）。

深入问答：

- **Q: assertions 与 cdk/03 Aspect 治理什么关系？** A: 都是合成期护栏。
  Aspect 深入构造树能改能查、随每次 synth 自动跑（组织级强制）；assertions
  只读模板、随 pytest 跑（仓库级质量门）。治理保证"不能写出违规"，测试
  保证"违规写出来也进不了主干"。
- **Q: `has_resource_properties` 是"存在一个匹配"还是"全部匹配"？**
  A: 存在即可（≥1）。要"全部"用 `resource_properties_count_is` 配精确
  计数；要"不存在"用计数 0。
- **Q: 为什么不给 Template 上 type hints fixture 也没事？** A: module 级
  fixture 合成一次复用，12 条断言 1.4 秒跑完——对比 cdk/02 的部署冒烟
  （分钟级），这就是测试金字塔给 IaC 的第一层红利。
- **Q: Match 家族怎么选？** A: 精确值直接写；`object_like` 子集匹配；
  `any_value` 占位（"有但内容不关心"）；`absent` 反面；`array_with`
  数组包含。嵌套组合即可表达绝大多数模板断言。

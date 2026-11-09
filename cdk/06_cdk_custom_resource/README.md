# 06 · Custom Resource：把任意动作接进部署生命周期

> Lambda-backed CR 三连：Create 播种 3 条、属性变更 Update 刷新为 4 条
> （物理 ID 稳定不 Replace）、destroy 时 Delete 清理零孤儿。labs/26 在
> CFN 层验证过回调协议，本实验把它装进 CDK 的 L2 `CustomResource`。

## Background

CFN 只认识"模板里声明的资源"。但部署生命周期里常有模板表达不了的动作：
往表里灌种子数据、触发一次外部注册、迁移历史配置。硬编码在脚本里做，
就成了部署之外的"影子步骤"——别人 apply 完你的栈，种子数据并没有。

Custom Resource 是官方逃生舱：部署时 CFN 向你指定的 Lambda 发
Create/Update/Delete 事件，Lambda 干完活必须签名回 POST 到 ResponseURL，
CFN 才算这个资源创建成功。它把任意代码变成一等公民资源——有 diff、有
回滚、有删除语义，同时引入新责任：**必须响应、物理 ID 必须想清楚**。

## What

一句话定义：`CustomResource` L2 指向一个内联 Lambda；CR 属性 `Seeds`
（JSON 数组）变化时触发对应事件——Create/Update 全量重写 `ho06-seeds` 表
的种子数据，Delete 清空。`PhysicalResourceId` 恒为 `ho06-seeds-v1`：
ID 稳定 → 属性变化走 Update（原地刷新）；ID 变了会触发 Replace（先删后建，
数据全损）。

心智模型：CR 是"随队工匠"——每阶段（建/改/拆）工程队都喊他到场，他做完
要签字回执（ResponseURL）。队伍只认签字不认人；他换工牌（物理 ID）就会被
当成新工匠先辞旧再雇新。

## When to Use

典型场景：

- 部署期数据初始化：种子数据、默认配置、一次性迁移。
- 与 IaC 生命周期强绑定的外部动作：注册 webhooks、预热缓存。
- 属性驱动的刷新：改 CR 属性 = 触发对应动作（本实验种子数 3→4）。

何时不用：运行期常态业务（CR 只在部署时跑，不是定时器/服务）；能被
普通资源表达的东西（DDB 表建表本身）；频繁变化的参数（每次变都触发
CR 全量重跑）。

## Quick Start

前置条件同 cdk/01-35。

```bash
cd cdk/06_cdk_custom_resource
./cdk_custom_resource.sh     # apply（播种断言）→ observe（Update+Delete 断言）→ clean
```

observe 阶段 9 条断言全绿即通过：Update 后 4 条种子 + 新种子内容 +
物理 ID 稳定、destroy 后栈/表/CR Lambda 零孤儿。

## How It Works

`cdk_app/app.py`（~150 行）：

- **CR Lambda**（内联代码）：`rewrite()` 全量重写——先 scan 出全部旧种子
  逐条删除，再按属性写入新种子（单条操作，原因见踩坑第 2 条）。
  响应体带 `Status/PhysicalResourceId/RequestId`，标准库 urllib PUT 回
  ResponseURL（labs/26 验证过的协议：不回执 = 栈卡 IN_PROGRESS）。
- **CDK L2**：`CustomResource(service_token=fn.function_arn, properties=...)`
  合成 `Custom::Ho36Seeder`，通过 Ref 隐式依赖 CR Lambda。
- **物理 ID 策略**：CR Lambda 自己返回恒定 `"ho06-seeds-v1"`——本实验
  observe 断言了 Update 后 PhysicalResourceId 不变（= 走 Update 分支）。
- **属性驱动**：`-c extra=1` 改变 `Properties.Seeds`（3→4 条）→ CFN 发
  Update 事件 → 表内多出 A-004。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **CR Lambda 崩溃 = 栈永久卡死**：Update 事件里 handler 抛异常没回执，
  CFN 无限等（LocalStack 每 ~23s 轮询一次结果键，30 分钟不停）。解法：
  handler 全程 try/except 并保证失败时也回 `Status: FAILED`；本机可用
  `aws logs filter-log-events --log-group-name /aws/lambda/<fn>` 第一时间
  看到崩溃栈。卡死栈无法响应时只能重启 LocalStack 清状态（状态在内存，
  不挂 volume）。
- **batch_writer 里 delete+put 同一键被拒**：
  `Provided list of item keys contains duplicates`——同一 BatchWriteItem
  批次里同键的 delete 和 put 算重复（真实 AWS 同规）。解法：删与写分开
  两轮，或干脆单条调用（种子量级小，单条更直白）。
- **`batch_writer.delete_item(sk=...)` TypeError**：boto3 的 batch 删除
  要 `Key={...}` 字典，不是平铺 kwargs。
- **管道吞退出码**：`./x.sh all 2>&1 | tail -24` 的退出码是 tail 的 0，
  脚本失败被掩盖。解法：跑验收一律重定向到文件再看 `$?`，不接管道。

深入问答：

- **Q: 物理 ID 什么时候该变？** A: 资源"换本体"才换——比如按环境生成
  不同 ID 想强制重建。种子数据这种"同一份、内容可变"的，ID 必须恒定，
  让属性变化落进 Update。
- **Q: Update 全量重写 vs 增量？** A: 全量重写让表状态 = CR 属性（声明式
  语义，diff 可预期）；增量逻辑（只补缺的）会让真实状态漂移出属性表达，
  两次部署间手工改动永远不会被纠正。
- **Q: 为什么不用 `AwsCustomResource`（SDK 调用型 CR）？** A: 它基于
  Provider 框架，框架 Lambda 是大段内联代码，本机曾出现 jsii/资产类
  兼容性问题；手写 CR Lambda 逻辑透明、labs/26 已验证协议。Provider 框架
  （onEvent/isComplete）留给需要异步完成的场景。
- **Q: CR 的 Data 输出能被别的资源引用吗？** A: 能——`Fn::GetAtt` 取
  响应 Data 字段（本实验返回了 seed_count）。这让 CR 可以"算出"一些
  部署期才能确定的值供栈内消费。

# 03 · SQS 队列 + SNS 发布订阅：队列、扇出与死信

> SQS（Simple Queue Service，托管消息队列）与 SNS（Simple Notification Service，
> 托管发布订阅主题）是 AWS 消息通信的两块基石。本实验在本机跑通消息闭环、可见
> 性超时、毒丸消息（每次消费都失败的消息）入死信队列、FIFO（First-In-First-Out，
> 先进先出）去重与 SNS 过滤扇出（一次发布复制给多个订阅方），共 12 项真实断言。

## Background

在消息中间件普及之前，服务之间的协作靠**直接调用**：下单 API 处理完库存后，
同步调用发货服务、通知服务、审计服务。

直接调用撞上两堵墙。第一，高峰期下游处理慢，上游被拖死，一个服务故障会顺着
调用链传播成雪崩。第二，新增一个"订单事件"的下游（比如审计），就得修改并重新
发布上游代码。消息队列的思路是让上游把工作"投递"出去就返回：SQS 让一件事
一个人异步做（点对点），SNS 让一件事同时广播给多个订阅方（发布/订阅）。

## What

一句话定义：SQS 是一种托管消息队列，生产者发送、消费者拉取，一条消息由一个
消费者处理；SNS 是一种托管发布订阅主题，一条消息按订阅关系复制给多个订阅者。

心智模型：可以把 SQS 想象成餐厅后厨的待办单——厨师（消费者）取一张单、做完
划掉；做砸了没划掉，单子过一会儿会回到取单口再被人取走。但和真实待办单不同的
是：它是"至少一次"投递，同一张单可能被取两次，所以消费者必须能识别重复。

可以把 SNS 想象成报刊订阅：发布者只管登报，谁订了哪份、要不要附过滤条件，
都是订阅侧的事。但和真实报刊不同的是：它能在投递前按条件裁剪内容（过滤
策略），且同一期可能被重复投递。

## When to Use

典型场景：

- 削峰解耦：下单高峰把订单丢进队列立即返回，发货服务按自己的节奏消费。
- 可靠异步：发邮件、转码等"失败不能丢"的任务，失败消息进死信队列（DLQ，dead
  letter queue，存放反复消费失败消息的队列）等待人工处理。
- 一事件多下游：订单事件同时给通知服务与审计服务，用 SNS 一次发布、各自订阅，
  并用过滤策略（Filter Policy，按消息属性筛选投递的订阅级规则）让下游只收
  自己关心的。

何时不用：请求方需要立刻拿到处理结果（同步语义）时，队列只会增加复杂度，直接
调用更简单；纯内存的低延迟调用也不该绕道消息服务。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| SQS 标准队列 | 至少一次、不保序、近乎无限吞吐 | 削峰、异步任务默认选择 |
| SQS FIFO 队列 | 同组严格有序、去重，吞吐受限 | 要求顺序的业务（下单、账务） |
| SNS | 扇出广播、过滤订阅 | 一事件多下游、移动端推送 |
| Kafka (MSK) | 持久日志、回放、消费组 | 流式管道、需要重放历史 |

## Quick Start

前置条件：LocalStack 运行中；aws CLI 可用。运行方式：

```bash
cd labs/03_sqs_sns_messaging
./sqs_sns_messaging.sh            # apply → observe → clean（约 50 秒，含重试等待）
./sqs_sns_messaging.sh observe    # 只看演示：闭环/可见性/毒丸/FIFO/扇出
./sqs_sns_messaging.sh clean      # 删除全部队列与主题
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] Visibility Timeout：收到不删 → 5s 内对别人不可见 → 6s 后重新可见
  ✅ 消费中(未删): InFlight=1, Visible=0
  ✅ 超时未删: 消息重新可见（别的消费者能再收到）
=====> [observe] 毒丸消息：消费即失败，连续失败 3 次后转入 DLQ
  ✅ 毒丸已入 DLQ（maxReceiveCount=3，约 8 秒完成转移）
=====> [observe] SNS 扇出与过滤：普通消息 2 个订阅都收，color=red 只有 q-red 收
  ✅ q-all 收到普通消息
  ✅ q-red 不收普通消息（过滤生效）
```

两个订阅队列的过滤策略来自声明式配置 `configs/filter-policy-red.json`：

```jsonc
{
  "color": [ "red" ]          // 只有带 color=red 属性的消息投递给该订阅
}
```

新手第一个失败点：给 SNS 订阅传 `--attributes` 时，FilterPolicy 的值本身是
JSON 字符串，CLI 简写解析不了嵌套引号——需要用 `json.dumps({"FilterPolicy":
...})` 整体构造（脚本已处理）。

## How It Works

![SQS 与 SNS 消息](images/sqs_sns_messaging.svg)

> 怎么看：左侧实线是 SQS 点对点主路径——消费者"收到→处理→删除"，不删除就会
> 在可见性超时后重现（重试的来源）；失败次数超限被移入 DLQ（虚线）。右侧 SNS
> 主题把一条消息复制进多个订阅队列，Filter Policy 按属性裁剪投递对象。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/03_sqs_sns_messaging/images/sqs_sns_messaging.html)
> （或本地打开 [`images/sqs_sns_messaging.html`](images/sqs_sns_messaging.html)）。

**消费闭环与"至少一次"**：`send → receive → delete` 三步。receive 会把消息
置为 InFlight（不可见），删除才真正出队；不删除，可见性超时（Visibility
Timeout，队列属性，本实验设 5 秒）到期后消息重现。

这就是"至少一次"投递的来源——你在输出里看到的"超时未删：消息重新可见"正是
这个机制。它要求消费者能识别并跳过重复消息。

**毒丸如何进 DLQ**：队列的 `RedrivePolicy {maxReceiveCount: 3}` 表示第 3 次
收到仍未删除就转入 DLQ。实测要点有二：接收计数跨 receive 累加；转移是惰性的
——LocalStack 在 receive 活动中异步完成，脚本持续轮询约 8 秒后断言通过。

**FIFO 与 SNS 过滤**：FIFO 队列（`.fifo` 后缀）用 `ContentBasedDeduplication`
对消息体做 SHA-256 去重（实测 2 发 1 存），`MessageGroupId` 同组严格有序。

SNS 订阅侧挂 `{"color":["red"]}` 后，普通消息 q-all 收、q-red 不收，红色消息
两者都收——属性级过滤在投递前完成。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **`--attributes` 传 FilterPolicy/Policy 报参数解析错误**：值本身是 JSON
  字符串，CLI 简写语法处理不了嵌套引号。解法：用
  `json.dumps({"FilterPolicy": ...})` 整体构造后再传。
- **队列深度越查越少**：用 `receive-message` 数消息会真的消费掉它们。解法：
  查深度用 `get-queue-attributes` 读元数据。
- **删除队列后立刻重建同名队列偶发冲突**：删队列是异步的。解法：删除后轮询
  `list-queues` 直到消失再重建。
- **真实 AWS 下 SNS 消息进不了 SQS**：SQS 队列缺少允许 SNS 发送的队列策略。
  解法：按 `configs/queue-policy-sns-send.json` 挂策略（LocalStack 不校验，
  脚本仍保留了这一正确姿势）。

深入问答：

- **Q: 标准队列为什么可能重复投递？** A: 分布式队列为保证可用性选择"至少
  一次"；可见期内未删除就会重现。消费者用幂等键（让重复请求只生效一次的标记，如按 messageId 建去重表）吸收
  重复。
- **Q: 消息什么时候进 DLQ？** A: ReceiveCount 达到 maxReceiveCount（第 N 次
  receive 且未删除）。DLQ 深度要设告警，否则毒丸悄悄堆积。
- **Q: FIFO 的顺序保证范围？** A: 同一 MessageGroupId 内严格有序，跨组并行
  不保序；分组键按业务实体（订单号/用户 ID）设计。
- **Q: SNS 过滤策略不匹配的消息去哪了？** A: 只是不投递给该订阅，不影响其它
  订阅；无过滤的订阅照常收到全部消息。
- **Q: visibility timeout 设多长？** A: 略大于 P99（99% 的请求都不超过的
  处理时长）；长任务配合心跳
  续期（`ChangeMessageVisibility`），超时说明消费者挂了，让消息回队才是正解。

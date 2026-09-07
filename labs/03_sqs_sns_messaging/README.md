# 03 · SQS 队列 + SNS 发布订阅：队列、扇出与死信

> DynamoDB 解决"存"，但一个动作要**多个系统各自处理**时怎么办？直接互相调用就
> 耦合死了。消息是解法，而消息有两副面孔：SQS 队列是"一件事一个人做"（点对点），
> SNS 主题是"一件事大家都知道了"（发布/订阅扇出）。本实验把两副面孔、可见性
> 超时、毒丸入 DLQ、消息过滤一次跑通。

## 1. 为什么需要它

- **削峰解耦**：下单高峰 API 把订单丢进队列就返回，发货服务按自己的节奏消费。
- **可靠投递**：消费失败的消息不能丢——SQS 的答案是把"重试 N 次仍失败"的毒丸
  隔离进死信队列（DLQ），人工介入或重驱。
- **扇出**：订单事件要同时给"通知服务"和"审计服务"，SNS 一次发布、多队列各拿
  一份，还能按消息属性过滤，让订阅者只收自己关心的。

## 2. 总览：核心机制一图看懂

![SQS 与 SNS 消息](images/sqs_sns_messaging.svg)

> 怎么看：左侧实线是 SQS 点对点主路径——消费者"收到→处理→删除"，不删除就会在
> 可见性超时后重现（重试的来源）；失败次数超限被移入 DLQ（虚线）。右侧 SNS 主题
> 把一条消息复制进多个订阅队列，Filter Policy 按属性裁剪投递对象。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/03_sqs_sns_messaging/images/sqs_sns_messaging.html)
> （或本地打开 [`images/sqs_sns_messaging.html`](images/sqs_sns_messaging.html)）。

心智模型一句话：**SQS 是"至少一次"的待办清单，SNS 是"一份广播 N 份抄送"。**

## 3. 快速开始

```bash
cd labs/03_sqs_sns_messaging
./sqs_sns_messaging.sh            # apply → observe → clean（约 50 秒，含重试等待）
./sqs_sns_messaging.sh observe    # 只看演示：闭环/可见性/毒丸/FIFO/扇出
./sqs_sns_messaging.sh clean      # 删除全部队列与主题
```

真实运行输出（节选）：

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

## 4. 核心概念

### 4.1 消费闭环与"至少一次"

`send → receive → delete` 三步闭环。receive 会把消息置为 **InFlight**（不可见），
删除才真正出队；不删除，可见性超时后消息重现——这就是"至少一次"投递的来源，
**消费者必须幂等**（lab 14 会专门工程化这一点）。

### 4.2 Visibility Timeout：锁的期限

本实验把队列可见期设为 5s，实测：收到不删 → `NotVisible=1` → 6s 后消息重新
可见。设短了处理慢的消息会被重复消费，设长了失败后要干等——通常设为"正常处理
耗时的 6 倍"起步。

### 4.3 死信队列：毒丸隔离

`RedrivePolicy {maxReceiveCount: 3}`：第 3 次收到仍未删除的消息自动转入 DLQ。
两个实测要点：**接收计数跨 receive 累加**（LocalStack 里 `--visibility-timeout 0`
不计数，要留真实可见期）；**转移是惰性的**——LocalStack 在 receive 活动中异步
完成，脚本轮询约 8 秒完成。

### 4.4 FIFO 队列：去重与分组

`.fifo` 后缀强制；`ContentBasedDeduplication` 对消息体做 SHA-256 去重（本实验
2 发 1 存）；`MessageGroupId` 同组严格 FIFO、跨组并行。实测差异：LocalStack 的
receive **默认不回** `MessageGroupId`，需显式 `--attribute-names MessageGroupId`。

### 4.5 SNS 扇出与过滤

主题的两个订阅：`q-all` 无过滤全收，`q-red` 挂 `{"color":["red"]}` 只收红色。
实测：普通消息 q-all=1 / q-red=0；带 `color=red` 属性的消息两队列各收一份。
真实 AWS 还要求给 SQS 挂允许 SNS 发送的队列策略（`configs/queue-policy-sns-send.json`），
LocalStack 不校验但脚本保留了这个正确姿势。

## 5. 配置关键字段

```jsonc
// configs/filter-policy-red.json —— 订阅级过滤：值是数组=OR，多个键=AND
{
  "color": [ "red" ]          // 只有带 color=red 属性的消息投递给该订阅
}

// configs/queue-policy-sns-send.json —— SNS 能往 SQS 写的授权（真实 AWS 必需）
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "sns.amazonaws.com" },
    "Action": "sqs:SendMessage",
    "Resource": "__QUEUE_ARN__",             // 脚本 sed 替换
    "Condition": { "ArnEquals": { "aws:SourceArn": "__TOPIC_ARN__" } }  // 只许这个主题
  }]
}
```

坑清单：

- `--attributes` 传 `FilterPolicy`/`Policy` 时值本身是 JSON 字符串，CLI 简写
  语法解析不了嵌套引号——用 `json.dumps({"FilterPolicy": ...})` 整体构造；
- 队列深度用 `get-queue-attributes` 查（读元数据），别用 receive 来"数"——
  那会真的消费掉消息；
- 删除队列是异步的，删完立刻重建同名队列偶发冲突，`purge_all` 里 `sleep 1` 兜底。

## 6. 文件结构

```text
labs/03_sqs_sns_messaging/
├── README.md                        # 本文件
├── sqs_sns_messaging.sh             # 主演示脚本：闭环/可见性/毒丸/FIFO/扇出全流程
├── configs/
│   ├── filter-policy-red.json       # SNS 订阅过滤策略（声明式）
│   └── queue-policy-sns-send.json   # SQS 队列策略：允许指定 SNS 主题投递
└── images/
    ├── sqs_sns_messaging.architecture.json  # 架构图源（Typed JSON IR）
    ├── sqs_sns_messaging.html               # 交互版架构图
    └── sqs_sns_messaging.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: SQS 标准队列为什么可能重复投递？消费者怎么办？** A: 分布式队列为保证
  可用性选择"至少一次"；可见期内未删除就会重现。消费者用幂等键（messageId 去重
  表）吸收重复。
- **Q: 消息什么时候会进 DLQ？进了几次的判定？** A: ReceiveCount 达到
  maxReceiveCount（第 N 次 receive 且未删除）。DLQ 也要设告警监控深度，否则
  毒丸悄悄堆积。
- **Q: FIFO 的顺序保证范围？** A: 同一 MessageGroupId 内严格有序；跨组并行不保序。
  高吞吐场景按业务实体（订单号/用户 ID）设计分组键。
- **Q: SNS 过滤策略不匹配的消息去哪了？** A: 不投递给该订阅（直接丢弃对它而言），
  不影响其它订阅；全属性都不匹配且订阅无过滤则照常投递。
- **Q: visibility timeout 设多长？** A: 略大于 P99 处理时长；配合心跳续期
  (ChangeMessageVisibility) 处理长任务，超时说明消费者挂了，让消息回队才是正解。

## 8. 总结

队列给可靠性（重试、DLQ），主题给扩展性（扇出、过滤），FIFO 给严格有序——三件
套覆盖了消息中间件 90% 的考点。下一篇把消费者换成代码：Lambda 从"手动调用"进化
到"S3/DynamoDB 事件驱动"，无服务器的核心齿轮开始转动。

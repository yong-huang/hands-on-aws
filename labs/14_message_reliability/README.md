# 14 · 消息可靠性工程：幂等、毒丸、重驱与 FIFO

> 消息队列的"至少一次投递"在生产上是把双刃剑：重复投递可能重复扣款，反复失败
> 的消息会阻塞消费。本实验把四个生产级问题一次做实：幂等消费、毒丸隔离进死信
> 队列（DLQ）、死信重驱回主队列、FIFO 组内有序，共 9 项真实断言。

## Background

在可靠性工程实践成熟之前，消费失败的常见处理是"记日志然后删消息"或"无限
重试"：前者丢数据，后者让一条坏消息（毒丸，poison message，反序列化或处理必
然失败的消息）堵死整个队列。

两种粗暴方案都不对。 SQS 的机制给了正确姿势的原料：可见性超时让失败消息自动
重现（天然重试），RedrivePolicy 让重试超限的消息自动转入死信队列。缺的是三个
工程件——消费者侧的幂等（重复投递的吸收）、死信的监控告警、以及"修好之后把
死信搬回去重放"的运维闭环。本实验把这三件补齐。

## What

一句话定义：消息可靠性工程 = 用去重表吸收重复投递（幂等）、用 DLQ 隔离毒丸、
用重驱脚本完成"修复后重放"的闭环。

心智模型：可以把这套机制想象成医院的分诊流程——普通病人处理完离开（删除消
息）；复查才确诊的病人（处理成功但未删除）会再次叫号，护士核对病历（去重表）
后跳过重复；疑难杂症送隔离病房（DLQ）。

专家会诊（修复 bug）后转回普通病房（重驱）。但和真实医院不同的是：叫号系统
不记"叫过几次"的账，重复出现是常态而非异常，识别重复的责任在消费者。

四个构件：

- **去重表**：DynamoDB 表，主键 = messageId，处理前查、处理后写。
- **DLQ**：maxReceiveCount=3 的 RedrivePolicy，第 3 次收到未删除即转入。
- **重驱脚本**：把 DLQ 消息原样搬回主队列。
- **FIFO 队列**（First-In-First-Out，先进先出）：MessageGroupId 同组严格
  有序 + 内容去重。

## When to Use

典型场景：

- 计费/扣款类消费：重复执行 = 资损，必须幂等键兜底。
- 长尾失败任务：转码、外呼等任务总有千分之几的失败，DLQ + 重驱是标准运维
  闭环。
- 顺序敏感业务：账户操作、订单状态机，用 FIFO 分组保证同实体串行。

何时不用：一次性通知类消息（丢了无所谓）不需要这套重装备；全链路已经有
exactly-once 语义的流处理框架时，去重表可省。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 去重表（本实验） | DynamoDB 条件写，键 = messageId | 通用幂等方案 |
| 业务状态机幂等 | 用业务状态判断（已发货则跳过） | 状态天然可判重的业务 |
| FIFO 队列去重 | 队列侧 ContentBasedDeduplication | 发送侧防重 |
| 流处理框架 exactly-once | 框架级保证，成本高 | 超大吞吐流处理 |

## Quick Start

前置条件：LocalStack（在本机模拟 AWS API 的开源工具）运行中。运行方式：

```bash
cd labs/14_message_reliability
./message_reliability.sh            # 建拓扑 → 四场景演示 → 清理（约 2 分钟）
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 四大可靠性场景（详见 reliability_demo.py）
  ✅ 幂等消费：投递两次、业务只处理一次（第二次识别为 duplicate 并安全跳过）
  ✅ 毒丸连续失败 3 次 → 自动转入 DLQ（主队列清零）
  ✅ DLQ 重驱：死信搬回主队列，修复后消费者处理成功，两队列清零
  ✅ FIFO 组内严格有序: job-1→2→3（跨组并行由 mock 顺序化，真实 AWS 并行）
```

消费者处理逻辑的核心（`reliability_demo.py`）——查重、分流、记账三步：

```python
def handle(msg, *, broken=False):
    mid = msg["MessageId"]                        # 幂等键：跨投递稳定
    if broken and "poison" in body:
        return "failed"                           # 失败 = 不删除，等重投
    seen = ddb.get_item(TableName=TABLE, Key={"message_id": {"S": mid}}).get("Item")
    if seen:
        return "duplicate"                        # 重复投递：跳过
    ddb.put_item(TableName=TABLE, ...)            # 处理 + 记账
    return "processed"
```

新手第一个失败点：模拟"处理后崩溃"时容易把删除也写了——测试的关键恰恰是
**只处理、不删除**，等可见性超时（本实验 3 秒）后消息重现再验幂等。

## How It Works

![消息可靠性工程](images/message_reliability.svg)

> 怎么看：主路径是"消费者收到 → 查去重表 → 处理 → 删除"；处理成功但没删除
> （模拟崩溃）时消息重现，去重表识别 duplicate 并跳过——幂等闭环。毒丸走红色
> 支线：连续失败 3 次入 DLQ，修复后由重驱脚本搬回主队列再处理（蓝色回归线）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/14_message_reliability/images/message_reliability.html)
> （或本地打开 [`images/message_reliability.html`](images/message_reliability.html)）。

**幂等闭环如何验证**：发送一条消息，消费者第一次处理成功（写去重表）但故意
不删除；可见性超时后消息重现，第二次处理查表命中 duplicate 被跳过——实测
投递两次、业务只处理一次。

**重驱闭环如何验证**：毒丸消息经 3 次失败进入 DLQ 后，重驱脚本把死信**原样**
搬回主队列，由"修复后的消费者"（不再失败）处理并删除——实测两队列清零。
生产环境用 `StartMessageMoveTask`，本质相同。

**FIFO 如何保序**：同一 `MessageGroupId` 内严格按发送序投递（实测 job-1→2→3），
跨组并行。本机 mock 顺序化投递，真实 AWS 的跨组并行度更高。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **重复扣款**：处理成功但未删除，消息重现后被重复处理。解法：处理前查去重表，
  处理与记账合并为 DynamoDB 条件写（原子防并发双处理）。
- **DLQ 静默堆积**：死信没有消费者也没有告警。解法：DLQ 深度告警 + 定期重驱
  例行化。
- **LocalStack 的 Redrive 惰性**：转移在 receive 活动中异步发生（lab 03 实测）。
  解法：轮询 DLQ 深度时保持消费活动（脚本做法）。
- **FIFO 去重窗口误解**：ContentBasedDeduplication 只在 5 分钟窗口内去重，不是
  永久。解法：业务侧仍带显式去重键。

深入问答：

- **Q: 为什么做不到 exactly-once 投递？** A: 分布式系统"至少一次 + 消费幂等"
  工程上等价于 exactly-once，成本远低于全局事务；幂等键用业务 ID 而非随机数。
- **Q: 毒丸为什么能拖垮系统？** A: 它总在最前沿失败，反复重投挤占吞吐。DLQ
  隔离、告警、带上下文的死信是标准三件套。
- **Q: 重驱的速率怎么控？** A: 真实 AWS 的 StartMessageMoveTask 支持限速；
  重驱即重放，下游要能承受洪峰——又是幂等。
- **Q: MessageGroupId 怎么选？** A: 串行化的最小业务单元；组内并发为 1，组数
  决定并行度——太粗吞吐塌缩，太细失去有序意义。
- **Q: 去重表会无限膨胀吗？** A: 会。给 processed_at 设 TTL（如 7 天），远大于
  重复投递窗口即可安全过期。

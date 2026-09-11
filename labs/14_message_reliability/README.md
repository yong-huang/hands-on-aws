# 14 · 消息可靠性工程：幂等、毒丸、重驱与 FIFO

> "消息至少一次投递"在生产上是把双刃剑：重复投递会重复扣款，处理失败的消息会
> 消失吗？会不会死循环？本实验把四个生产级问题一次做实：**重复投递的幂等吸收、
> 毒丸消息的 DLQ 隔离、死信的运维重驱、FIFO 的组内有序**。

## 1. 为什么需要它

- lab 03 验证了 DLQ 的机制；本实验补齐**运维闭环**：毒丸隔离之后怎么修复、怎么
  搬回去、怎么证明修好了。
- 幂等不是可选项：至少一次投递意味着重复是常态，业务必须以幂等键（messageId）
  兜底。

## 2. 总览：核心机制一图看懂

![消息可靠性工程](images/message_reliability.svg)

> 怎么看：主路径是"消费者收到 → 查去重表 → 处理 → 删除"；处理成功但没删除
> （模拟崩溃）时消息重现，去重表识别 duplicate 并跳过——幂等闭环。毒丸走红色
> 支线：连续失败 3 次入 DLQ，修复后由重驱脚本搬回主队列再处理（蓝色回归线）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/14_message_reliability/images/message_reliability.html)
> （或本地打开 [`images/message_reliability.html`](images/message_reliability.html)）。

心智模型一句话：**去重表管重复，DLQ 管失败，重驱管修复——三者构成消息的安全生产环。**

## 3. 快速开始

```bash
cd labs/14_message_reliability
./message_reliability.sh            # 建拓扑 → 四场景演示 → 清理（约 2 分钟）
```

真实运行输出：

```text
=====> [observe] 四大可靠性场景（详见 reliability_demo.py）
  ✅ 幂等消费：投递两次、业务只处理一次（第二次识别为 duplicate 并安全跳过）
  ✅ 毒丸连续失败 3 次 → 自动转入 DLQ（主队列清零）
  ✅ DLQ 重驱：死信搬回主队列，修复后消费者处理成功，两队列清零
  ✅ FIFO 组内严格有序: job-1→2→3（跨组并行由 mock 顺序化，真实 AWS 并行）
```

## 4. 核心概念

### 4.1 幂等消费：去重表是标准答案

处理前先查 `ho14-dedup` 表（键 = SQS MessageId，重复投递天然同 id）：没有则
处理并写表，有则跳过。本实验实测：消息处理成功但**不删除**（模拟处理后崩溃），
可见性超时重现后第二次投递被识别为 duplicate 安全跳过。

### 4.2 毒丸隔离：maxReceiveCount 的判定语义

消费者"收到即失败、不删除"，ReceiveCount 累计到 3 → 消息自动转入 DLQ（实测
主队列清零、DLQ 出现毒丸）。消费者要区分"业务失败"（重试有意义）与"毒丸"
（永远失败，重试无意义）。

### 4.3 重驱：修好再回来

DLQ 不是坟场：定位 bug → 修复上线 → 重驱脚本把死信**原样搬回**主队列 → 由
修复后的消费者处理。本实验实测毒丸被搬回、处理成功、两队列清零。生产用
`redrive` 策略或 StartMessageMoveTask，本质相同。

### 4.4 FIFO 组内有序

同一 MessageGroupId 内严格 FIFO（实测 job-1→2→3 保序）；跨组并行。分组键选
"需要串行的最小业务单元"（如单账户、单订单）。

## 5. 代码关键字段（reliability_demo.py）

```python
def handle(msg, *, broken=False):
    mid = msg["MessageId"]                        # 幂等键：跨投递稳定
    if broken and "poison" in body:
        return "failed"                           # 失败 = 不删除，等可见性超时重投
    seen = ddb.get_item(TableName=TABLE, Key={"message_id": {"S": mid}}).get("Item")
    if seen:
        return "duplicate"                        # 重复投递：跳过
    ddb.put_item(TableName=TABLE, ...)            # 处理 + 记去重（生产用条件写原子化）
    return "processed"
```

坑清单：

- 查表与写表应合并为**条件写**（attribute_not_exists）防并发双处理；
- DLQ 也要监控（深度告警），否则毒丸悄悄堆积；
- 重驱前必须先修复 bug，否则毒丸原路打回；
- LocalStack 的 Redrive 是惰性异步：靠持续 receive 的"队列活动"推进（lab 03 实测）。

## 6. 文件结构

```text
labs/14_message_reliability/
├── README.md                    # 本文件
├── message_reliability.sh       # 主脚本：建拓扑（Redrive/VT/FIFO）→ 四场景 → 清理
├── reliability_demo.py          # 核心：幂等/毒丸/重驱/FIFO 四段可运行断言
└── images/
    ├── message_reliability.architecture.json  # 图源（Typed JSON IR）
    ├── message_reliability.html            # 交互版
    └── message_reliability.svg             # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: 为什么不能做到 exactly-once 投递？** A: 分布式系统中"至少一次 + 消费幂等"
  工程上等价于 exactly-once，且成本远低于全局事务；幂等键选业务 ID 而非随机数。
- **Q: 毒丸为什么会拖垮系统？** A: 它总在消费最前沿失败，反复重投挤占吞吐；
  DLQ 隔离 + 告警 + 快速定位（死信带原始错误上下文）是标准三件套。
- **Q: 重驱的速率怎么控？** A: 真实 AWS StartMessageMoveTask 支持限速；重驱本质
  是重新入队，下游要能承受重放洪峰（也是幂等的用武之地）。
- **Q: FIFO 的 MessageGroupId 怎么选？** A: 串行化的最小业务单元；组内并发为 1，
  组数决定并行度——组太粗则吞吐塌缩，太细则失去有序意义。
- **Q: 去重表会无限膨胀吗？** A: 会。给 processed_at 设 TTL（如 7 天），消息
  重复投递窗口远小于此即可安全过期。

## 8. 总结

幂等表、死信队列、重驱脚本、FIFO 分组——四个组件把"至少一次投递"驯服成
"业务恰好一次"的效果，全部真机验证。下一篇回到 DynamoDB 的高级特性：Streams、
TTL、事务与单表设计（含本机已知缺陷的降级实录）。

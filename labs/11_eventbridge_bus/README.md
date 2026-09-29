# 11 · EventBridge 事件总线与规则路由

> Amazon EventBridge 是一种托管事件总线（event bus）：事件源把事件发布到总线，
> 一组规则（rule）按内容模式决定投递给哪些目标。本实验建自定义总线、三种匹配
> 规则（精确+数值 / 前缀 / 定时）、SQS+Lambda 双目标路由，共 8 项真实断言。

## Background

在事件总线普及之前，"一个动作通知多个下游"靠点对点接线：订单服务在代码里依次
调用通知、风控、审计，或者给每个下游单独配一个队列订阅。

点对点接线撞上两堵墙。第一，发布者与消费者强耦合——每加一个下游都要改发布者
代码，"谁在监听订单事件"只存在于代码细节里。

第二，路由逻辑分散——"大额订单走风控"这样的规则散落各处，改一条要发版。
EventBridge（2020 年由 CloudWatch Events 升级而来）把接线反过来：所有事件先
进总线，路由规则集中在总线一侧管理，发布者与消费者互不相识。

## What

一句话定义：EventBridge 是一种托管事件总线服务——事件（JSON，含 source、
detail-type、detail 三个语义字段）发布到总线后，由规则按内容模式匹配并投递给
目标（SQS、Lambda 等）。

心智模型：可以把总线想象成机场的航班信息大屏——航空公司（发布者）只管把航班
动态放上屏，接机的人（目标）盯自己关心的航班号。但和真实大屏不同的是：大屏
还能替你"分拣"——规则可以按事件内容过滤（数值比较、前缀匹配），甚至到点自动
生成一条"虚拟航班"（定时调度）。

三种规则（本实验全部实测）：

- **精确 + 数值**：`source=app.orders` 且 `detail.amount > 100` 才投递。
- **前缀**：`source` 以 `app.` 开头的全收。
- **定时**：`rate(1 minute)` 到点自动生成事件（只能建在 default 总线——每个区域自动存在的默认总线）。

## When to Use

典型场景：

- 事件驱动架构的中枢：订单、支付、库存等事件源全部入总线，下游按规则订阅。
- 内容感知路由：`amount>100` 走风控队列、其余走普通队列——路由即配置。
- 定时触发：cron/rate 表达式到点触发 Lambda，与业务事件共用同一套目标管理。

何时不用：单一下游的简单解耦（一个 SQS 队列足够）；对投递顺序有严格要求的
管道（总线不保序，选 Kinesis 或 FIFO）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| EventBridge | 内容模式匹配、多目标、定时、归档重放 | 事件架构中枢、SaaS 集成 |
| SNS | 扇出广播，属性过滤较弱 | 简单扇出、移动推送 |
| SQS 直发 | 发布者直接写队列 | 下游唯一且固定 |
| S3 通知 | 只对 S3 事件 | 文件处理管道（lab 13） |

## Quick Start

前置条件：LocalStack（在本机模拟 AWS API 的开源工具）运行中；awslocal 是指向它的
AWS CLI 包装命令。运行方式：

```bash
cd labs/11_eventbridge_bus
./eventbridge_bus.sh            # 建总线+三规则 → 发事件验证 → 清理（约 3 分钟，含等 cron）
./eventbridge_bus.sh observe    # 只跑匹配断言
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 发 3 类事件：大额订单(250) / 小额订单(50) / 无关来源(other.thing)
  ✅ 数值规则只收 amount>100（o-1，o-2 被滤掉）
  ✅ 前缀规则收全部 app.* 事件（250 与 50）
  ✅ other.thing 无任何队列收到（source 不匹配）
=====> [observe] cron 定时调度：等待 rate(1 minute) 触发（最长 90 秒）
  ✅ 定时规则真实触发了 Lambda（日志含 cron.tick）
```

事件与规则的发布/声明方式（发布内容是脚本用 python 组装的 JSON，避免双层
转义出错）：

```bash
awslocal events put-rule --name r1 --event-bus-name ho11-bus \
  --event-pattern '{"source":["app.orders"],
                    "detail":{"amount":[{"numeric":[">",100]}]}}'
awslocal events put-events --entries '[{"EventBusName":"ho11-bus",
  "Source":"app.orders","DetailType":"OrderCreated","Detail":"{...}"}]'
```

新手第一个失败点：`ScheduleExpression` 规则建在自定义总线上会报错——本机实测
与真实 AWS 一致，定时规则只能建在 default 总线（脚本已把规则③移到 default）。

## How It Works

![EventBridge 事件总线](images/eventbridge_bus.svg)

> 怎么看：发布者把事件丢进自定义总线（PutEvents）就结束；三条规则各自匹配——
> 规则①精确 source + 数值过滤路由到"队列 + Lambda"**双目标**，规则②按 source
> 前缀全收，规则③挂在默认总线上按 rate 定时触发。不匹配的事件静默消失。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/11_eventbridge_bus/images/eventbridge_bus.html)
> （或本地打开 [`images/eventbridge_bus.html`](images/eventbridge_bus.html)）。

**内容匹配如何工作**：规则的 `event-pattern` 是一段 JSON，与事件做深度比较——
实测 250 元订单命中数值规则（进 SQS+Lambda 双目标）、50 元订单被其拒绝、
`other.thing` 来源谁也不收。模式匹配的是事件内容本身，改路由只改规则。

**多目标投递**：一条规则 `put-targets` 可挂多个目标（本实验 SQS 与 Lambda 同
投，实测日志含 `app.orders`）。真实 AWS 还要求给 SQS 队列挂资源策略授权总线
写入。

**定时调度如何工作**：`rate(1 minute)` 规则到点自动生成事件投给目标，目标可带
静态 `Input`（本实验用 `{"source":"cron.tick"}` 做标记）。实测 90 秒内 Lambda
日志出现 `cron.tick`——定时事件与业务事件走同一套目标语义。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **定时规则建在自定义总线报错**：ScheduleExpression 仅支持 default 总线
  （实测，与真实 AWS 一致）。解法：定时规则去掉 `--event-bus-name`。
- **`Detail` 字段双层转义出错**：它是字符串化的 JSON。解法：用
  `json.dumps` 整体构造 entries。
- **改规则前忘删目标**：目标还挂着时删规则报错。解法：先 `remove-targets` 再
  `delete-rule`。
- **数值匹配静默失效**：`amount` 以字符串形式发布时数值规则不命中。解法：
  发布侧保证类型，并像脚本一样用断言验证路由结果。

深入问答：

- **Q: EventBridge 与 SNS 的本质区别？** A: SNS 是消息扇出（属性过滤）；Event
  Bridge 是事件总线（内容模式匹配、归档重放、第三方 SaaS 接入）。
- **Q: 事件会丢吗？** A: 至少一次投递；可开归档（Archive）保存事件流，必要时
  `start-replay` 重放给新目标。
- **Q: 不匹配的事件去哪了？** A: 静默消失、不计费目标调用。解法：给每类事件
  建断言（脚本做法），路由变更时回归验证。
- **Q: Input 与 InputPath 的作用？** A: 定制投给目标的事件形状——Input 静态
  替换（cron 用它传标记），InputPath 抽取事件片段。

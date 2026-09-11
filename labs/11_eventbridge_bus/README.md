# 11 · EventBridge 事件总线与规则路由

> SNS 扇出是"发布者自己选听众"；当系统长到几十个事件源、上百个消费者时，你需要
> 一个**中央事件大厅**：所有事件先落总线，路由规则集中管理——这就是 EventBridge。
> 它带模式匹配（精确/前缀/数值）、一事件多目标、定时调度，是事件架构的指挥中心。

## 1. 为什么需要它

- **发布者与消费者彻底解耦**：订单服务只管发 `app.orders`，谁订阅、几个订阅，
  它一无所知也不必知道。
- **规则即路由**：`{"amount":[{">":100}]}` 这样一行 JSON 就能实现"大额订单走
  风控"的路由逻辑，改路由不用改代码。
- **cron 也能进总线**：定时事件和业务事件走同一套目标管理，监控告警视角统一。

## 2. 总览：核心机制一图看懂

![EventBridge 事件总线](images/eventbridge_bus.svg)

> 怎么看：发布者把事件丢进自定义总线（PutEvents）就结束；三条规则各自匹配——
> 规则①精确 source + 数值过滤路由到"队列 + Lambda"**双目标**，规则②按 source
> 前缀全收，规则③挂在默认总线上按 rate 定时触发。不匹配的事件静默消失。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/11_eventbridge_bus/images/eventbridge_bus.html)
> （或本地打开 [`images/eventbridge_bus.html`](images/eventbridge_bus.html)）。

心智模型一句话：**生产者只管发，规则决定谁收到——匹配逻辑集中在总线一侧。**

## 3. 快速开始

```bash
cd labs/11_eventbridge_bus
./eventbridge_bus.sh            # 建总线+三规则 → 发事件验证 → 清理（约 3 分钟，含等 cron）
./eventbridge_bus.sh observe    # 只跑匹配断言
```

真实运行输出（节选）：

```text
=====> [observe] 发 3 类事件：大额订单(250) / 小额订单(50) / 无关来源(other.thing)
  ✅ 数值规则只收 amount>100（o-1，o-2 被滤掉）
  ✅ 前缀规则收全部 app.* 事件（250 与 50）
  ✅ other.thing 无任何队列收到（source 不匹配）
=====> [observe] cron 定时调度：等待 rate(1 minute) 触发（最长 90 秒）
  ✅ 定时规则真实触发了 Lambda（日志含 cron.tick）
```

## 4. 核心概念

### 4.1 事件、总线与规则的三层模型

事件是 JSON（`source/detail-type/detail` 是语义三要素）；自定义总线是事件的
"频道"；规则从事件流里挑出匹配子集投给目标。本实验自建 `ho11-bus`，业务事件
与 AWS 服务事件（走 default 总线）分流。

### 4.2 事件模式：内容感知路由

三种匹配实测：`source:["app.orders"]` 精确、`{"prefix":"app."}` 前缀、
`detail.amount:[{"numeric":[">",100]}]` 数值比较——250 进双目标、50 被规则①
拒收、`other.thing` 谁也不收。模式匹配的是**事件内容**，不是消息头。

### 4.3 多目标与投递语义

一条规则可挂多个目标（本实验 SQS + Lambda 同投）。EventBridge 至少一次投递、
目标各自重试；队列目标要给总线授权（`add-permission`）。

### 4.4 定时调度：default 总线的特殊规则

`rate(1 minute)` 定时规则在**默认总线**上创建（实测：自定义总线报
`ScheduleExpression is supported only on the default event bus`——LocalStack 与
真实 AWS 行为一致的差异点）。调度事件可带静态 `Input` 作为载荷。

## 5. 命令关键字段

```bash
awslocal events put-rule --name r1 --event-bus-name ho11-bus \
  --event-pattern '{"source":["app.orders"],
                    "detail":{"amount":[{"numeric":[">",100]}]}}'
awslocal events put-targets --rule r1 --event-bus-name ho11-bus \
  --targets '[{"Id":"q","Arn":"arn:aws:sqs:...:ho11-highvalue-q"},
              {"Id":"fn","Arn":"arn:aws:lambda:...:ho11-fn"}]'
awslocal events put-events --entries '[{"EventBusName":"ho11-bus",
  "Source":"app.orders","DetailType":"OrderCreated","Detail":"{...}"}]'
```

坑清单：

- `Detail` 是**字符串化的 JSON**——双层转义最易写错（脚本用 python 组装）；
- ScheduleExpression 规则只能在 default 总线（实测）；
- 队列作为目标需要资源策略授权，否则真实 AWS 会静默投递失败；
- 规则改名/换总线要先 `remove-targets` 再 `delete-rule`。

## 6. 文件结构

```text
labs/11_eventbridge_bus/
├── README.md                 # 本文件
├── eventbridge_bus.sh        # 主演示脚本：总线/规则/双目标/cron 全流程
├── event_sink.py             # 事件接收 Lambda（日志即验证）
└── images/
    ├── eventbridge_bus.architecture.json  # 图源（Typed JSON IR）
    ├── eventbridge_bus.html               # 交互版
    └── eventbridge_bus.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: EventBridge 与 SNS 的本质区别？** A: SNS 是"推拉订阅"的消息服务，过滤
  能力弱（属性匹配）；EventBridge 是事件总线，支持**内容模式匹配**、转换、
  归档重放、第三方 SaaS 事件接入。
- **Q: 事件模式的匹配规则开销？** A: 模式在总线上评估，不匹配不投递不计费目标
  调用；模式写错（如数值用了字符串）会静默不匹配——必须用断言验证路由。
- **Q: 如何保证事件不丢？** A: 总线开启归档（Archive）+ 目标侧 DLQ；重放用
  `start-replay`。
- **Q: Input 与 InputPath 的作用？** A: 定制投给目标的事件形状——Input 静态
  替换（本实验 cron 用它传标记），InputPath 从事件中抽取片段。
- **Q: cron 与 rate 的区别？** A: rate 是固定频率（不受时间影响），cron 表达式
  可指定具体时刻与时区；两者都是 default 总线规则。

## 8. 总结

一条总线、三种匹配、双目标路由加定时调度——事件从"点对点管道"升级成"可编程
大厅"。下一篇进入流的世界：Kinesis 的分片、迭代器与重放。

# 22 · CloudWatch 指标与告警闭环

> Amazon CloudWatch 的指标与告警构成"系统自己报障"的机制：应用上报自定义
> 业务指标，Alarm 按阈值评估并在状态间流转（INSUFFICIENT_DATA → ALARM → OK），
> 进 ALARM 时触发 SNS 通知、落地到 SQS 队列。本实验端到端做实这条闭环，共
> 8 项真实断言。

## Background

在指标告警体系成熟之前，系统健康靠人工盯仪表盘或用户报障：出问题最先知道的
往往是客户。

被动监控撞上两堵墙。第一，发现滞后——错误率从 1% 涨到 50% 的过程无人察觉，
直到用户投诉。第二，无量纲——"日志很多"不等于"错误在涨"，缺少按维度聚合的
数值化指标就无法设定阈值。

CloudWatch 的答案分三层：指标（Metric，带维度的
时间序列数值）、告警（Alarm，按阈值与周期评估的状态机）、通知动作（进 ALARM
时触发 SNS 主题，再分发到队列/邮件/IM）。

## What

一句话定义：CloudWatch 指标是带维度（dimension，键值对形式的过滤标签）的
时间序列数值；告警（Alarm）是订阅某指标聚合值的阈值评估器，在
INSUFFICIENT_DATA、OK、ALARM 三态间流转。

心智模型：可以把指标想象成体检报告里的各项数值（按器官分维度记录），Alarm
是体检报告上的参考范围标注——某项连续超出范围就在报告上标红。但和真实体检
不同的是：标红的那一刻它会主动打电话（触发 SNS 通知动作），数值恢复后还会
主动销假（回 OK）。

三态与动作：

- **INSUFFICIENT_DATA**：数据点不足，无法评估（新告警的初始态）。
- **ALARM**：连续评估窗口越限，触发 alarm-actions。
- **OK**：恢复，可再配 OK-actions。

## When to Use

典型场景：

- 业务健康监控：错误数、P99 延迟（按耗时排序第 99% 位置的值）（按耗时排序第 99% 位置的值，代表最慢的
  1% 请求）、队列积压深度按维度上报，越限即告警。
- 容量预警：剩余连接数/磁盘/配额跌破水位提前通知。
- 自动止血：ALARM 时触发 Auto Scaling 扩容或 Lambda 修复动作。

何时不用：一次性的探针检查（直接调 API 看结果）；无法量化的主观状态（先
定义度量再谈告警）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CloudWatch 指标+告警 | AWS 原生、与服务联动 | AWS 应用的默认方案 |
| Prometheus + Alertmanager | 拉模型、丰富查询语言，自运维 | Kubernetes 与多云场景 |
| 应用自身心跳 | 外部视角探测整体可用性 | 补充"静默故障"盲区 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/22_cloudwatch_alarms
./cloudwatch_alarms.sh            # 建通知链 → 指标/告警/恢复闭环 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 指标可查询（api 维度 Sum=5 的数据点存在）
  ✅ 指标可查询（api 维度 Sum=5 的数据点存在）
=====> [observe] Alarm：Errors Sum ≥ 3 → ALARM（周期 60s，评估 1 点）
  ✅ 初始状态: ALARM（越限数据已在窗口内则直接 ALARM）
  ✅ 越限后进入 ALARM
=====> [observe] 告警通知闭环：SNS 把告警消息投递到 SQS
  ✅ 告警消息已进 SQS（SNS 订阅投递）
=====> [observe] 恢复：数据回落 → 回 OK
  ✅ 数据回落回 OK
```

指标打点的核心命令（时间戳必须用容器时钟，从 LocalStack 响应头取——脚本的
`ts()` 函数处理）：

```bash
awslocal cloudwatch put-metric-data --namespace Ho22 \
  --metric-data file:///tmp/metric.json   # [{"MetricName":"Errors",
                                          #   "Dimensions":[{"Name":"Service",
                                          #                 "Value":"api"}],
                                          #   "Value": 9, "Timestamp": <容器时钟>}]
```

新手第一个失败点：按宿主机时间打点后告警永远不触发——容器时钟落后宿主机约
3 小时（lab 12 已发现），越限数据点落在评估窗口之外。解法就是上面的容器时钟。

## How It Works

![CloudWatch 指标与告警](images/cloudwatch_alarms.svg)

> 怎么看：应用按维度（Service=api/worker）上报 Errors 指标；Alarm 订阅
> "api 维度 Sum≥3"，状态机在 INSUFFICIENT_DATA/OK/ALARM 间流转；进 ALARM 时
> 触发 SNS 主题，订阅的 SQS 队列收到告警消息——值班侧从队列消费。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/22_cloudwatch_alarms/images/cloudwatch_alarms.html)
> （或本地打开 [`images/cloudwatch_alarms.html`](images/cloudwatch_alarms.html)）。

**维度如何分流指标**：同一个 `Errors` 指标名按 `Service` 维度拆成 api 与
worker 两条时间序列（实测 list-metrics 返回 2 条）——告警只盯 api 维度，
worker 的错误不会误触发。维度键值必须与打点时完全一致。

**告警状态机如何流转**：`put-metric-alarm` 声明"每 60 秒取 Sum，≥3 即
ALARM"。实测注入 Sum=9 后进入 ALARM 并触发 SNS；连续注入 Sum=0 后回 OK。
注意告警只在状态**变化**时触发动作——持续 ALARM 不会重复通知。

**通知如何闭环**：SNS 主题订阅 SQS 队列，ALARM 动作发到主题，队列深度实测
+1——值班系统从队列消费告警（可再转 IM/工单）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **告警永远 INSUFFICIENT_DATA**：数据点时间戳落在评估窗口之外（时钟漂移）。
  解法：用容器时钟打点（脚本 `ts()` 从 LocalStack 响应头取时间）。
- **维度对不上，告警读不到指标**：打点与告警声明的 Dimensions 键值不完全
  一致。解法：两侧用同一份常量。
- **统计口径选错**：Sum 数次数、Average 看均值、p99 需要扩展统计（extended
  statistics）。解法：先明确"阈值该加在哪个口径上"。

深入问答：

- **Q: period/evaluationPeriods 如何权衡误报漏报？** A: 窗口越短越灵敏越毛
  躁；连续 N 个窗口越限才告警可压误报，代价是漏报窗口拉长。
- **Q: 告警风暴怎么防？** A: 复合告警（Composite Alarm，多告警与/或）、分层
  告警、变更窗口静默。
- **Q: 缺数据（INSUFFICIENT_DATA）算故障吗？** A: `treat-missing-data` 可配
  notBreaching/missing/breaching——采集断了算不算故障是业务决策。
- **Q: ALARM 还能触发什么？** A: 除 SNS 外可触发 Auto Scaling 扩容、Lambda 自动修复、Systems Manager（AWS 的运维操作
  服务）里的 OpsItem（一条待处理运维工单）——"自动止血"是告警的进阶形态。

# 22 · CloudWatch 指标与告警闭环

> 日志会查询了（lab 21），下一步是"系统自己喊疼"：业务指标越限 → Alarm 进入
> ALARM → SNS 通知 → SQS 落地 → 恢复后回 OK。这一整条**告警状态机**在本实验
> 端到端做实。

## 1. 为什么需要它

- 人工盯监控不可扩展；告警是"系统主动报障"的唯一正道。
- 自定义业务指标（错误数、延迟、队列深度）比基础设施指标更早暴露问题。
- 告警必须**闭环**：ALARM 状态要能触达值班渠道（SNS→SQS/邮件/IM）。

## 2. 总览：核心机制一图看懂

![CloudWatch 指标与告警](images/cloudwatch_alarms.svg)

> 怎么看：应用按维度（Service=api/worker）上报 Errors 指标；Alarm 订阅
> "api 维度 Sum≥3"，状态机在 INSUFFICIENT_DATA/OK/ALARM 间流转；进 ALARM 时
> 触发 SNS 主题，订阅的 SQS 队列收到告警消息——值班侧从队列消费。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/22_cloudwatch_alarms/images/cloudwatch_alarms.html)
> （或本地打开 [`images/cloudwatch_alarms.html`](images/cloudwatch_alarms.html)）。

心智模型一句话：**指标是体温计，Alarm 是大脑，SNS/SQS 是喊人的嗓子。**

## 3. 快速开始

```bash
cd labs/22_cloudwatch_alarms
./cloudwatch_alarms.sh            # 建通知链 → 指标/告警/恢复全流程 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] Alarm：Errors Sum ≥ 3 → ALARM（周期 60s，评估 1 点）
  ✅ 初始状态: ALARM（越限数据已在窗口内则直接 ALARM）
  ✅ 越限后进入 ALARM
=====> [observe] 告警通知闭环：SNS 把告警消息投递到 SQS
  ✅ 告警消息已进 SQS（SNS 订阅投递）
=====> [observe] 恢复：数据回落 → 回 OK
  ✅ 数据回落回 OK
```

## 4. 核心概念

### 4.1 维度设计：指标的第二主键

同一 `Errors` 指标按 `Service` 维度拆成 api/worker 两路（实测 2 条 Metric），
告警只盯 api 维度——**维度就是指标的过滤键**，设计好了才能"精确告警不误伤"。

### 4.2 Alarm 状态机三态

`INSUFFICIENT_DATA`（数据不足）→ 数据越限 `ALARM` → 回落 `OK`。本实验实测完整
流转：注入 Sum=9（阈值 3）进 ALARM，注入 0 恢复 OK。评估参数：period（聚合
窗口 60s）+ evaluation-periods（连续几个窗口）。

### 4.3 通知闭环

`alarm-actions` 挂 SNS Topic，Topic 的 SQS 订阅让告警落地为消息（可被值班系统
消费/转 IM）。实测 ALARM 后队列出现告警消息。

### 4.4 时钟陷阱（本机实录）

容器时钟落后宿主机约 3 小时（lab 12/21 坑的根源），按宿主机时间打的数据点在
容器眼里"太旧"，告警永不触发。解法：**从 LocalStack 响应头取容器时钟**打点。
这个坑在生产对应的是"NTP 漂移导致告警失灵"。

## 5. 命令关键字段

```bash
awslocal cloudwatch put-metric-data --namespace Ho22 \
  --metric-data file://metric.json      # [{"MetricName","Dimensions","Value","Timestamp"}]

awslocal cloudwatch put-metric-alarm --alarm-name err \
  --namespace Ho22 --metric-name Errors \
  --dimensions '[{"Name":"Service","Value":"api"}]' \
  --statistic Sum --period 60 --evaluation-periods 1 --threshold 3 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$TOPIC_ARN"          # ALARM 时触发
```

坑清单：

- 指标时间戳超出容器/服务器时钟窗口 = 数据点被忽略 → 告警永远 INSUFFICIENT_DATA；
- `--dimensions` 必须与指标上报时**完全一致**（键值序都算）才能对上；
- 统计口径：Sum 数次数、Average 看均值、p99 近似用 SampleCount+percentile；
- 告警只在状态**变化**时触发 action，持续 ALARM 不会重复通知。

## 6. 文件结构

```text
labs/22_cloudwatch_alarms/
├── README.md                 # 本文件
└── cloudwatch_alarms.sh      # 主脚本：通知链 → 指标/告警/恢复闭环 → 清理
```

> 注：图片三件套见 `images/`。

## 7. 深入要点

- **Q: period/evaluationPeriods 如何权衡误报漏报？** A: 窗口越短越灵敏越毛躁；
  连续 N 个窗口越限才告警可压误报，代价是漏报窗口拉长。
- **Q: 复合告警（Composite Alarm）解决什么？** A: 多告警"与/或"降噪——单机抖动
  不报，全站同时越限才报（抑制告警风暴）。
- **Q: 告警风暴怎么防？** A: 分层告警（基础设施→服务→业务）、抑制规则、
  维度聚合收敛、变更窗口静默。
- **Q: 缺数据（INSUFFICIENT_DATA）该怎么处理？** A: treat-missing-data 可配
  notBreaching/missing/breaching——采集断了算不算故障是业务决策。
- **Q: 告警动作除了 SNS 还能做什么？** A: 触发 Auto Scaling、ECR/SQS、
  Systems Manager OpsItem；"自动止血"是告警的进阶形态。

## 8. 总结

维度化指标、三态告警、通知闭环、恢复回 OK——"系统自己喊疼"的完整链路真机
打通（外加一个昂贵的时钟漂移教训）。下一篇攻密钥治理：多版本 Secret 的轮换
与无感切换。

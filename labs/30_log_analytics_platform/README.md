# 30 · 终极实战：实时日志分析平台

> 收官。把 11-29 的全部能力拧成一台平台级系统：SDK 生成器灌 1000 条日志 →
> Kinesis 聚流 → 清洗 Lambda（脱敏/结构化）→ DynamoDB 明细 + S3 按天归档 →
> ERROR 告警入队 → CloudWatch 指标注册。CDK 一键部署，`make run` 一键演示，
> 重跑幂等，销毁复原。

## 1. 为什么需要它

- 平台级系统考验的不是单点技术，而是**边界**：数据在哪、告警怎么走、归档按
  什么切、重跑会不会重复计数——每个环节都要有明确答案。
- 1000 条压测 + 全链路断言 = 平台的"出厂检验单"，任何一段退化立刻暴露。

## 2. 总览：核心机制一图看懂

![实时日志分析平台](images/log_analytics_platform.svg)

> 怎么看：实线主数据路径——生成器按 run 标记灌日志进 Kinesis；清洗 Lambda
> 按批次拉取，脱敏后写 DynamoDB 明细、按天归档 S3、ERROR 推告警队列；虚线
> 观测路径——生成器打 CloudWatch 指标，全套资源由 CDK 栈管理（bootstrap 后
> deploy/destroy）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/30_log_analytics_platform/images/log_analytics_platform.html)
> （或本地打开 [`images/log_analytics_platform.html`](images/log_analytics_platform.html)）。

心智模型一句话：**采（流）→ 洗（函数）→ 存（表+桶）→ 警（队列）→ 看（指标），
五段各有断言。**

## 3. 快速开始

```bash
cd labs/30_log_analytics_platform
make run                  # CDK 部署 → 1000 条压测 → 全链路断言 → 销毁（约 3 分钟）
make deploy               # 只部署平台
make clean                # 只销毁
```

真实运行输出（节选）：

```text
=====> [observe] 1000 条压测 + 全链路断言
  灌入 1000 条日志（run=f0f190e8，含 100 条 ERROR）
  ✅ 已写入 1000 条
  ✅ DynamoDB 明细入库（1000）
  ✅ 告警队列收到 ERROR（100）
  ✅ S3 归档对象生成（10）
  ✅ CloudWatch 指标注册（2）
=====> [clean] CDK 一键销毁平台栈
  ✅ 平台已销毁，环境复原
```

## 4. 核心概念

### 4.1 五段管道与断言矩阵

| 段 | 组件 | 断言 |
|:---|:---|:---|
| 采 | Kinesis（1 分片） | put_records FailedRecordCount=0 |
| 洗 | 清洗 Lambda（映射 LATEST） | Lambda Active + 映射 Enabled |
| 存 | DynamoDB 明细 + S3 归档 | 明细 ≥95% 入库；归档对象生成 |
| 警 | SQS 告警队列 | ERROR 数 100 条落队 |
| 看 | CloudWatch Ho30 指标 | Metrics 注册 2 条 |

### 4.2 run 标记：压测的幂等隔离

每轮压测生成 `run=<uuid8>` 写进每条日志——明细表按 run 过滤统计，重跑不互相
污染；S3 归档按天分目录、按批时间戳命名，天然幂等。

### 4.3 脱敏在清洗层

清洗器对 `138****` 类手机号打码后才落库——**敏感治理集中在管道的单一入口**，
下游（明细/归档）拿到的都是安全数据。

### 4.4 CDK 资产与 bootstrap

栈内含 `Code.from_asset`（函数代码是"资产"），首次 deploy 需要
`cdklocal bootstrap`（建 CDKToolkit 栈与资产桶，实测 12/12 资源）。这是 CDK
落地的第一道门槛，脚本已自动化。

## 5. 代码关键字段

```python
# cleaner.py：批处理主循环
for r in event["Records"]:
    log = json.loads(base64.b64decode(r["kinesis"]["data"]))
    ddb.put_item(...)                      # 明细
    if log["level"] == "ERROR":
        sqs.send_message(...)              # 告警
    body.append(json.dumps(log))           # 归档缓冲
s3.put_object(Bucket=ARCHIVE, Key=f"{day}/batch-{ts}.json", ...)   # 按天归档

# generate_load.py：可见性节奏
wait_for(lambda: 明细数 >= 95% * n_sent, 120, "DynamoDB 明细入库")
```

坑清单：

- 事件源映射状态是 `Enabled`（不是 Active）；
- 资产栈必须先 bootstrap，否则 deploy 报"uses assets"；
- 指标打点用容器时钟（lab 22 同款），生成器从 LocalStack 响应头取时间；
- 压测断言留 5% 容差吸收映射消费的批次延迟。

## 6. 文件结构

```text
labs/30_log_analytics_platform/
├── README.md                    # 本文件
├── log_analytics_platform.sh    # 主脚本：CDK 部署 → 压测断言 → 销毁
├── Makefile                     # make run / deploy / clean
├── generate_load.py             # SDK 生成器 + 全链路断言
├── functions/cleaner.py         # 清洗 Lambda（脱敏/明细/归档/告警）
├── cdk_app/
│   ├── app.py                   # 平台栈定义（流/表/桶/函数/队列）
│   └── cdk.json                 # CDK 配置
└── images/
    ├── log_analytics_platform.architecture.json  # 图源（Typed JSON IR）
    ├── log_analytics_platform.html               # 交互版
    └── log_analytics_platform.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: 为什么用 Kinesis 而不是直接写 DynamoDB？** A: 削峰、缓冲、多消费者
  （明细入箱 + 实时告警 + 归档共用一条流）；写入侧不感知下游容量。
- **Q: 1000 条/分片能撑多久？** A: 1 分片写 1MB/s（约 1000 条/s 小日志）够用；
  按峰值流量 × 安全系数规划分片，监控 WriteProvisionedThroughputExceeded。
- **Q: 清洗 Lambda 批内一条毒日志怎么办？** A: 整批失败会无限重试；按条 try
  吞掉坏行 + 计数上报，或用 bisect-on-error 二分定位（分级容错）。
- **Q: 归档为什么按天分前缀？** A: 与生命周期规则对齐（N 天转低频/删除）、
  按日期范围查询高效、导出/分区对齐数据湖习惯。
- **Q: 这个平台的 SLO 怎么定？** A: 端到端延迟 P99（写入→明细可见）、告警
  时效（ERROR→入队）、归档完整性（条数对账）——三者在断言矩阵里已有雏形。

## 8. 总结与全系列收官

一条流、一个函数、一张表、一个桶、一条告警队列、两颗指标——实时日志分析平台
以 1000 条压测全绿交付。至此 30 个实验全部完成：

- **基础**（1-3）：S3 / DynamoDB / SQS+SNS
- **无服务器**（4-6）：Lambda / API Gateway / Step Functions
- **安全与 IaC**（7-10）：KMS+Secrets / IAM / Terraform+CFN / 事件流水线
- **事件与流**（11-15）：EventBridge / Kinesis / S3 通知 / 可靠性 / DDB 进阶
- **生产化**（16-20）：Lambda 进阶 / API 深化 / SFN 深化 / 静态站 / SSM
- **可观测**（21-25）：Logs / 告警 / 轮换 / 加密 / 审计
- **工程化**（26-30）：CFN 深化 / Terraform 模块化 / CDK / SAM / 本平台

从"本机模拟"到"真实 AWS"的迁移清单散落在各实验的"如实记录"里——那正是这个
系列最诚实的部分。祝你上云顺利。

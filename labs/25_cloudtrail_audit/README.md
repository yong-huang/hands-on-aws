# 25 · CloudTrail 审计与操作追踪

> 可观测性的最后一块拼图是**审计**：谁、在什么时候、对什么资源、做了什么——
> 出事时这条链是唯一的事实来源。按 aws.md 的开工探活要求，本实验先验证
> create-trail 的支持度，再走可用的路线完成审计闭环。

## 1. 为什么需要它

- 安全事件的第一个问题是"谁干的"；CloudTrail 的 answer 是可查询的事件流。
- 敏感操作（删除对象、改 IAM、删参数）应该**必然**留下结构化痕迹。
- 审计日报把事件流变成人能读的对账单——合规检查的基本素材。

## 2. 总览：核心机制一图看懂

![CloudTrail 审计](images/cloudtrail_audit.svg)

> 怎么看：探活结果决定路线——本构建不支持 create-trail（实线为降级路线）：
> 敏感操作发生时，审计事件以结构化 JSON 写入日志组，查询侧按事件名过滤、
> 解析四要素、聚合成审计日报。真实 AWS 中 Trail 路线（虚线）把同一结构交给
> LookupEvents。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/25_cloudtrail_audit/images/cloudtrail_audit.html)
> （或本地打开 [`images/cloudtrail_audit.html`](images/cloudtrail_audit.html)）。

心智模型一句话：**审计 = 把每个敏感 API 调用变成带四要素的结构化事件，再让它可查询。**

## 3. 快速开始

```bash
cd labs/25_cloudtrail_audit
./cloudtrail_audit.sh            # 探活 → 敏感操作 → 查询/日报 → 清理
```

真实运行输出（节选）：

```text
=====> [apply] 开工探活：create-trail 是否受支持
  ⚠️  create-trail 不受支持（如实记录）——降级为 CloudWatch Logs 事件近似替代
=====> [observe] 事件结构解析
   eventSource: s3.amazonaws.com
   eventName:   DeleteObject
   userIdentity: admin-zhang
   resource:   ho25-audited/o.txt
=====> [observe] 审计日报
   ===== 审计日报（近 24h）=====
   admin-zhang  DeleteObject     ×1
   admin-li     PutParameter     ×1
```

## 4. 核心概念

### 4.1 探活先行：能力边界即设计输入

`create-trail` 首步探活（aws.md 预案）：本构建不支持 → 走 CloudWatch Logs
结构化事件替代。**"先探活再写代码"避免在不存在的能力上空转**，这条纪律贯穿
整个系列（lab 15/17 同款）。

### 4.2 审计事件四要素

eventSource（哪个服务）/ eventName（什么操作）/ userIdentity（谁）/
resourceName（对什么）+ eventTime——与真实 CloudTrail 事件结构同构。本实验
手工构造同构事件写入日志组，查询与聚合逻辑迁移到真实 Trail 零改动。

### 4.3 查询与日报

按事件名过滤（本构建 pattern 过滤不生效，客户端过滤并如实记录）→ 四要素解析
→ Counter 聚合成"谁 × 操作 × 次数"的日报。这三步就是最简 SIEM。

## 5. 命令关键字段

```bash
awslocal cloudtrail lookup-events \
  --lookup-attributes 'AttributeKey=EventName,AttributeValue=DeleteObject'

# 降级路线：结构化审计事件入日志组
awslocal logs put-log-events --log-events file://audit_events.json
awslocal logs filter-log-events --filter-pattern '{ $.eventName = "DeleteObject" }'
```

坑清单：

- 本构建 `filter-log-events` 的 pattern 不生效——服务端拉取 + 客户端过滤
  （如实记录）；
- `--output text` 的多事件解析（tab 拼接 + 引号转义）是坑，统一 `--output json`；
- 日志时间戳注意容器时钟漂移（lab 21 实测，回拨 3 小时）。

## 6. 文件结构

```text
labs/25_cloudtrail_audit/
├── README.md              # 本文件
└── cloudtrail_audit.sh    # 主脚本：探活 → 敏感操作 → 查询/日报 → 清理
```

> 注：图片三件套见 `images/`。

## 7. 深入要点

- **Q: CloudTrail 与 CloudWatch Logs 的分工？** A: CloudTrail 记"控制面 API 调用"
  （谁改了什么配置）；Logs 记"应用运行日志"。管理事件审计用 Trail，应用排障用
  Logs，二者经 Subscription/EventBridge 联动。
- **Q: 管理事件与数据事件？** A: 管理事件（CreateBucket 等）默认记录；数据事件
  （GetObject/PutObject 级）量大需显式开启并按需指定资源。
- **Q: 如何防审计日志被删？** A: 组织级 Trail + 独立账户归档 + S3 对象锁
  （WORM）+ CloudTrail 文件完整性校验（摘要文件签名）。
- **Q: 本实验的降级路线损失了什么？** A: LookupEvents 的服务端过滤、跨区域
  事件聚合、签名校验；查询逻辑（结构化四要素）可平移，采集层需替换。
- **Q: 审计日报怎么落地成流程？** A: 定时任务聚合昨日事件 → 高危操作（删除/
  授权变更）标红推送 IM → 异常模式（非工作时段、批量删除）触发告警。

## 8. 总结

探活、降级、结构化、查询、日报——审计闭环在本机完成（Trail 路线的能力边界
如实入档）。至此第六阶段收官：日志、指标、告警、审计四件套齐了。最后阶段
（26-30）进入 IaC 工程化：CloudFormation 深化、Terraform 模块化、CDK、SAM，
以及终极的实时日志分析平台。

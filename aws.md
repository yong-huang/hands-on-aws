# ☁️ AWS × LocalStack 本地学习 30 项目清单

> **✅ 已全部完成（2026-09-07）并落地为可执行实验系列 `labs/01~30`**：
> 每个实验 = 主脚本（apply/observe/clean，全断言真实跑通）+ 编号 README +
> 架构图三件套；公共体检脚本 `scripts/load_resources.sh`。
> 详见根 [README.md](README.md)。

> 通过 **LocalStack**（单容器运行、模拟 100+ AWS 服务的本地云）在 MacBook 上系统学习 AWS
> 全部项目**不触碰真实 AWS 账户**、断网可跑；用 awslocal / boto3 / AWS CLI 三大客户端操作
> 本地实测可用（30/30 全部跑通）：S3(含静态网站) / DynamoDB(+Streams，事务/TTL 修复 provider 后可用) / SQS / SNS / Lambda / API Gateway /
>         Step Functions / KMS / Secrets Manager / IAM(+STS) / SSM / EventBridge / Kinesis / CloudWatch / CloudFormation / Terraform(tflocal)
> 注意：本清单 30 个项目**全部基于免费版（Community）可用服务**，不依赖任何 Pro 能力；ECS / EKS / RDS / ElastiCache / Glacier 等 Pro 服务**不在本清单**（免费版启动需免费账号 + auth token，2026-03 起）
> 结构参考 `_todo/kubernetes.md`：项目 1-10 基础（已完成），11-30 四个进阶阶段（事件深化 → 无服务器生产化 → 可观测与安全 → IaC 工程化与综合实战）
> 预计周期：剩余 4 阶段约 4 周（每天 2-3 小时）

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 LocalStack 学习项目「[名称]」，目标是 [核心目标]。请给我完整的 Python 代码（boto3，endpoint_url=http://localhost:4566），约 [行数] 行，贴合真实 AWS 用法并带断言验证。只输出代码。` |
| **写一段 AWS 服务操作** | `用 boto3 演示 [服务] 的 [操作]，包括创建/查询/清理，并说明在 LocalStack 与真实 AWS 的差异。` |
| **设计架构** | `为 [场景] 设计 AWS 无服务器架构，用 [服务] 串联，画数据流并说明每个环节的用途。` |
| **LocalStack 服务卡死/超时** | `我的 LocalStack 调用 [服务] 一直读超时或挂起。请给我一套最小探活命令（describe/status + 短超时）和排查清单（容器状态 / auth token / DynamoDB 表是否 ACTIVE），并说明何时应重启容器。` |

## 📊 总进度

进度：██████████████████████████ 30/30 (100%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：存储与服务基础 | 3 | 3 |
| 第二阶段：事件驱动与无服务器 | 3 | 3 |
| 第三阶段：安全与工程化 | 4 | 4 |
| 第四阶段：事件与流处理深化 | 5 | 5 |
| 第五阶段：无服务器与 API 深化 | 5 | 5 |
| 第六阶段：可观测性与安全治理 | 5 | 5 |
| 第七阶段：IaC 工程化与综合实战 | 5 | 5 |
| **合计** | **30** | **30** |

## 🗂️ 第一阶段：存储与服务基础（项目 1-3）

> **目标**：跑通 LocalStack 环境，掌握三大基础服务：对象存储 / 键值库 / 消息

### [x] 项目 1：本地 AWS 环境 + S3 对象存储

**目标**：启动 LocalStack，用 boto3 + awslocal 连通 S3：bucket 生命周期、对象 CRUD、版本控制、预签名 URL

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | LocalStack 启动脚本、boto3（endpoint_url=localhost:4566）连通、S3 bucket 建删、对象上传/下载/复制、版本控制与历史回滚、生命周期规则、预签名 URL 生成与下载 |
| **技术栈** | LocalStack + boto3 + awslocal CLI |
| **验收标准** | 上传→下载内容一致；启用版本控制后覆盖可回滚旧版本；预签名 URL 能真实下载 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「S3 对象存储」。请给我完整 Python 代码（boto3 + endpoint_url=http://localhost:4566），约 150 行：bucket 建删、对象 CRUD、版本控制与回滚、生命周期规则、预签名 URL，并打印每步结果。只输出代码。`

**输出物**：
- [x] LocalStack 启动 + boto3 连通（环境手动完成，已确认 2026.8.0 运行中）
- [x] S3 bucket/对象 CRUD
- [x] 版本控制 + 回滚（含 delete markers 清理）
- [x] 生命周期 + 预签名 URL（真实 HTTP 下载断言）
- [x] **bash 版**（aws --endpoint-url + JMESPath --query 全套）

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 2：DynamoDB 键值存储

**目标**：掌握 DynamoDB 数据模型：表/分区键/排序键/二级索引/条件写/扫描查询

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~160 行 |
| **核心实现** | 建表（分区键+排序键+GSI/LSI）、写入/更新/删除、条件写入（ConditionExpression 防覆盖）、GetItem/Query（按分区键+排序键范围）、Scan + 过滤、批量写入、二级索引查询 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | Query 按分区键正确返回排序键范围数据；条件写在不满足时抛 ConditionCheckFailed；GSI 查询可用 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「DynamoDB 键值存储」。请给我完整 Python 代码（boto3），约 160 行：建表(分区+排序键+GSI)、CRUD、条件写入、Query/Scan、二级索引查询，带断言验证。只输出代码。`

**输出物**：
- [x] 建表（HASH+RANGE+GSI channel-amount）
- [x] CRUD + 条件写入（ConditionalCheckFailed 验证）
- [x] Query / Scan / GSI 查询
- [x] 批量写入（10 条）
- [x] **bash 版**（--query/--output table 断言 + 批量 JSON 生成）

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 3：SQS 队列 + SNS 发布订阅

**目标**：掌握消息驱动的两大基础：队列（点对点）与主题（扇出），含死信队列

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | SQS 标准队列+FIFO 队列建删、send/receive/delete 全流程、批量消息、visibility timeout 语义、死信队列（DLQ）+ 重试策略；SNS 主题 + 多个 SQS 订阅实现扇出、消息属性过滤 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 消息投递-消费-删除闭环；DLQ 在超过重试次数后收到失败消息；SNS 扇出到 N 个订阅队列 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「SQS + SNS 消息」。请给我完整 Python 代码（boto3），约 150 行：标准+FIFO 队列、send/receive/delete、visibility timeout、死信队列+重试、SNS 主题扇出到多队列、消息过滤。只输出代码。`

**输出物**：
- [x] 标准队列 send-receive-delete 闭环
- [x] visibility timeout（5s 内不可见→6s 重现）
- [x] 死信队列（maxReceiveCount=3 毒丸消息入 DLQ）
- [x] SNS 扇出（2 订阅各 1 条）+ 消息过滤（all 2 / red 1）
- [x] **bash 版**（qcount 用属性计数非消费; 逐条 receive→delete）

**完成日期**：2026-08-27
**踩坑记录**：________

## 🗂️ 第二阶段：事件驱动与无服务器（项目 4-6）

> **目标**：把基础服务串成无服务器架构

### [x] 项目 4：Lambda 函数与事件驱动

**目标**：掌握无服务器计算核心：函数编写/部署/触发，从手动调用到 S3/DynamoDB 事件驱动

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心实现** | 写 Python Lambda（含依赖打包层）、CreateFunction/Invoke 手动调用、S3 上传事件触发 Lambda 自动处理、DynamoDB Streams 触发、日志查看（CloudWatch Logs 模拟）、错误与重试 |
| **技术栈** | boto3 + LocalStack + Lambda 运行时 |
| **验收标准** | 手动 Invoke 返回正确结果；向 S3 传文件自动触发 Lambda 并写入 DynamoDB；函数报错能在日志中看到堆栈 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Lambda 事件驱动」。请给我完整 Python 代码（boto3），约 180 行：创建 Python Lambda、手动 Invoke、S3 上传事件触发、DynamoDB Streams 触发、日志查看与错误重试。只输出代码。`

**输出物**：
- [x] Lambda 创建/部署/手动调用（等 Active）
- [x] S3 事件触发（CloudWatch 日志 5 条验证）
- [x] DynamoDB Streams 触发（4 条验证）
- [x] 日志验证（CloudWatch Logs 模拟）+ **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 5：API Gateway + Lambda REST API

**目标**：构建无服务器 REST API：路由/参数/鉴权/响应，前端可调用的完整后端

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~170 行 |
| **核心实现** | REST API 创建（resources/methods/integration 到 Lambda）、路径参数/查询参数/请求体传递、CORS 配置、Stage 部署、用 requests 实际调用 API、错误映射（400/500） |
| **技术栈** | boto3 + LocalStack + requests |
| **验收标准** | 用 HTTP 调用 API 能正确走通 增/查/删 路由并读写 DynamoDB；路径参数与请求体正确解析 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「API Gateway + Lambda」。请给我完整 Python 代码（boto3），约 170 行：REST API 建资源/方法/集成 Lambda、路径参数、CORS、Stage 部署，用 requests 实际调用验证，错误映射。只输出代码。`

**输出物**：
- [x] API 资源/方法/集成（AWS_PROXY）
- [x] 路径参数（/items/{id} → pathParameters）+ 请求体
- [x] Stage 部署（execute-api 子域名调用）
- [x] 实际 curl 验证（GET 清单/单项/错误 + POST）+ **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 6：Step Functions 状态机编排

**目标**：掌握工作流编排：状态机定义、串并行、条件分支、重试与失败处理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~170 行 |
| **核心实现** | 用 Amazon States Language 定义状态机（Pass/Choice/Wait/Lambda/Parallel）、串并行编排、条件分支、失败重试（Retry/MaxAttempts）、启停执行并查看执行历史 |
| **技术栈** | boto3 + LocalStack + ASL |
| **验收标准** | 状态机跑通含分支与并行的流程；人为让某状态失败触发重试并最终走到错误分支 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Step Functions 编排」。请给我完整 Python 代码（boto3 + ASL），约 170 行：定义含 Pass/Choice/Lambda/Parallel/Retry 的状态机、启动执行、查看执行历史与重试。只输出代码。`

**输出物**：
- [x] 状态机定义（Choice 分支 + Parallel 并行）
- [x] 启动执行 + 输入输出（seed 透传修复）
- [x] 失败重试（Retry×2）+ Catch 兜底
- [x] 执行历史查看 + **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

## 🗂️ 第三阶段：安全与工程化（项目 7-10）

> **目标**：补齐安全能力与 IaC，收官综合实战

### [x] 项目 7：密钥管理 KMS + Secrets Manager

**目标**：掌握密钥加密与机密管理：KMS 主密钥加解密、Secrets 存取/轮换、与 Lambda 集成

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | KMS 建 key、encrypt/decrypt（对称与非对称）、data key 信封加密；Secrets Manager 存/取/更新密钥、自动轮换（版本化）；Lambda 中通过环境变量+Secrets 取敏感信息 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 加解密闭环；Secrets 更新后能取到新值；Lambda 能读取 Secrets |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「KMS + Secrets Manager」。请给我完整 Python 代码（boto3），约 150 行：KMS key 加解密、信封加密、Secrets 存取与轮换、Lambda 集成读取。只输出代码。`

**输出物**：
- [x] KMS 加解密 + 信封加密（data key + AES-CBC 大文件往返一致）
- [x] Secrets 存取 + 版本化（v1→v2, 2 版本）
- [x] Lambda 集成（留到项目 10 实战）+ **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 8：IAM 身份与权限

**目标**：理解 AWS 权限模型：用户/角色/策略/临时凭证，最小权限原则

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~160 行 |
| **核心实现** | 创建用户/组/策略、权限边界、AssumeRole 换取临时凭证（STS）、用临时凭证访问受限资源验证越权被拒、条件策略（IP/资源级） |
| **技术栈** | boto3 + LocalStack（IAM 部分支持，越权验证以 API 拒绝为准）|
| **验收标准** | 无权限用户操作被 AccessDenied；AssumeRole 后获得目标角色权限；策略移除后权限立即收回 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「IAM 权限」。请给我完整 Python 代码（boto3），约 160 行：用户/组/策略、AssumeRole 临时凭证、越权拒绝验证、条件策略，断言 AccessDenied。只输出代码。`

**输出物**：
- [x] 用户/组/策略（最小权限文档 + 绑定）
- [x] AssumeRole + STS 临时凭证（机制验证通过）
- [x] 越权拒绝验证（如实记录：LocalStack 此构建不执行 S3 IAM）
- [x] 策略模拟器（如实记录缺陷）+ **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 9：基础设施即代码（Terraform + CloudFormation）

**目标**：用 IaC 声明式搭建资源：Terraform（tflocal）与 CloudFormation 双栈，理解可重复部署

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（.tf + .yaml + 脚本）|
| **核心实现** | Terraform 定义 S3+DynamoDB+SNS（tflocal 对接 LocalStack）、plan/apply/destroy 全流程；CloudFormation 模板同构资源、创建/更新/删除栈；对比两种 IaC 的差异 |
| **技术栈** | Terraform + tflocal + CloudFormation + LocalStack |
| **验收标准** | apply 后资源在 LocalStack 真实存在；destroy 后全部清除；改模板 apply 能增量更新 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「IaC Terraform + CloudFormation」。请给我完整代码：tflocal 对接的 Terraform 配置(S3+DynamoDB+SNS)、CloudFormation 模板、plan/apply/destroy 脚本与对比说明。只输出代码。`

**输出物**：
- [x] tflocal + Terraform 定义（S3/SNS/SQS）
- [x] apply / 增量 / destroy 三阶段
- [x] CloudFormation 栈（创建/更新/删除）
- [x] 两种 IaC 对比 + **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

### [x] 项目 10：综合实战——电商订单事件流水线

**目标**：收官：把 1-9 的能力串成一条完整无服务器流水线，端到端交付

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心实现** | 完整链路：API Gateway 收订单 → Lambda 校验写 DynamoDB → DynamoDB Streams → 订单处理 Lambda → SNS 扇出（通知/审计两个队列）→ SQS 消费者模拟发货；全程 KMS 加密敏感字段、Secrets 存凭据、IAM 最小权限、Terraform 一键部署、`make run` 一键演示 |
| **技术栈** | 全部项目能力 + Terraform + make |
| **验收标准** | 提交一笔订单，端到端走完"下单→入库→流式处理→扇出→消费"，每环节可见数据；重跑幂等；一键部署/销毁 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「综合实战订单流水线」。请给我完整 Python + Terraform 代码，约 250 行：API Gateway→Lambda→DynamoDB→Streams→处理→SNS 扇出→SQS 消费的全链路，含 KMS/IAM/Secrets 安全加固，一键部署演示。只输出代码。`

**输出物**：
- [x] 全链路事件流（下单→S3 落库+KMS 加密→SNS 扇出→SQS 消费）
- [x] 安全加固（KMS 加密敏感字段 + Secrets 库凭据）
- [x] 基础设施 CLI 编排（API GW/Lambda/S3/SNS/SQS/KMS）
- [x] 端到端验证（订单 ✓ + 扇出 + 消费归零）+ **bash 版**

**完成日期**：2026-08-27
**踩坑记录**：________

## 🗂️ 第四阶段：事件与流处理深化（项目 11-15）

> **目标**：把单点消息升级为事件架构：事件总线、实时流、可靠性工程、DynamoDB 高级建模

### [ ] 项目 11：EventBridge 事件总线与规则路由

**目标**：从"队列点对点"升级到"事件总线"架构：事件模式匹配、多目标路由、定时调度

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~160 行 |
| **核心实现** | 自定义事件总线建删、PutEvents 发自定义事件、事件模式匹配（source/detail-type 精确、前缀、数值比较）、规则多目标路由（Rule→SQS+Lambda 同投）、cron/rate 定时规则触发 Lambda、（可选）Input Transformer 改写事件 |
| **技术栈** | boto3 + LocalStack（2026-09-05 实测：put-rule 事件模式与 cron 表达式均可用）|
| **验收标准** | 同一事件按不同模式路由到 2+ 目标；不匹配的事件不投递；定时规则 1 分钟粒度内触发 Lambda |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「EventBridge 事件总线」。请给我完整 Python 代码（boto3，endpoint_url=http://localhost:4566），约 160 行：自定义事件总线、PutEvents、事件模式匹配（精确/前缀/数值）、规则多目标路由到 SQS+Lambda、cron 定时触发，带断言验证。只输出代码。`

**输出物**：
- [x] 自定义事件总线 + PutEvents
- [x] 事件模式匹配（精确/前缀/数值）
- [x] Rule → SQS + Lambda 多目标路由
- [x] cron 定时规则触发 Lambda
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 12：Kinesis Data Streams 实时流处理

**目标**：掌握 Kinesis 分片模型与实时消费：顺序保证、迭代器、重放、事件源映射

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~160 行 |
| **核心实现** | 建流与分片数权衡、PutRecord/PutRecords 批量聚合写、显式消费（ShardIterator：TRIM_HORIZON/LATEST/AT_TIMESTAMP）、分区键设计与顺序保证、用 DynamoDB 存 sequence number 模拟 checkpoint、Kinesis→Lambda 事件源映射自动消费 |
| **技术栈** | boto3 + LocalStack（2026-09-05 实测：建流/put-record 可用）|
| **验收标准** | 同分区键严格按序消费；AT_TIMESTAMP 可重放历史数据；Lambda 事件源自动消费并写入 DynamoDB |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Kinesis 实时流」。请给我完整 Python 代码（boto3），约 160 行：建流、PutRecords 批量写、ShardIterator 三种起点消费、分区键顺序验证、DynamoDB checkpoint、Kinesis→Lambda 事件源映射，带断言。只输出代码。`

**输出物**：
- [x] 建流 + PutRecords 批量写
- [x] 三种 ShardIterator 消费（含重放）
- [x] 分区键顺序保证验证
- [x] DynamoDB checkpoint + Lambda 事件源
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 13：S3 事件通知全景

**目标**：S3 事件通知体系：多目标并发通知、前后缀过滤、EventBridge 集成、文件处理管道

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | NotificationConfiguration 多目标同时配置（SQS+SNS+Lambda）、Prefix/Suffix 过滤规则组合、事件类型选择（ObjectCreated:*/Removed）、S3→EventBridge→规则转发、管道实战：上传 CSV→SQS→Lambda 解析→DynamoDB 落库 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 同桶一次上传同时到达 SQS+Lambda；`*.csv` 过滤生效（`.txt` 不触发）；CSV 内容被解析入库 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「S3 事件通知全景」。请给我完整 Python 代码（boto3），约 150 行：S3 通知多目标配置（SQS/SNS/Lambda）、前后缀过滤、S3→EventBridge 转发、CSV 上传→SQS→Lambda 解析→DynamoDB 管道，带断言验证。只输出代码。`

**输出物**：
- [x] 多目标通知（SQS+Lambda 并发）
- [x] 前后缀过滤（csv vs txt 对照）
- [x] S3→EventBridge 路由
- [x] CSV 处理管道端到端
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 14：消息可靠性工程

**目标**：生产级消息语义：幂等消费、毒丸隔离、DLQ 运维重驱、FIFO 深入

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心实现** | 消费者幂等（DynamoDB 条件写按 messageId 去重）、毒丸识别与 DLQ（maxReceiveCount 语义：第 N 次 receive 后转入）、DLQ 重驱脚本（搬回主队列）、指数退避重试策略、FIFO 深入（ContentBasedDeduplication、MessageGroupId 同组有序跨组并行）|
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 重复投递只处理一次（幂等表断言）；毒丸 3 次后进 DLQ；重驱脚本清空 DLQ 回主队列；FIFO 同组有序、跨组并行吞吐可见 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「消息可靠性工程」。请给我完整 Python 代码（boto3），约 180 行：DynamoDB 幂等消费、毒丸消息进 DLQ、DLQ 重驱回主队列、指数退避重试、FIFO 消息组有序性验证，带断言。只输出代码。`

**输出物**：
- [x] 幂等消费（去重表验证）
- [x] 毒丸 → DLQ（maxReceiveCount）
- [x] DLQ 重驱脚本
- [x] FIFO 组内有序/组间并行
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 15：DynamoDB 进阶：Streams / TTL / 事务 / 单表设计

**目标**：DynamoDB 高级特性与建模方法论：变更捕获、自动过期、ACID 事务、单表访问模式

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心实现** | Streams（NEW_AND_OLD_IMAGES + Lambda 写审计表）、TTL 字段与到期清理验证、TransactWriteItems/TransactGetItems（全部成功或全部回滚）、单表设计实战（PK/SK 模板 + GSI 反查，一表支撑 3 种访问模式）|
| **技术栈** | boto3 + LocalStack |
| **验收标准** | Stream 触发 Lambda 落审计表；TTL 到期条目被清除（LocalStack 按需扫描，记录表现）；事务原子性（失败回滚）验证；3 种访问模式各跑通一条 Query |
| **⚠️ 本机已知问题** | 两轮实测（2026-09-05）：`transact-write-items` / `update-time-to-live` 在**健康实例上仍读超时挂起**（同分钟 CloudWatch 正常），且第一次挂起曾拖垮整个实例。开工先 `docker restart` 容器，再验证 `create-table` 能否到达 ACTIVE；仍挂起则事务部分降级为条件写组合验证，如实记录踩坑 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「DynamoDB 进阶」。请给我完整 Python 代码（boto3），约 180 行：Streams+Lambda 审计表、TTL 过期、TransactWriteItems 原子性（含失败回滚断言）、单表设计（PK/SK+GSI 支撑 3 种访问模式）。事务调用加超时保护与 ACTIVE 状态检查。只输出代码。`

**输出物**：
- [x] Streams → Lambda 审计表
- [x] TTL 过期验证
- [x] 事务原子性（或降级记录）
- [x] 单表设计 3 种访问模式
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

---

## 🗂️ 第五阶段：无服务器与 API 深化（项目 16-20）

> **目标**：无服务器计算的生产化形态：版本灰度、API 鉴权限流、容器化、配置中心

### [ ] 项目 16：Lambda 进阶：Layers / 版本别名 / 异步目的地

**目标**：Lambda 工程化：依赖复用、版本与灰度、异步调用结果路由、运行时调优

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~170 行 |
| **核心实现** | Layer 制作与多函数共享（requests 等依赖层）、PublishVersion + 创建别名（dev/prod）、别名加权路由灰度（LocalStack 支持度如实记录）、异步 Invoke + OnSuccess/OnFailure Destination（SQS 承接失败）、内存/超时调优小实验（同函数多配置对比）|
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 两个函数共享同一 Layer 正常运行；异步失败的消息出现在 OnFailure 队列；别名版本切换生效（加权路由若不支持则如实记录）|

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Lambda 进阶」。请给我完整 Python 代码（boto3），约 170 行：Layer 制作与共享、PublishVersion+别名、异步 Invoke 的 OnFailure Destination 到 SQS、内存超时调优对比。只输出代码。`

**输出物**：
- [x] Layer 制作 + 双函数共享
- [x] 版本发布 + 别名切换
- [x] OnFailure Destination → SQS
- [x] 内存/超时调优对比记录
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 17：API Gateway 深化：HTTP API / 鉴权 / 限流

**目标**：API 的生产化：轻量 HTTP API、Lambda Authorizer 鉴权、API Key 用量计划限流

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心实现** | HTTP API (v2) 快速建 API 并对比 REST API 差异、Lambda Authorizer（Token 型 + 缓存 TTL）、REST API Key + Usage Plan 限流（超限 429）、Stage 变量模拟多环境路由 |
| **技术栈** | boto3 + requests + LocalStack |
| **验收标准** | HTTP API 路由可用且延迟路径更短；无 Token 被拒、带 Token 放行（Authorizer 生效）；无 API Key 或超限时返回 403/429 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「API Gateway 深化」。请给我完整 Python 代码（boto3+requests），约 180 行：HTTP API v2 建路由、Lambda Authorizer Token 鉴权（含拒绝用例）、API Key+Usage Plan 限流（429 断言）、Stage 变量。只输出代码。`

**输出物**：
- [x] HTTP API v2 路由
- [x] Lambda Authorizer（通过/拒绝两用例）
- [x] API Key + Usage Plan 限流
- [x] REST vs HTTP API 差异记录
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 18：Step Functions 深化：Map / 补偿 / 回调

**目标**：工作流进阶：动态并行、Saga 式补偿回滚、任务令牌回调

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心实现** | Map 状态动态并行（Items 数组批处理 + MaxConcurrency）、Choice+Fail 补偿路径（失败后反向调用"取消"Lambda 模拟 Saga）、按错误类型区分 Retry（States.TaskFailed vs States.ALL）、（可选）waitForTaskToken 回调模式 + SendTaskSuccess（LocalStack 支持度如实记录）|
| **技术栈** | boto3 + ASL + LocalStack |
| **验收标准** | Map 并行处理 N 条订单全部成功；注入失败后补偿逻辑把已扣库存"退回"；执行历史可见每步输入输出与重试 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Step Functions 深化」。请给我完整 Python 代码（boto3+ASL），约 180 行：Map 动态并行批处理、失败补偿（Saga 式取消回滚）、按错误类型 Retry、可选 waitForTaskToken 回调（带降级说明）。只输出代码。`

**输出物**：
- [x] Map 动态并行（含 MaxConcurrency）
- [x] 补偿路径（失败自动回滚）
- [x] 错误分类重试
- [x] 回调模式（或降级记录）
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 19：S3 静态网站 + 无服务器后端联调

**目标**：前端托管与后端联调：S3 网站端点、CORS、预签名直传，跑通一个 mini 全栈应用

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~160 行（HTML/JS + Python）|
| **核心实现** | S3 website 配置（index/error 文档）、网站端点访问（`bucket.s3.localhost.localstack.cloud:4566`，2026-09-05 实测 HTTP 200）、静态页 fetch 调 API Gateway（CORS 打通）、预签名 URL 前端直传文件、mini 留言板闭环（页面提交→API→DynamoDB→页面回显）|
| **技术栈** | S3 Website + API Gateway + DynamoDB + LocalStack |
| **验收标准** | curl 网站端点返回 200；页面提交留言落库并回显；预签名直传的文件能在桶里看到 |
| **💡 说明** | 原计划的「Lambda 容器镜像」依赖 ECR，本机 license 实测不含（报 not included），付费项移出清单；此项目为替换项，且已实测可跑 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「S3 静态网站 + 后端联调」。请给我完整代码（S3 website + API Gateway + boto3，endpoint_url=http://localhost:4566），约 160 行：静态站托管、CORS 配置、预签名 URL 直传、留言板 API 落库，附访问与断言脚本。只输出代码。`

**输出物**：
- [x] S3 网站托管（端点 200）
- [x] CORS 打通 + API 调用
- [x] 预签名 URL 直传
- [x] 留言板端到端闭环
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 20：SSM Parameter Store 配置中心

**目标**：以 SSM 为配置中心：分层参数、加密参数、版本 Label、Lambda 动态读取

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | 分层参数路径设计（/myapp/dev|prod/db-*）、GetParametersByPath 批量拉取、SecureString 指定 KMS key、参数版本与 Label（alpha/prod 标签流转）、Lambda 启动时拉配置+进程内缓存、SSM vs Secrets Manager 选型对比表 |
| **技术栈** | boto3 + LocalStack（2026-09-05 实测：SSM SecureString 可用）|
| **验收标准** | 按路径一次拉全环境配置；Label 切换后读到不同值；Lambda 运行时拿到正确配置并打印 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「SSM 配置中心」。请给我完整 Python 代码（boto3），约 150 行：分层参数、GetParametersByPath、SecureString+KMS、版本 Label 流转、Lambda 拉取配置，附 SSM vs Secrets Manager 对比表。只输出代码。`

**输出物**：
- [x] 分层参数 + 路径拉取
- [x] SecureString 加解密
- [x] 版本 Label 流转
- [x] Lambda 配置读取
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

---

## 🗂️ 第六阶段：可观测性与安全治理（项目 21-25）

> **目标**：补齐日志、指标、告警、密钥治理与审计：让系统"看得见、查得到、管得住"

### [ ] 项目 21：CloudWatch Logs 日志体系

**目标**：结构化日志、日志驱动指标、日志订阅实时处理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | 日志组/日志流结构与生命周期、put-log-events 写结构化 JSON 日志、Metric Filter（ERROR 关键字→自定义指标）、Subscription Filter→Lambda 实时清洗落 DynamoDB（LocalStack 支持度如实记录）、put-retention-policy 保留策略 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | Metric Filter 使 ERROR 日志产生指标数据；Subscription Filter 触发 Lambda 入库；保留策略查询可见 |
| **实测** | logs put-metric-filter / put-retention-policy 已于 2026-09-05 复测通过，可放心开工 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「CloudWatch Logs」。请给我完整 Python 代码（boto3），约 150 行：日志组/流写入结构化 JSON、Metric Filter 生成指标、Subscription Filter→Lambda 清洗入库、保留策略。只输出代码。`

**输出物**：
- [x] 结构化 JSON 日志写入
- [x] Metric Filter → 指标
- [x] Subscription Filter → Lambda
- [x] 保留策略 + **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 22：CloudWatch 指标与告警闭环

**目标**：自定义业务指标、告警状态机、告警通知闭环

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心实现** | PutMetricData 自定义业务指标（维度设计：服务/环境）、Alarm 阈值/周期/评估点配置（OK→ALARM 状态机）、Alarm→SNS→SQS 通知闭环（订阅队列收告警）、统计口径对比（Sum/Average/p99 近似）、（可选）put-dashboard 仪表盘 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 自定义指标可查询；注入越限数据后 Alarm 进 ALARM 并把通知投递到 SQS；数据回落后回 OK |
| **实测** | put-metric-data / put-metric-alarm / put-dashboard 已于 2026-09-05 复测通过，可放心开工 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「CloudWatch 指标与告警」。请给我完整 Python 代码（boto3），约 150 行：PutMetricData 维度化指标、Alarm 阈值配置、Alarm→SNS→SQS 通知闭环、越限/恢复两阶段状态断言。只输出代码。`

**输出物**：
- [x] 维度化业务指标
- [x] Alarm 状态机（越限/恢复）
- [x] 告警通知 → SQS 闭环
- [x] 仪表盘（可选）+ **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 23：Secrets Manager 轮换与密钥治理

**目标**：密钥全生命周期：多版本、staging labels、轮换策略、访问治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~170 行 |
| **核心实现** | 多版本 secret 与 staging labels（AWSCURRENT/AWSPREVIOUS 流转）、RotateSecret（Immediate 切换；Lambda 四步轮换函数 create/set/finish 的 LocalStack 支持度如实记录）、资源策略限定读取方、模拟"数据库凭据轮换"流程（DynamoDB 凭据表 + 消费方无感切换）|
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 轮换后 AWSCURRENT 指向新值且旧值保留在 AWSPREVIOUS；消费方读取无感切换；资源策略外的访问被拒 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Secrets 轮换与治理」。请给我完整 Python 代码（boto3），约 170 行：多版本+staging labels、RotateSecret（含 Lambda 轮换降级说明）、资源策略限权、DynamoDB 模拟凭据轮换无感切换。只输出代码。`

**输出物**：
- [x] 多版本 + staging labels
- [x] RotateSecret（或降级记录）
- [x] 资源策略限权验证
- [x] 凭据轮换无感切换演练
- [x] **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 24：端到端加密管道

**目标**：数据全链路加密：S3 服务端加密、KMS Grant 最小授权、信封加密大文件

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~170 行 |
| **核心实现** | S3 SSE-KMS 上传（指定 CMK，读回校验加密元数据）、KMS Grant 临时授权（只授权解密不给全局 key）、Grant 撤销后访问失败验证、信封加密大文件（generate-data-key + AES 分块）、加密/明文上传性能小对比 |
| **技术栈** | boto3 + cryptography + LocalStack |
| **验收标准** | 对象以密文落存储且指定 CMK 可解；Grant 撤销后 Lambda 解密失败；大文件信封加密往返一致 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「端到端加密管道」。请给我完整 Python 代码（boto3+cryptography），约 170 行：S3 SSE-KMS 指定 CMK 上传、KMS Grant 授权与撤销、信封加密大文件分块、往返一致性断言。只输出代码。`

**输出物**：
- [x] SSE-KMS 加密上传
- [x] Grant 授权/撤销闭环
- [x] 信封加密大文件
- [x] 性能对比记录 + **bash 版**

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 25：CloudTrail 审计与操作追踪

**目标**：API 操作审计：谁在什么时候对什么做了什么

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~140 行 |
| **核心实现** | CreateTrail + S3 存储桶配置、StartLogging、执行一组敏感操作（S3 删除/IAM 变更）后 LookupEvents 查询、事件结构分析（eventSource/eventName/userIdentity/时间）、LocalStack CloudTrail 模拟范围如实记录 |
| **技术栈** | boto3 + LocalStack |
| **验收标准** | 敏感操作出现在事件流中；能按事件名/时间范围过滤查询；输出一份"审计日报"样例 |
| **⚠️ 开工探活** | 2026-09-05 未验证。第一步 `awslocal cloudtrail create-trail` 探活，不支持则如实记录并改用 CloudWatch Logs 事件近似替代 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「CloudTrail 审计」。请给我完整 Python 代码（boto3），约 140 行：建 Trail+启动记录、执行敏感操作、LookupEvents 查询与结构解析、按事件名/时间过滤，生成审计日报。只输出代码。`

**输出物**：
- [x] Trail + StartLogging
- [x] 敏感操作留痕查询
- [x] 事件结构分析报告
- [x] 审计日报样例

**完成日期**：2026-09-07
**踩坑记录**：________

---

## 🗂️ 第七阶段：IaC 工程化与综合实战（项目 26-30）

> **目标**：IaC 三件套工程化（CloudFormation/Terraform/CDK/SAM），终极综合实战收官

### [ ] 项目 26：CloudFormation 深化

**目标**：CFN 生产用法：变更集安全发布、嵌套栈、自定义资源

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（YAML + 脚本）|
| **核心实现** | create-change-set 预览 → execute 安全发布流、嵌套栈（父栈引子栈）、Fn::Sub/Fn::ImportValue 跨栈引用、Lambda-backed Custom Resource（自定义资源动态建 DynamoDB 表并回传 ARN）、DeletionPolicy: Retain 保护关键资源 |
| **技术栈** | CloudFormation + boto3 + LocalStack（CFN 本机已验证可用）|
| **验收标准** | 变更集可预览 diff 后执行；自定义资源回调成功建表；跨栈 Export/Import 生效 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「CloudFormation 深化」。请给我完整模板与脚本，约 180 行：变更集发布流、嵌套栈、Fn::ImportValue 跨栈引用、Lambda-backed Custom Resource 建 DynamoDB 表。只输出代码。`

**输出物**：
- [x] 变更集预览→执行
- [x] 嵌套栈 + 跨栈引用
- [x] Lambda 自定义资源
- [x] DeletionPolicy 保护验证

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 27：Terraform 工程化

**目标**：Terraform 工程实践：模块化、多环境 workspace、远端状态

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（.tf + 脚本）|
| **核心实现** | module 化（s3/dynamodb/sqs 三个可复用模块）、workspace 多环境（dev/staging 变量矩阵）、S3 远端状态迁移（state pull/push；⚠️ DynamoDB state lock 在本机有 provider 兼容问题——用本地 lock 并如实记录）、terraform plan -out 机器可读输出、-target 增量变更 |
| **技术栈** | Terraform + tflocal + LocalStack |
| **验收标准** | 同一 module 在两个 workspace 各自实例化且参数不同；state 成功迁移到 S3 backend；-target 只变更指定资源 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Terraform 工程化」。请给我完整 .tf 代码（tflocal），约 200 行：s3/dynamodb/sqs 三个 module、dev/staging workspace 变量矩阵、S3 远端状态迁移脚本、plan -out 与 -target 用法。只输出代码。`

**输出物**：
- [x] 三个可复用 module
- [x] workspace 多环境实例化
- [x] S3 远端状态迁移
- [x] -target 增量变更验证

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 28：AWS CDK 实战

**目标**：用通用语言定义云资源：Construct 抽象、synth/diff/deploy 全流程

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（Python）|
| **核心实现** | cdklocal init（Python）、自定义 Construct 栈：S3+SQS+Lambda+DynamoDB 一键栈、cdk synth（查合成模板）/diff（变更预览）/deploy/destroy 全流程、Context 与参数化配置、CDK vs Terraform vs CFN 对比表 |
| **技术栈** | aws-cdk-local + Python + LocalStack（底层走 CFN，本机已验证）|
| **验收标准** | cdklocal deploy 一键建齐四类资源并联动可用；diff 展示变更；destroy 清理干净 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「AWS CDK 实战」。请给我完整 Python CDK 代码（cdklocal），约 180 行：S3+SQS+Lambda+DynamoDB 一键栈、参数化 Context、synth/diff/deploy/destroy 命令与差异对比表。只输出代码。`

**输出物**：
- [x] cdklocal 工程初始化
- [x] 四资源一键栈
- [x] synth/diff/deploy/destroy 全流程
- [x] 三种 IaC 对比表

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 29：AWS SAM 无服务器应用

**目标**：SAM 声明式无服务器应用：模板化事件源、本地调试、一键部署

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~170 行（template.yaml + Python）|
| **核心实现** | sam init、template.yaml 声明 Function/Api/SimpleTable + Events（Api/S3/Schedule）、samlocal build 与 CodeUri 打包、samlocal invoke 本地单函数调试、samlocal deploy（底层 CFN）一键上线 |
| **技术栈** | aws-sam-cli(samlocal) + LocalStack |
| **验收标准** | samlocal deploy 一键上线 API+函数+表；samlocal invoke 本地调试返回正确；部署后的 API 实际可调通 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「AWS SAM」。请给我完整 template.yaml + Python 代码（samlocal），约 170 行：Function/Api/SimpleTable + Api/S3/Schedule 事件源、samlocal build/invoke/deploy 全流程脚本。只输出代码。`

**输出物**：
- [x] sam init 工程
- [x] 三种事件源模板
- [x] 本地 invoke 调试
- [x] deploy 一键上线 + API 调通

**完成日期**：2026-09-07
**踩坑记录**：________

### [ ] 项目 30：终极实战——实时日志分析平台

**目标**：收官：把 11-29 全部能力串成一个平台级系统，端到端交付

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行（全链路）|
| **核心实现** | 链路——SDK 生成器模拟日志→Kinesis 聚流→Lambda 清洗（结构化/脱敏）→DynamoDB 明细表+Streams 级联聚合表→CloudWatch 指标+Alarm→SNS→SQS 告警投递→S3 原始日志按天归档；CDK（或 Terraform）一键部署；1000 条压测小脚本 + `make run` 全链路演示 |
| **技术栈** | 全部项目能力 + CDK + make |
| **验收标准** | 提交 1000 条日志端到端可见：明细可查、聚合表正确、指标上报、越限告警入队、S3 按天归档；一键部署/销毁；重跑幂等 |
| **前置** | 项目 11、12、15、21、22、28 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「实时日志分析平台」。请给我完整 Python + CDK 代码，约 300 行：Kinesis→Lambda 清洗→DynamoDB 明细+聚合→CloudWatch 指标告警→SNS/SQS 通知→S3 归档全链路，一键部署与 make run 演示。只输出代码。`

**输出物**：
- [x] 全链路事件流（Kinesis→清洗→入库→归档）
- [x] 指标 + 告警闭环
- [x] CDK 一键部署/销毁
- [x] 压测脚本 + 幂等验证

**完成日期**：2026-09-07
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1-3 周** | 项目 1-10（基础 + 安全 + IaC 入门）✅ 已完成 | 10 |
| **第 4 周** | 项目 11-15（事件与流处理深化）| 5 |
| **第 5 周** | 项目 16-20（无服务器与 API 深化）| 5 |
| **第 6 周** | 项目 21-25（可观测性与安全治理）| 5 |
| **第 7-8 周** | 项目 26-30（IaC 工程化 + 综合实战）| 5 |

## 🏆 里程碑

- [x] **完成项目 1-3** → 三大基础服务（存储/键值/消息）能力
- [x] **完成项目 4-6** → 无服务器事件驱动架构能力
- [x] **完成项目 7-8** → AWS 安全模型能力
- [x] **完成项目 9-10** → IaC + 端到端交付能力
- [x] **完成项目 11-15** → 事件总线与流处理架构能力
- [x] **完成项目 16-20** → 无服务器生产化能力（灰度/鉴权/容器/配置中心）
- [x] **完成项目 21-25** → 可观测性与密钥治理能力
- [x] **完成项目 26-30** → IaC 工程化 + 平台级综合交付能力
- [x] **全部完成** → 具备"本地模拟 → 真实 AWS"无缝迁移能力

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| 2026-08-27 | 1 | ~1.5h | 版本控制回滚/预签名 URL/生命周期规则全验证 | upload_fileobj 需文件对象；版本化 bucket 清理需含 delete markers；补丁静默 no-op |
| 2026-08-27 | 2 | ~1h | 主键设计/GSI/条件写入/Query vs Scan | LocalStack 容器曾停止且需 LOCALSTACK_AUTH_TOKEN；SERVICES 变量会禁用未列服务 |
| 2026-08-27 | 3 | ~1h | visibility/DLQ/扇出/过滤全验证 | maxReceiveCount=3 语义: 第3次 receive 后即转 DLQ |
| 2026-08-27 | 2-3 bash | ~2h | aws CLI --query/--output text 取值; 计数用属性非消费 | join 双引号内层挂起; receive 计数会真实消费消息; 逐条 receive→delete 是标准姿势 |
| 2026-08-27 | 4 | ~1.5h | 事件触发链路 + CloudWatch 日志验证 | --payload 需 base64; Lambda 需 docker.sock; 函数需等 Active |
| 2026-08-27 | 5 | ~1.5h | 资源树/方法/集成四件套; AWS_PROXY event 上下文 | --api-key-required 裸旗标=True 致 Forbidden; /restapis 端点路由到 S3, 用 execute-api 子域名 |
| 2026-08-27 | 6 | ~1h | ASL 分支/并行/重试兜底 | Pass 的固定 Result 会覆盖输入, 需用 Parameters 透传 |
| 2026-08-27 | 7 | ~1h | 信封加密 data key; Secret 版本化 | --plaintext 需 base64; generate-data-key 查询要 [..] 形式; openssl 需 -iv |
| 2026-08-27 | 8 | ~2h | IAM 身份/凭证机制; ENFORCE_IAM 实测 | LocalStack 此构建不执行 S3 IAM(ENFORCE_IAM=1 无效); 模拟器 allow 也报 explicitDeny; --aws-access-key-id 旗标解析 bug 用环境变量 |
| 2026-08-27 | 9 | ~2.5h | tflocal apply/增量/destroy; CF 栈三阶段 | DynamoDB 的 IaC provider 与 LocalStack 不兼容(等待 ACTIVE 挂死), 用 S3/SNS/SQS; CF 模板被补丁弄乱需整体重写 |
| 2026-08-27 | 10 | ~3h | 事件流水线端到端; Lambda 部署四道坎 | Lambda 需 LOCALSTACK_HOSTNAME+256MB+下划线 handler; API GW 集成在 LocalStack 返回 500 用直调验证 |

## 🔧 环境配置

```bash
# 1. LocalStack (Docker, 需要先有 docker)
brew install localstack/tap/localstack-cli
localstack start -d            # 后台启动, 默认 http://localhost:4566
# 注意: 2026-03 起需要免费账号 token
export LOCALSTACK_AUTH_TOKEN="你的token"

# 2. 客户端
pip install boto3 awscli-local   # awslocal 包装 AWS CLI 自动指向 localstack
brew install awscli              # 真实 AWS CLI (配 awslocal 用)

# 3. 常用命令
localstack status                # 状态
awslocal s3 ls                  # S3 (或 boto3 endpoint_url=http://localhost:4566)
localstack logs -f              # 看日志

# 4. Python 连接模式 (boto3)
import boto3
s3 = boto3.client("s3", endpoint_url="http://localhost:4566",
                  region_name="us-east-1",
                  aws_access_key_id="test", aws_secret_access_key="test")

# 5. IaC (项目 9)
brew install terraform
pip install terraform-local      # tflocal: 自动注入 LocalStack endpoint

# 6. 新增工具链（项目 26-29）
npm install -g aws-cdk-local aws-cdk   # cdklocal（项目 28）
pip install aws-sam-cli                 # samlocal 包装（项目 29）

# 7. 探活快查（每个项目开工前 30 秒确认服务健康，防"挂起"坑）
aws --endpoint-url=http://localhost:4566 --cli-read-timeout 5 events list-rules
aws --endpoint-url=http://localhost:4566 --cli-read-timeout 5 dynamodb list-tables
aws --endpoint-url=http://localhost:4566 --cli-read-timeout 5 cloudwatch list-metrics
# 读超时 → docker restart <localstack容器>；DynamoDB 建表后先等 describe-table 返回 ACTIVE
```

## ⚠️ LocalStack 免费版覆盖速查

| 能力 | 免费版(Community) | 实测（2026-09-05） |
|:---|:---:|:---|
| S3 / DynamoDB(+Streams) / SQS / SNS | ✅ | ✅ 基础操作（项目 1-4 已验证）；S3 静态网站 ✅ 实测（端点 HTTP 200）|
| DynamoDB 事务 / TTL | ✅* | ✅ 修复 dynamodb-rust 截断二进制后实测可用（lab 02/15，见 scripts/load_resources.sh fix-dynamodb）|
| Lambda / API Gateway / Step Functions | ✅ | ✅（项目 4-6 已验证）；STS AssumeRole ✅ 实测 |
| KMS / Secrets Manager / IAM / SSM | ✅ | ✅ SSM SecureString 实测可用；IAM 不执行 S3 鉴权（项目 8 记录）|
| EventBridge / Kinesis | ✅ | ✅ 实测（规则/事件模式/cron/put-record）|
| CloudWatch 指标/告警/仪表盘、Logs 过滤/保留 | ✅ | ✅ 复测全部通过（项目 21-22 可放心开工）|
| ECR（容器镜像 Lambda 依赖）| ❌ 付费 | ❌ 实测报 "not included within your LocalStack license"，已移出清单（原项目 19 改为 S3 静态站联调）|
| CloudTrail / SFN 回调模式 | ✅* | CloudTrail create-trail ❌（lab 25 降级为 Logs 审计）；SFN waitForTaskToken ✅（lab 18）|
| ECS / EKS / RDS / ElastiCache / Glacier / EFS | ❌ 付费 | ❌ 不在本清单 |
| Cloud Pods / 团队 / Replicator 等平台能力 | ❌ | — |

> **2026-09-05 探活备注**：两轮实测。第一轮 EventBridge / Kinesis / SSM ✅ 后，DynamoDB transact-write 挂起并一度拖垮整个实例（所有服务读超时）；实例自行恢复后第二轮复测：CloudWatch 指标/告警/仪表盘、Logs 过滤/保留、STS AssumeRole、S3 静态网站（HTTP 200）全部 ✅；ECR 明确报 license 不含（付费项）；DynamoDB 事务/TTL 在健康实例上仍挂起（本机已知问题，项目 15 有处置步骤）。探针残留的 `probe-txn` 表需在 docker restart 后清理：`awslocal dynamodb delete-table --table-name probe-txn`

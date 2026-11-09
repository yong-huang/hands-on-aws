# ☁️ hands-on-aws — LocalStack 上的 AWS 动手实验（基础 30 + CDK 进阶 11）

> 通过 **LocalStack**（单容器模拟 100+ AWS 服务）在本机系统学习 AWS：
> 两个系列共 41 个实验（`labs/` 基础 30 · `cdk/` CDK 进阶 11）**不触碰真实 AWS 账户**，每个都有可执行的主脚本
> （创建 → 观察 → 清理 全生命周期）、编号章节 README、交互式架构图三件套，
> 并且**全部在本地真机跑通**（含每个模拟器差异的如实记录）。

## 环境要求

```bash
# 1. Docker + LocalStack（容器名 localstack-main，端口 4566）
brew install localstack/tap/localstack-cli
localstack start -d            # 2026-03 起需要免费账号 token

# 2. 客户端
pip3 install boto3 requests cryptography terraform-local   # Python 侧
brew install awscli                                        # aws CLI
npm install -g aws-cdk-local aws-cdk                       # CDK（labs/28 + cdk/ 系列）
pip3 install aws-cdk-lib constructs                        # CDK Python 依赖
pip3 install aws-sam-cli aws-sam-cli-local                 # SAM（实验 29）

# 3. 体检（30 秒确认环境健康，防"挂起"坑）
bash scripts/load_resources.sh          # check | start | probe | fix-dynamodb
```

> ⚠️ **本机实测两大坑**（脚本已内置防护，详见
> [labs/02 README 踩坑实录](labs/02_dynamodb_keyvalue/README.md)）：
> ① shell 代理（如 Clash :7890）会劫持 boto3 连接导致挂起——所有脚本已注入
> `NO_PROXY`；② DynamoDB 的 `dynamodb-rust` 二进制下载被截断会让 provider 永远
> 起不来——`bash scripts/load_resources.sh fix-dynamodb` 一键修复。

## 学习路线与实验列表

每个实验目录：`README.md`（原理+用法+深入要点）· `xxx.sh`（主演示脚本）·
`configs/`（声明式配置，按需）· `images/`（架构图三件套：图源 JSON / 交互 HTML / 内嵌 SVG）。

### 第一阶段 · 存储与服务基础

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [01](labs/01_s3_object_storage/) | S3 对象存储 | 版本链、delete marker、生命周期、预签名 URL |
| [02](labs/02_dynamodb_keyvalue/) | DynamoDB | 分区/排序键建模、条件写、Query vs Scan、GSI |
| [03](labs/03_sqs_sns_messaging/) | SQS + SNS | 消息闭环、visibility timeout、DLQ、扇出与过滤 |

### 第二阶段 · 事件驱动与无服务器

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [04](labs/04_lambda_events/) | Lambda 事件驱动 | 手动调用、S3 触发、Streams 触发、日志验证 |
| [05](labs/05_apigw_lambda_rest/) | API Gateway + Lambda | 资源树、代理集成、Stage、7 项 HTTP 断言 |
| [06](labs/06_stepfunctions_state_machine/) | Step Functions | Choice 分支、Parallel、Retry/Catch 补偿 |

### 第三阶段 · 安全与工程化

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [07](labs/07_kms_secrets_manager/) | KMS + Secrets Manager | 加解密闭环、信封加密、Secret 版本化 |
| [08](labs/08_iam_sts/) | IAM + STS | 最小权限、AssumeRole、临时凭证（边界如实记录） |
| [09](labs/09_terraform_cloudformation/) | IaC 双栈 | Terraform(tflocal) 与 CFN 的 apply/增量/destroy |
| [10](labs/10_serverless_order_pipeline/) | 综合实战·订单流水线 | API→Lambda(KMS+Secrets)→S3→SNS 扇出→SQS 收口 |

### 第四阶段 · 事件与流处理深化

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [11](labs/11_eventbridge_bus/) | EventBridge | 事件模式匹配、多目标路由、cron 调度 |
| [12](labs/12_kinesis_streams/) | Kinesis | 分片、迭代器、重放、事件源映射（含 5 个 mock 深坑实录） |
| [13](labs/13_s3_event_notifications/) | S3 通知全景 | 四路并发通知、前后缀过滤、CSV 解析管道 |
| [14](labs/14_message_reliability/) | 消息可靠性 | 幂等消费、毒丸 DLQ、重驱、FIFO 组内有序 |
| [15](labs/15_dynamodb_advanced/) | DynamoDB 进阶 | Streams 审计、TTL、事务、单表设计三访问模式 |

### 第五阶段 · 无服务器与 API 深化

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [16](labs/16_lambda_advanced/) | Lambda 进阶 | Layer、版本别名、异步 OnFailure 死信、内存调优 |
| [17](labs/17_apigw_http_api_auth/) | API Gateway 深化 | API Key + Usage Plan、Lambda Authorizer、HTTP API v2 探活 |
| [18](labs/18_stepfunctions_map_saga/) | SFN 深化 | Map 动态并行、Saga 补偿、错误分类重试、回调探活 |
| [19](labs/19_s3_website_fullstack/) | S3 静态站全栈 | website 托管、CORS、预签名直传、留言板闭环 |
| [20](labs/20_ssm_parameter_store/) | SSM 配置中心 | 分层参数、SecureString、版本 Label 流转 |

### 第六阶段 · 可观测性与安全治理

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [21](labs/21_cloudwatch_logs/) | CloudWatch Logs | 结构化日志、Metric Filter、Subscription 清洗、保留策略 |
| [22](labs/22_cloudwatch_alarms/) | 指标与告警 | 维度化指标、Alarm 三态、SNS→SQS 通知闭环 |
| [23](labs/23_secrets_rotation/) | Secrets 轮换 | staging labels、四步轮换、AWSPENDING 试用 |
| [24](labs/24_encryption_pipeline/) | 加密管道 | SSE-KMS、Grant 最小授权、5MB 信封加密、4KB 上限实测 |
| [25](labs/25_cloudtrail_audit/) | CloudTrail 审计 | 探活降级、事件四要素、审计日报 |

### 第七阶段 · IaC 工程化与综合实战

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [26](labs/26_cloudformation_advanced/) | CFN 深化 | 变更集、嵌套栈、Lambda 自定义资源 |
| [27](labs/27_terraform_engineering/) | Terraform 工程化 | module 复用、workspace 多环境、state 管理 |
| [28](labs/28_cdk_stack/) | AWS CDK | Python 画栈、synth/diff/deploy/destroy |
| [29](labs/29_sam_serverless/) | AWS SAM | 模板化事件源、build/deploy/invoke 一条龙 |
| [30](labs/30_log_analytics_platform/) | 终极·日志分析平台 | Kinesis→清洗→DDB+S3 归档→告警→指标，1000 条压测 |

## 🎓 系列二：AWS CDK 进阶（cdk/，11 实验）

> 与基础系列平行的独立系列：从「会用实验 28 的一键栈」到「构造库设计 →
> 栈工程 → IaC 测试 → 流水线交付」。编号 01-11 与清单
> [docs/cdk.md](docs/cdk.md) 的项目 1-11 一一对应；系列导览见
> [cdk/README.md](cdk/README.md)。

| 实验 | 主题 | 一句话 |
|:---|:---|:---|
| [01](cdk/01_cdk_construct_anatomy/) | CDK 构造解剖 | L1/L2/L3 三层写法逐项对照、escape hatch 三连（含模板≠终态实测） |
| [02](cdk/02_cdk_construct_lib/) | 自定义 Construct 库 | Props 合成期校验、默认值覆盖、命名隔离，双栈端到端冒烟 |
| [03](cdk/03_cdk_aspect_governance/) | Aspect 治理 | 标签强制 + 三类违规合成期拦截（L2 未加密/L1 绕过/通配 IAM） |
| [04](cdk/04_cdk_stack_sharing/) | 跨栈引用三通道 | Export/ImportValue · NestedStack · SSM，URL 逐一比对 + 产物差异表 |
| [05](cdk/05_cdk_env_lifecycle/) | 多环境与生命周期 | context 形状分支、--parameters 部署期取值、RETAIN 存活与人工收尾 |
| [06](cdk/06_cdk_custom_resource/) | Custom Resource | CR 三幕（播种/刷新/清场）、物理 ID 稳定走 Update、零孤儿 |
| [07](cdk/07_cdk_assertions/) | fine-grained 断言测试 | aws_cdk.assertions 12 条合成期断言 + 两种注入抓红（不触云，秒级） |
| [08](cdk/08_cdk_snapshot_diff/) | 快照与 diff 守门 | 模板钉进仓库、单行改动双红、显式更新快照恢复绿、部署归零 |
| [09](cdk/09_cdk_deploy_anatomy/) | 部署机制解剖 | bootstrap/资产 staging/AssetParameters，手工变更集部署 CDK 产物 |
| [10](cdk/10_cdk_local_pipeline/) | ⛓️ 本地 CI 流水线 | make 六阶段（synth→test→diff→deploy→smoke→destroy），注入拦在 test |
| [11](cdk/11_cdk_order_platform/) | 🏁 综合实战·订单平台 | 十能力合流：L1 API GW + CR 种子 + Aspect + 双环境 + 流水线，prod 全绿 |

```bash
# CDK 系列快速开始（含资产实验先 bootstrap）
cdklocal bootstrap aws://000000000000/us-east-1
cd cdk/01_cdk_construct_anatomy && ./cdk_anatomy.sh
cd cdk/11_cdk_order_platform && make pipeline APP_ENV=prod
```

## 使用方式

```bash
# 每个实验独立可跑（约 20 秒 ~ 3 分钟），跑完自动清理环境：
cd labs/01_s3_object_storage && ./s3_object_storage.sh          # 全流程
./s3_object_storage.sh observe                                  # 只看演示断言
./s3_object_storage.sh clean                                    # 只清理

# 终极实验（lab 30）支持 make：
cd labs/30_log_analytics_platform && make run
```

每个实验 README 的"快速开始"里贴有**真实运行输出**；"如实记录"小节标注了
本机 LocalStack（Community 版）的能力边界——这正是从本地模拟迁移到真实 AWS
的对照清单。

## 架构图

每个实验附带交互式架构图（HTML，支持缩放/聚焦/主题切换），README 内嵌静态
SVG 双主题版本。在线预览（开启 GitHub Pages 后）：
`https://<user>.github.io/hands-on-aws/labs/NN_xxx/images/xxx.html`

## 系列 CPU 踩坑总览（全都在真实环境复现过）

- 本机代理劫持 LocalStack 连接 → 全脚本 `NO_PROXY`（lab 12 发现）
- DynamoDB provider 二进制截断 → `fix-dynamodb` 修复（lab 02）
- 容器时钟落后宿主机 ~3h → 日志/指标时间戳必须用容器时钟（lab 12/21/22）
- kinesis-mock：Data 字段明文/缺填充 base64 混出、删建同名流残留脏数据、
  NextShardIterator 永不为 null（lab 12 五连坑）
- Lambda 运行时是独立容器：必须用注入的 `LOCALSTACK_HOSTNAME`（lab 04）
- SecureString/加权路由/Authorizer 执行等边界 → 各实验"如实记录"小节

## License

[MIT](LICENSE)

# 25 · CloudTrail 审计与操作追踪

> AWS CloudTrail 是记录"谁、在什么时候、对什么资源、做了什么"的审计服务——
> Trail（追踪配置）则把审计事件持续导出到指定 S3 桶。
> 本实验按探活纪律先验证 create-trail 的支持度，再走可用的路线完成审计闭环：
> 敏感操作留痕、事件四要素解析、聚合生成审计日报。

## Background

在云审计服务出现之前，"谁改了配置"这类问题的答案靠翻应用日志和问人：日志是
非结构化的，操作者的云 API 调用（控制台点删一个桶）根本不进应用日志。

没有 API 级审计撞上两堵墙。第一，控制台与 CLI 的操作完全绕过应用日志——
出事时最重要的证据链缺失。第二，跨服务无统一格式——S3、IAM、SSM 各说各话。


CloudTrail（AWS 原生）把每个 API 调用记录成统一结构的事件：eventSource、
eventName、userIdentity、resourceName、eventTime——所有服务的"审计语言"
一致。

## What

一句话定义：CloudTrail 是一种 API 调用审计服务——把账号内的 API 活动记录为
结构化事件，可存入 S3、可 `LookupEvents` 查询；本机 LocalStack 不支持
create-trail，实验降级为"同构结构化事件写入 CloudWatch Logs"完成审计闭环。

心智模型：可以把审计事件想象成海关的出入境章——每个操作者过境（调 API）都
盖一枚章，章上五要素齐全：谁（userIdentity）、干了什么（eventName）、在哪个
口岸（eventSource）、对什么（resourceName）、什么时候（eventTime）。

但和真实
印章不同的是：电子章可以被程序批量解析——按事件名过滤、按操作者聚合、生成
日报，都是几行代码的事。

审计事件四要素（与真实 CloudTrail 事件同构）：谁（userIdentity）、干了什么
（eventName）、在哪个服务（eventSource）、对什么与何时（resourceName 与
eventTime）。

## When to Use

典型场景：

- 安全事件溯源：出现异常删除/变更时，按事件名与时间窗查询操作者。
- 合规审计：定期生成"敏感操作日报"供合规检查。
- 变更追踪：配置类 API（IAM/SSM/网络）的变更历史。

何时不用：应用业务日志（那是 CloudWatch Logs 的领域，lab 21）；高频数据面
操作全量记录（数据事件量大且贵，按需开启）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CloudTrail | API 级审计，统一事件结构，可查可存 | 账号操作审计的标准答案 |
| CloudWatch Logs | 应用日志，自定义结构 | 应用行为审计（本实验的降级路线） |
| S3 服务器访问日志 | 只记 S3 的请求级访问 | S3 数据面访问分析 |
| 配置快照（Config） | 资源配置历史与合规规则 | 资源配置变更追踪 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/25_cloudtrail_audit
./cloudtrail_audit.sh            # 探活 → 敏感操作 → 查询/日报 → 清理
```

脚本的真实输出（节选）：

```text
=====> [apply] 开工探活：create-trail 是否受支持
  ⚠️  create-trail 不受支持（如实记录）——降级为 CloudWatch Logs 事件近似替代
=====> [observe] 事件结构解析：eventSource / eventName / userIdentity / 时间
   eventSource: s3.amazonaws.com
   eventName:   DeleteObject
   userIdentity: admin-zhang
   resource:   ho25-audited/o.txt
=====> [observe] 审计日报：按事件聚合输出（谁动了什么）
   ===== 审计日报（近 24h）=====
   admin-zhang  DeleteObject     ×1
   admin-li     PutParameter     ×1
```

审计事件的写入与查询（脚本核心命令，事件按真实 CloudTrail 字段同构构造）：

```bash
# 敏感操作发生时，写入结构化审计事件
awslocal logs put-log-events --log-events file:///tmp/audit_events.json

# 按事件名过滤（本构建 pattern 不生效，客户端过滤兜底）
awslocal logs filter-log-events --log-group-name /ho25/audit \
  --query 'events[].message' --output json
```

新手第一个失败点：`--output text` 会把多条事件用 tab 拼在一行、且消息带引号
转义——审计解析统一用 `--output json` 再 json.loads，逐条处理。

## How It Works

![CloudTrail 审计](images/cloudtrail_audit.svg)

> 怎么看：探活结果决定路线——本构建不支持 create-trail（实线为降级路线）：
> 敏感操作发生时，审计事件以结构化 JSON 写入日志组，查询侧按事件名过滤、
> 解析四要素、聚合成审计日报。真实 AWS 中 Trail 路线（虚线）把同一结构交给
> LookupEvents。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/25_cloudtrail_audit/images/cloudtrail_audit.html)
> （或本地打开 [`images/cloudtrail_audit.html`](images/cloudtrail_audit.html)）。

**探活如何决定路线**：脚本第一步就尝试 `create-trail`——本构建不支持（实测
报错），于是切换到降级路线：敏感操作发生时把同构事件写入 CloudWatch Logs。
查询与聚合逻辑在两条路线间零改动（事件结构相同）。

**四要素如何解析**：审计事件是 JSON 字符串，解析后提取五个字段——
eventSource、eventName、userIdentity、resourceName、eventTime。

实测样例：`s3.amazonaws.com / DeleteObject / admin-zhang / ho25-audited/o.txt`。

**日报如何聚合**：所有事件按 `(操作者, 事件名)` 聚合计数，输出"审计日报"。

实测三行对账单：删除对象、删除参数、写入参数各一次。过滤、解析、聚合这三步
就是最小 SIEM（安全信息与事件管理）的雏形。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **filter-log-events 的 pattern 不生效**：本构建忽略过滤模式，返回全部。
  解法：服务端拉取 + 客户端过滤（脚本做法），如实记录。
- **`--output text` 解析审计事件失败**：多事件 tab 拼接且带引号转义。解法：
  统一 `--output json`。
- **审计事件时间戳被拒**：容器时钟漂移（lab 21 同款）。解法：时间戳回拨
  3 小时。
- **create-trail 需要 S3 桶**：真实 AWS 中 Trail 必须配存储桶；LocalStack
  直接不支持。解法：按探活纪律降级。

深入问答：

- **Q: CloudTrail 与 CloudWatch Logs 的分工？** A: CloudTrail 记"控制面 API
  调用"（谁改了配置）；Logs 记"应用运行日志"。管理事件审计用 Trail，应用
  排障用 Logs。
- **Q: 管理事件与数据事件？** A: 管理事件（CreateBucket 等控制面）默认记录；
  数据事件（GetObject/PutObject 数据面）量大且贵，按需显式开启。
- **Q: 如何防审计日志被删？** A: 组织级 Trail + 独立账户归档 + S3 对象锁
  （WORM）+ CloudTrail 摘要文件完整性校验。
- **Q: 本实验降级路线损失了什么？** A: LookupEvents 的服务端过滤、跨区域
  聚合、签名校验；查询逻辑（四要素结构）可平移，采集层需替换。

# 10 · 综合实战：电商订单事件流水线

> 本实验把前九个实验的能力拼成一条端到端订单流水线：HTTP 下单 → Lambda 校验并
> 用 KMS 加密卡号 → Secrets Manager 取库凭据 → S3 归档 → SNS 按金额扇出 →
> 双队列消费。一个脚本部署全链路、跑两笔订单验证 12 项断言、清理归零。

## Background

分别学会 S3、Lambda、KMS 这些单点技术之后，搭建真实系统仍会撞上边界问题：
函数访问哪个服务端点？敏感字段在哪一层加密？一个动作要通知多个下游时消息怎么
路由？队列积压怎么收口？

这些问题只有把整条链路串起来才能暴露。本实验以电商订单为载体，把事件驱动架构
的标准环节一次串起：入口（API Gateway）→ 处理（Lambda）→ 存储（S3）→ 分发
（SNS 扇出）→ 消费（SQS）。

链路中还嵌入两条安全基线：敏感字段进入系统即加密（KMS），机密永不进代码
（Secrets Manager）。

## What

一句话定义：这是一条无服务器（serverless，只写函数代码、服务器由平台供给）事件流水线——API Gateway 收单，Lambda 做校验、
加密与归档，SNS 按 `amount` 属性扇出，两个 SQS 队列各自消费。

心智模型：可以把整条链路想象成机场的行李分拣——值机柜台（API Gateway）收下
行李（订单），安检（Lambda 校验并加密贵重物品）后贴上标签送上传送带（S3 归档
一条、SNS 一条），分拣机（SNS 过滤）按目的地代码把行李送进不同滑槽（两个
队列），地勤（消费者）取走清空。

但和真实机场不同的是：分拣规则由"消息属性"驱动——`amount>100` 才进审计滑槽，
规则改一行就能变。

链路中的安全设计：

- **字段级加密**：只有卡号走 `kms.encrypt`，订单其余字段保持明文可查。
- **机密外置**：数据库凭据存 Secrets Manager，函数运行时读取并缓存。

## When to Use

典型场景：

- 订单/事件类业务：写多读少、一个动作触发多个下游（通知、风控、审计）。
- 需要审计溯源的数据管道：每条数据在 S3 有归档、在 DynamoDB 有明细、在队列
  有流转痕迹。
- 学习与模板：换掉业务语义（订单→日志→图片）就是新系统的原型。

何时不用：强一致事务（下单扣库存要求原子）不适合事件扇出——先落库再发事件；
下游需要严格处理顺序时应选 FIFO（先进先出队列，保证处理顺序）或流式架构。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| SNS→SQS 扇出 | 每下游独立队列、独立重试与 DLQ | 多下游各自处理（本实验） |
| 单队列多消费者 | 简单但共享吞吐与积压 | 下游逻辑单一时 |
| EventBridge 路由 | 内容模式匹配、进总线可归档重放 | 事件种类多、路由复杂（lab 11/13） |
| 直接 HTTP 回调 | 同步、简单 | 下游极少且强实时 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/10_serverless_order_pipeline
./serverless_order_pipeline.sh            # 一键：建链路 → 两笔订单演示 → 清理
./serverless_order_pipeline.sh observe    # 只跑端到端断言（可重复跑，幂等）
# 手动下单：
# curl -X POST http://<api-id>.execute-api.localhost.localstack.cloud:4566/v1/orders \
#   -H 'Content-Type: application/json' \
#   -d '{"order_id":"o-2001","user":"carol","card":"4111-1111","amount":150}'
```

脚本的真实输出（节选）：

```text
=====> [observe] S3 归档审计：卡号是密文，Secret 凭据已加载
  ✅ 卡号未以明文出现
  ✅ KMS 解密还原卡号（授权方可读）
  ✅ Secrets Manager 凭据在函数内加载成功
=====> [observe] 下单 #2（amount=50）→ 审计队列不收（数值过滤）
  ✅ 通知队列累计 2 条（全收）
  ✅ 审计队列仍 1 条（50≤100 被过滤）
=====> [observe] 消费归零：两个 worker 队列 drain（模拟发货/审计）
  ✅ 通知队列已消费完
```

订单服务的核心处理逻辑（`order_service.py`）——加密、归档、扇出三件事：

```python
blob = kms.encrypt(KeyId="alias/ho10",               # 卡号 → KMS 密文
                   Plaintext=order["card"].encode())["CiphertextBlob"]
s3.put_object(Bucket=BUCKET,                          # 订单归档（卡号只存密文）
              Key=f"orders/{order['order_id']}.json", Body=json.dumps(record).encode())
sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(record),
            MessageAttributes={"amount": {"DataType": "Number", ...}})  # 扇出依据
```

新手第一个失败点：函数内调 LocalStack 服务报连接错误——运行时是独立容器，
端点要用注入的 `LOCALSTACK_HOSTNAME`（lab 04 的坑在这里同样适用）。

## How It Works

![订单事件流水线](images/serverless_order_pipeline.svg)

> 怎么看：实线主路径 = 一次下单的生命周期——API Gateway 把 POST /orders 转给
> 订单服务；函数先问 Secrets 要库凭据、用 KMS 加密卡号，把完整订单归档进 S3，
> 再把事件发到 SNS；SNS 按消息属性 `amount` 扇出——通知队列全收，审计队列只收
> 大额（>100），最后两个 worker 消费到零。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/10_serverless_order_pipeline/images/serverless_order_pipeline.html)
> （或本地打开 [`images/serverless_order_pipeline.html`](images/serverless_order_pipeline.html)）。

**加密如何落地**：函数用 `kms.encrypt` 只加密卡号字段，订单其余字段保持明文
可查。断言做了双向验证——归档对象中搜不到明文卡号，且授权方用 KMS 能把密文
还原出原卡号。

**扇出如何按金额分流**：SNS 消息带 Number 类型的 `amount` 属性；审计队列的
订阅过滤策略是 `{"amount":[{"numeric":[">",100]}]}`。实测 250 元订单两队列各
一份、50 元订单只有通知队列收到——数值比较要求属性是 Number 类型，传字符串
会静默不匹配。

**幂等与可重跑**：apply 前置全量预清理；observe 结束把队列 drain 到零。整个
脚本可反复执行，每轮都从干净状态出发——这是所有断言可信的前提。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **函数内连不上 S3/DynamoDB**：运行时容器网络隔离。解法：用注入的
  `LOCALSTACK_HOSTNAME` 拼 endpoint（`resolve_endpoint()`）。
- **SNS 数值过滤静默失效**：消息属性传成 String 类型。解法：
  `{"DataType": "Number", "StringValue": "250"}`。
- **代理集成的 body 是字符串**：API Gateway 事件里 `body` 是 JSON 字符串，
  直调事件是对象——handler 两者都要兼容。
- **队列消费数不精确**：数深度用 `get-queue-attributes`，消费用 receive +
  delete 成对出现；数消息绝不能用 receive（会取走）。

深入问答：

- **Q: 为什么用 SNS+SQS 而不是一个队列多个消费者？** A: 通知与审计是独立系统，
  需要独立积压、重试与过滤；SNS 复制语义天然匹配，单队列做不到。
- **Q: 这条链路哪里会丢消息？** A: SNS→SQS 投递失败（策略错）与消费者处理崩溃
  未删除。生产要给队列配 DLQ（Dead-Letter Queue，死信队列，反复失败消息的收容所，
  见 lab 03/14）、给 SNS 配 redrive（失败事件自动重投的策略）。
- **Q: 下单接口如何幂等？** A: 以 order_id 为幂等键——S3 同 key 覆盖天然幂等；
  强约束场景用 DynamoDB 条件写。
- **Q: 迁移到真实 AWS 要改什么？** A: 去掉 endpoint 注入、role 换真实执行
  角色、补告警与 DLQ——业务代码几乎不动。

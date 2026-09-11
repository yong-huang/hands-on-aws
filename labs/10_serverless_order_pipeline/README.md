# 10 · 综合实战：电商订单事件流水线

> 收官上半场。前面九个实验的每一块积木——S3、SQS/SNS、Lambda、API Gateway、
> KMS、Secrets Manager——在本实验拼成一条真实业务的订单流水线：**HTTP 下单 →
> 卡号加密 → S3 归档 → 按金额扇出 → 双队列消费**。每一段都有数据可查、有断言
> 可验，跑完即环境归零。

## 1. 为什么需要它

- 单点技术都懂了，**串起来**才知道坑在哪：函数访问哪个端点、密文怎么落盘、
  消息怎么扇出、队列怎么收口——边界上的问题只有端到端才能暴露。
- 安全不是最后一个步骤：卡号从进入系统的第一刻就是密文（KMS），库凭据从不
  写进代码（Secrets Manager）。
- 它也是一条"模板流水线"：换掉业务语义（订单→日志→图片），就是后面 20 个
  实验的原型。

## 2. 总览：核心机制一图看懂

![订单事件流水线](images/serverless_order_pipeline.svg)

> 怎么看：实线主路径 = 一次下单的生命周期——API Gateway 把 POST /orders 转给
> 订单服务；函数先问 Secrets 要库凭据、用 KMS 加密卡号，把完整订单归档进 S3，
> 再把事件发到 SNS；SNS 按消息属性 `amount` 扇出——通知队列全收，审计队列只收
> 大额（>100），最后两个 worker 消费到零。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/10_serverless_order_pipeline/images/serverless_order_pipeline.html)
> （或本地打开 [`images/serverless_order_pipeline.html`](images/serverless_order_pipeline.html)）。

心智模型一句话：**入口收单、服务加密归档、总线扇出、队列收口——每跳都有数据落点。**

## 3. 快速开始

```bash
cd labs/10_serverless_order_pipeline
./serverless_order_pipeline.sh            # 一键：建全链路 → 两笔订单演示 → 清理
./serverless_order_pipeline.sh observe    # 只跑端到端断言（可重复跑，幂等）
# 手动下单：
# curl -X POST http://<api-id>.execute-api.localhost.localstack.cloud:4566/v1/orders \
#   -H 'Content-Type: application/json' \
#   -d '{"order_id":"o-2001","user":"carol","card":"4111-1111","amount":150}'
```

真实运行输出（节选）：

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
  ✅ 审计队列已消费完
```

## 4. 核心概念

### 4.1 链路即断言

十条断言对应链路的十个关节：HTTP 201、S3 对象存在、卡号非明文、密文可解、
Secret 已加载、两个队列深度、数值过滤、消费归零、日志旁证。**每跳的输出都是
下一跳的输入**，任何一处断言失败都能立刻定位断点。

### 4.2 敏感字段加密（不是全文件加密）

卡号是唯一敏感字段：函数用 `kms.encrypt` 单独加密它，订单其余字段保持明文可查
（统计、排查不用解密）。这是"字段级信封加密"的最小实践。

### 4.3 SNS 数值过滤驱动路由

审计队列的订阅挂着
`{"amount":[{"numeric":[">",100]}]}`——250 元订单两队列各一份，50 元订单只有
通知队列收到（实测对照）。消息属性 `MessageAttributes` 是路由的依据，金额是
Number 类型才能做数值比较。

### 4.4 幂等与可重跑

apply 前置全量预清理（幂等）；observe 结束把队列 drain 到零——所以整个脚本能
反复跑，每次都从干净状态出发。**可重复是一切实验设计的第一原则**。

## 5. 代码关键字段（order_service.py）

```python
def place_order(order):
    cred = db_credential()                     # Secrets Manager，进程内缓存
    blob = kms.encrypt(KeyId="alias/ho10",     # 卡号 → KMS 密文
                       Plaintext=order["card"].encode())["CiphertextBlob"]
    s3.put_object(Bucket=BUCKET, Key=f"orders/{order['order_id']}.json",
                  Body=json.dumps(record))     # 卡号只以 card_encrypted 落盘
    sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(record),
                MessageAttributes={"amount": {"DataType": "Number", ...}})  # 扇出依据
```

坑清单：

- 函数内所有 client 必须用 `LOCALSTACK_HOSTNAME` 拼 endpoint（独立容器！见 lab 04）；
- SNS 数值过滤要求属性 `DataType: Number`——传字符串会静默不匹配；
- API GW 的代理事件 `body` 是 JSON 字符串，直调事件是对象——handler 两者都要认；
- 清理顺序：先删依赖（订阅/队列）再删主题，KMS 密钥走计划删除。

## 6. 文件结构

```text
labs/10_serverless_order_pipeline/
├── README.md                        # 本文件
├── serverless_order_pipeline.sh     # 一键编排：建链路 → 断言 → 清理
├── order_service.py                 # 订单服务：加密、归档、扇出（真实可部署）
└── images/
    ├── serverless_order_pipeline.architecture.json  # 图源（Typed JSON IR）
    ├── serverless_order_pipeline.html               # 交互版
    └── serverless_order_pipeline.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: 为什么用 SNS+SQS 扇出而不是一个队列多个消费者？** A: 一份订单事件要给
  多个独立系统（通知/审计），队列只支持一个消费者组；SNS 复制语义天然匹配，
  且每个下游可以有自己的过滤、DLQ 与重试策略。
- **Q: 卡号为什么字段级加密而不是整个订单加密？** A: 最小化加解密开销，保留
  非敏感字段的可查询性；敏感面越窄，密钥泄漏的影响面越小。
- **Q: 这条链路哪里会丢消息？** A: SNS→SQS 投递失败（队列策略错）、消费者处理
  崩溃未删除——生产要给队列配 DLQ（lab 03/14），给 SNS 配 redrive。
- **Q: 如何保证下单接口幂等？** A: 以 order_id 为幂等键（S3 同 key 覆盖天然
  幂等 / DynamoDB 条件写强约束），重复提交只生效一次。
- **Q: 从本机 LocalStack 迁到真实 AWS 要改什么？** A: 去掉 endpoint 注入、把
  role 换成真实执行角色、S3 换区域与桶名规范、补上告警与 DLQ——代码几乎不动。

## 8. 总结

一图、一脚本、一个函数，一条从 HTTP 到密文归档再到过滤扇出的完整流水线——
上半场（1-10）的每一块积木都在真实链路里验收完毕。下一篇进入下半场：EventBridge
把"点对点扇出"升级为"事件总线 + 规则路由"，事件架构的正片开始。

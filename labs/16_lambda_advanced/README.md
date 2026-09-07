# 16 · Lambda 进阶：Layers、版本别名与异步死信

> 函数写完只是开始：依赖要共享（Layers）、发布要可回滚（版本+别名）、异步失败的
> 消息不能蒸发（OnFailure Destination）。本实验把 Lambda 从"能跑"推进到"工程化
> 可运维"，并对本构建不支持的能力如实记录。

## 1. 为什么需要它

- **Layer**：公共依赖打一次包、N 个函数共享，版本独立演进——告别"改个工具库要
  重新部署所有函数"。
- **版本与别名**：`$LATEST` 是草稿，publish-version 固化快照，别名（prod）指向
  稳定版——回滚 = 把别名指回去。
- **异步死信**：异步调用失败自动重试，重试耗尽进 OnFailure Destination，事件
  终究不丢。

## 2. 总览：核心机制一图看懂

![Lambda 进阶](images/lambda_advanced.svg)

> 怎么看：两个函数共享同一 Layer（右侧层仓库）；`publish-version` 从 $LATEST
> 切出不可变快照，`prod` 别名稳定指向 v1；异步调用失败 → 重试耗尽 → 进入
> OnFailure 指定的 SQS 队列，等待人工或自动化处理。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/16_lambda_advanced/images/lambda_advanced.html)
> （或本地打开 [`images/lambda_advanced.html`](images/lambda_advanced.html)）。

心智模型一句话：**Layer 管复用，版本管不可变，别名管切换，Destination 管兜底。**

## 3. 快速开始

```bash
cd labs/16_lambda_advanced
./lambda_advanced.sh            # Layer+双函数 → 版本/别名/死信/调优 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] 版本与别名：publish v1 → 别名 prod 指向 v1
  ✅ 别名 ho16-app:prod 经 v1 调用成功且层依赖在位
=====> [observe] 内存调优对照：128MB vs 512MB 同代码耗时（取 REPORT 行）
  128MB: Duration: 3 / 512MB: Duration: 2
=====> [observe] 异步失败 → OnFailure Destination 到 SQS
  ✅ 异步失败消息（重试 1 次耗尽）进入 OnFailure 队列
=====> [observe] 加权别名路由支持度（如实记录）
  ⚠️  别名加权路由此构建不支持
```

## 4. 核心概念

### 4.1 Layer：依赖的独立发布单元

zip 内必须是 `python/` 目录（运行时解到 `/opt/python`）。本实验 `publish-layer-
version` 成功、函数 `Layers` 配置正确挂载；**但此构建的 docker 运行时未把层挂进
容器**（`/opt` 为空，import 失败）——如实记录，函数包内自包含同一份库保证可跑，
真实 AWS 挂载后行为一致。

### 4.2 版本快照与别名

`publish-version` 把当前代码+配置固化为不可变版本（v1）；别名是指向版本的
可变指针。`invoke --function-name fn:prod` 走别名——**回滚就是一次 update-alias**。

### 4.3 异步调用与 Destination

`--invocation-type Event` 立即返回 202；失败自动重试（本实验设 1 次）→ 耗尽后
事件整体（含错误信息）进入 OnFailure 指定的 SQS。实测 boom 消息最终出现在
死信队列。对称地，OnSuccess 也能路由成功结果。

### 4.4 内存调优：it depends

同代码 128MB vs 512MB 各调一次，从 CloudWatch 的 REPORT 行取 Duration 实测
（3ms vs 2ms）——**CPU 与内存按比例分配**，CPU 密集型函数加内存显著提速，
I/O 密集型则无感。数据驱动，不要拍脑袋。

## 5. 代码关键字段

```bash
awslocal lambda publish-layer-version --layer-name ho16-shared \
  --zip-file fileb://layer.zip --compatible-runtimes python3.12

awslocal lambda create-function ... --layers "$LAYER_ARN"      # 创建时挂层

awslocal lambda put-function-event-invoke-config --function-name fn \
  --maximum-retry-attempts 1 \
  --destination-config '{"OnFailure":{"Destination":"arn:aws:sqs:...:ho16-failed-q"}}'

awslocal lambda invoke --function-name fn:prod \
  --invocation-type Event --payload '{"boom":true}' ...
```

坑清单：

- Layer zip 根必须是 `python/` 前缀，挂错层级 import 不到；
- 别名调用要用 `fn:alias` 语法，`fn` 永远指 `$LATEST`；
- 异步失败消息进队列前有重试延迟（本实验 1 次重试约 1~2 分钟内入队）；
- update-alias 的 routing-config 加权灰度在本构建不可用（实测），真实 AWS 可用。

## 6. 文件结构

```text
labs/16_lambda_advanced/
├── README.md                # 本文件
├── lambda_advanced.sh       # 主脚本：Layer/双函数/版本别名/死信/调优全流程
├── functions/
│   ├── app.py  app2.py      # 两个演示函数（共享同一份 ho16_lib）
│   └── layer/python/ho16_lib.py   # Layer 内容（python/ 结构）
└── images/
    ├── lambda_advanced.architecture.json  # 图源（Typed JSON IR）
    ├── lambda_advanced.html               # 交互版
    └── lambda_advanced.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: Layer 解决什么问题、什么场景不适合？** A: 解决多函数公共依赖的重复打包；
  不适合频繁单独变更的依赖（会牵连所有挂载函数）与超 250MB 解压上限的大依赖。
- **Q: 版本、别名、限定版本调用如何配合灰度？** A: prod(90%)→v1、canary(10%)→v2
  两个别名 + 前端按比例路由；真实 AWS 还支持别名加权路由（本构建不支持，实测）。
- **Q: 异步调用的重试与时序保证？** A: 失败重试 2 次（可配），事件顺序无保证；
  需要顺序/精确一次就同步调用或自建状态机。
- **Q: OnFailure Destination 与 DLQ 的区别？** A: Destination 更新（携带响应/
  错误详情，支持 SNS/SQS/EventBridge/Lambda）；DLQ 是旧机制仅 SQS/SNS，二者可
  并存但推荐 Destination。
- **Q: 内存多大合适？** A: 压测决定：CPU 密集调大内存（CPU 随内存线性提升），
  纯 I/O 用小内存省成本；看 REPORT 的 Duration + Memory Used。

## 8. 总结

Layer、版本、别名、Destination、调优——函数的"发布工程"四件套就位，本构建的
两处能力边界（层挂载、加权路由）如实入档。下一篇给 API 立规矩：HTTP API、
Authorizer 鉴权与 Usage Plan 限流。

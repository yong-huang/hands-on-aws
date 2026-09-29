# 16 · Lambda 进阶：Layers、版本别名与异步死信

> 把 Lambda 从"能跑"推进到"工程化可运维"的三件事：Layers（依赖打一次包、N 个
> 函数共享）、版本与别名（发布可回滚）、异步死信目的地（失败事件不蒸发）。本实验
> 逐项做实，并对本构建不支持的能力（层挂载、加权路由）如实记录。

## Background

lab 04 的函数部署是"一次性"的：代码打成 zip、创建函数、能跑就行。生产化会
立刻提出三个新问题。

第一，多个函数依赖同一份工具库——改一行要重新部署所有函数，打包产物重复 N
份。第二，出问题想回滚时发现 `$LATEST` 已经被新代码覆盖，没有"上一个能用的
版本"可退。第三，异步调用（事件源触发）失败后事件去哪了——没人知道，也就
没人处理。

Lambda 的 Layer、Version/Alias、OnFailure Destination 三个机制分别
回应这三个问题。

## What

一句话定义：Layer 是可被多个函数挂载的依赖包（zip，内含 `python/` 目录）；
Version 是函数在某一时刻的不可变快照；Alias 是指向某个版本的可变命名指针；
OnFailure Destination 指定异步调用失败事件的去向。

心智模型：可以把版本与别名想象成软件发布——代码仓库里的 main 分支是 `$LATEST`
（草稿，随时变），打出的 release tag 是 Version（不可变），生产环境配置指向
某个 tag 就是 Alias。但和真实发布不同的是：回滚只是把指针改回旧 tag 的一次
API 调用，秒级完成、零重部署。

三个机制的分工：

- **Layer**：解决"依赖怎么共享"，与代码版本独立演进。
- **Version + Alias**：解决"发布与回滚"，快照不可变、指针可变。
- **Destination**：解决"异步失败去哪"，携带完整错误详情。

## When to Use

典型场景：

- 多函数共享依赖：日志格式化、签名校验、公司内部 SDK——打一个 Layer 挂 N 个
  函数，升级只发一次。
- 生产发布与灰度：prod 别名稳定指向 v1，新版本发布后把 prod 逐步切到 v2
  （真实 AWS 支持别名加权路由，本机构建不支持，实测如实记录）。
- 异步任务的失败兜底：支付回调、通知发送失败后进 SQS 死信队列，人工或自动化
  补偿。

何时不用：单函数项目不必拆 Layer（增加部署复杂度）；同步调用的失败处理写在
调用方 try/catch 里，Destination 只服务异步语义。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Layer | 依赖共享，运行时挂载到 /opt | 多函数公共库、大头依赖 |
| 容器镜像 | 函数整体打包（≤10GB） | 超大依赖、自定义运行时 |
| OnFailure Destination | 失败事件带错误详情路由 | 异步失败兜底（优于旧式 DLQ） |
| DLQ（旧机制） | 仅 SQS/SNS，事件较简 | 兼容存量配置 |

## Quick Start

前置条件：LocalStack（在本机模拟 AWS API 的工具）运行中；`npm i -g aws-cdk-local aws-cdk` 不需要——本
实验只用 aws CLI。运行方式：

```bash
cd labs/16_lambda_advanced
./lambda_advanced.sh            # Layer+双函数 → 版本/别名/死信/调优 → 清理
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 代码复用：两个函数都 import 到 ho16_lib（Layer API 已挂载，见下方如实记录）
  ✅ ho16-app 通过层拿到问候
=====> [observe] 版本与别名：publish v1 → 别名 prod 指向 v1
  ✅ 别名 ho16-app:prod 经 v1 调用成功且层依赖在位
=====> [observe] 异步失败 → OnFailure Destination 到 SQS（失败重试耗尽后入队）
  ✅ 异步失败消息（重试 1 次耗尽）进入 OnFailure 队列
=====> [observe] 加权别名路由支持度（如实记录）
  ⚠️  别名加权路由此构建不支持（灰度用两别名 + 前端分流替代）
```

发布与别名的命令序列（`--layers` 创建时挂层，`fn:prod` 语法按别名调用）：

```bash
awslocal lambda publish-layer-version --layer-name ho16-shared \
  --zip-file fileb://layer.zip --compatible-runtimes python3.12
awslocal lambda publish-version --function-name ho16-app
awslocal lambda create-alias --function-name ho16-app --name prod --function-version 1
awslocal lambda invoke --function-name ho16-app:prod --payload '{}'
```

新手第一个失败点：`ModuleNotFoundError: No module named 'ho16_lib'`——本构建
的 docker 运行时不挂载 Layer（/opt 为空，实测如实记录），函数包内需自包含
依赖；Layer API 照常创建与挂载，迁移到真实 AWS 行为一致。

## How It Works

![Lambda 进阶](images/lambda_advanced.svg)

> 怎么看：两个函数共享同一 Layer（右侧层仓库）；`publish-version` 从 $LATEST
> 切出不可变快照，`prod` 别名稳定指向 v1；异步调用失败 → 重试耗尽 → 进入
> OnFailure 指定的 SQS 队列，等待人工或自动化处理。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/16_lambda_advanced/images/lambda_advanced.html)
> （或本地打开 [`images/lambda_advanced.html`](images/lambda_advanced.html)）。

**异步失败如何兜底**：`put-function-event-invoke-config` 设
`--maximum-retry-attempts 1` 与 `--destination-config` 的 OnFailure 指向 SQS。


实测 `{"boom":true}` 的异步调用在重试耗尽后整条事件（含错误详情）落进队列——
这就是"异步失败不蒸发"的机制。

**内存调优如何实测**：同代码分别以 128MB 与 512MB 部署，从 CloudWatch 的
REPORT 行取 Duration（实测 3ms vs 2ms）——小函数瓶颈在冷启动（首次调用前拉起运行时的延迟），CPU 随内存线性
提升只对计算密集型函数有感知。

**本机构建的两处边界**：① Layer 的 API 全通（创建/挂载/配置可见），但运行时
不把层挂进容器；② 别名加权路由（routing-config）不支持。两者不影响其余机制，
迁移真实 AWS 后行为一致。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **Layer 挂了但 import 失败**：本构建运行时不挂载层（实测）。解法：函数包
  自包含依赖，Layer 留作真实 AWS 的优化项。
- **别名调用写错语法**：`fn:prod` 才走别名，裸函数名永远指 `$LATEST`。
- **异步失败队列迟迟没有消息**：失败后有重试延迟（本实验 1 次重试约 1~2 分钟
  内入队）。解法：轮询窗口放大到 2 分钟。
- **Layer zip 打错层级**：内容必须在 `python/` 前缀下，否则运行时 /opt 里
  找不到模块（真实 AWS 行为，按规范打包）。

深入问答：

- **Q: Layer 解决什么、不适合什么？** A: 解决多函数公共依赖重复打包；不适合
  频繁单独变更的依赖（牵连全部挂载者）与超 250MB 解压上限的大依赖。
- **Q: 灰度发布如何做？** A: prod(90%)→v1、canary(10%)→v2 双别名 + 前端按
  比例路由；真实 AWS 支持别名加权路由自动分流。
- **Q: 异步调用的重试与时序？** A: 失败重试 2 次（可配 0~2），事件顺序无保证；
  需要顺序用同步调用或状态机编排。
- **Q: Destination 与 DLQ 的区别？** A: Destination 携带完整响应/错误详情、
  支持 SQS/SNS/EventBridge/Lambda；DLQ 是旧机制仅 SQS/SNS，推荐 Destination。

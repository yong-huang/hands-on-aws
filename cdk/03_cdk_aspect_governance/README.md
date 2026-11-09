# 03 · Aspect 治理：标签强制与合规拦截

> 手写访问者扫遍构造树：给每个可打标资源盖强制标签，把"L2 未加密 / L1 绕过 /
> 通配 IAM"三类违规在合成期一次拦下，再验证修复路径。平台工程的 IaC 护栏雏形。

## Background

cdk/01 看清了 L2 默认值，cdk/02 学会了封装构造——但团队规模一大就会遇到
治理问题：谁都能绕过你的"标准构造"直接写 L1 裸桶，谁都能塞一条
`Action: "s3:*"` 的策略。约定靠自觉，护栏靠机制。

CDK 的机制是 **Aspect（切面）**：官方形式 `Aspects.of(stack).add(aspect)`
在合成时对构造树上**每个节点**调用一次 `visit()`——与 `Tags.of()` 批量打标
是同一底层机制。访问者可以做两件事：改（打标、注入配置）和查（累积违规，
合成期一次抛出）。检查放在合成期意味着违规进不了部署，成本最低。

## What

一句话定义：`TaggingAspect` 给每个带 `tags` 能力的节点盖 owner/lab 两个
标签（含 L1 裸桶）；`ComplianceAspect` 累积三类违规——L2 桶无加密配置、
L1 裸桶绕过加密、IAM 语句含精确 `*`——合成完成后一次性列出并以退出码 1
拦截。

心智模型：Aspect 是"质检机器人"沿流水线（构造树）逐站巡检；违规不是
"看到一条报一条"，而是攒齐了一次性报全——否则修一条跑一遍才知道还有下一条。

## When to Use

典型场景：

- 组织级强制标签（成本归集 owner/cost-center），不允许"忘了打标"。
- 合规基线：加密、公网阻断、IAM 不许通配——在 synth 期而不是审计期发现。
- 治理既覆盖 L2 也覆盖 L1 绕过：巡检对象是构造树节点，L1 裸资源无所遁形。

何时不用：检查目标只在合成产物（模板 JSON）层面——用 Post-scan 或
assertions（cdk/04）更直接；单个栈自己管自己——约定写在构造库里更轻。

## Quick Start

前置条件同 cdk/01/32。运行方式：

```bash
cd cdk/03_cdk_aspect_governance
./cdk_aspect_governance.sh     # apply（部署合规+修复栈）→ observe（拦截断言）→ clean
```

三种形态（`-c` context 切换）：`mode=good` 合规样板；`mode=bad` 违规样例
（3 条违规一次列全、退出码 1）；`mode=bad -c fix=1` 同一套代码的修复路径。
observe 阶段 10 条断言全绿即通过。

## How It Works

`cdk_app/app.py`（~160 行）：

- `TaggingAspect.visit(node)`：鸭子类型判定可打标（`hasattr(node, "tags")`
  且 `set_tag` 可调用——ITaggable 是非 runtime_checkable 的 Protocol，
  `isinstance` 会直接抛 TypeError），盖 owner=platform-team、lab=ho03。
- `ComplianceAspect.visit(node)`：桶检查统一看 `CfnBucket.bucket_encryption
  is None`——L2 未加密与 L1 绕过在此收敛为同一终态，再按父级类型区分标记
  `[L2]`/`[L1-绕过]`；IAM 检查用 `Policy.document.to_json()`（dict）扫描
  语句，`Action`/`Resource` 精确等于 `"*"` 判违规（arn 前缀 `/*` 不算）。
- `apply_aspects(stack, *aspects)`：`stack.node.find_all()` 后逐节点 visit——
  这是 `Aspects.of().add()` 的等价内部实现（为何手动见踩坑第 1 条）。
- 违规拦截在 `app.synth()` 之后：`report_or_none()` 一次打印全部违规并
  `sys.exit(1)`，cdklocal synth 退出码非零，CI 直接失败。

修复路径 `fix=1` 的对照：L2 桶 `UNENCRYPTED → S3_MANAGED`；L1 裸桶构造时
显式传 `bucket_encryption`（L1 的修复就是"把模板字段写全"）；IAM 通配改为
`s3:GetObject` + `arn 前缀/*`。observe 断言修复后模板净化、线上标签齐全。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **`Aspects.of(x).add()` 触发 `Don't know how to convert object to JSON`**：
  Python 实现的 aspect 对象进不了 jsii 内核序列化（Python 3.13 + jsii 1.140/
  1.142 + aws-cdk-lib 2.268/2.274 全实测，`@jsii.implements` 亦无效，
  见 aws/jsii#576 一脉）。解法：`find_all()` + `visit()` 手动应用——与
  Aspects 内部实现等价，visit 语义不变；TS 团队不受影响。
- **`isinstance(node, ITaggable)` 直接抛 TypeError**：ITaggable 是非
  runtime_checkable Protocol。解法：鸭子类型（本实验方案），或自定义
  runtime_checkable 协议。
- **`Aspects.of(app)` 挂 App 级同样炸**：不是挂载层级问题，是序列化问题。
- **CfnBucket 的 python kwarg 走 jsii struct**：嵌套结构键是 camelCase
  （`serverSideEncryptionConfiguration`），写模板 PascalCase 会报
  `Missing required properties`。
- **deploy 会重新合成**：不带 mode context 的 deploy 只合成默认 good 栈，
  导致 `No stacks match ho03-bad-stack`。解法：deploy/destroy 各自带上
  `-c mode=... -c fix=...`。
- **"0 违规"的假阴性**：拦截逻辑写好了但没人调用 `report_or_none()`，
  成功信息里硬编码"0 违规"骗过所有人。解法：断言退出码 + 违规条数，
  不信 stdout 的成功话术。

深入问答：

- **Q: Aspect 与 assertions 测试（cdk/04）的边界？** A: 都在合成期工作。
  Aspect 深入构造树内部、能改能查、随每次 synth 自动运行；assertions 对
  合成产物（模板 JSON）做测试断言、只读、随 pytest 运行。组织护栏用
  Aspect，单仓库质量门用 assertions，两层互补。
- **Q: 违规要不要 fail-fast？** A: 不要。逐条抛出会让团队陷入
  "修一条→跑一遍→再见下一条"的循环；累积一次列全（本实验方案）把
  修复成本从 O(n) 轮合成降到 1 轮。
- **Q: 标签打在 Stack 上和打在每个资源上有何区别？** A: Stack 标签由
  CFN 传播（部署后资源可见，但模板资源段里看不到）；逐资源打标写进每个
  资源的 Tags 属性，模板自描述、审计工具可直接扫描。本实验两者都生效。
- **Q: 为什么 IAM 检查用 `to_json()` 而不是语句对象？** A: aws-cdk-lib
  2.268 的 Python 侧 `PolicyDocument` 只暴露 `add_statements`/
  `statement_count`，语句列表属性未暴露；`to_json()` 返回 dict，是拿到
  全部语句的稳定通道。

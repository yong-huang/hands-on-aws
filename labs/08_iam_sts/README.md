# 08 · IAM 身份与权限：用户、角色与临时凭证

> 前面的实验都是"root 视角"一把梭。真实 AWS 里，每个动作都要回答三件事：**谁**
>（身份）、**能做什么**（策略）、**怎么证明**（凭证）。IAM 定义前两者，STS 发放
> 一次性凭证。本实验创建最小权限用户、演示 AssumeRole 换角色，并**如实记录**
> LocalStack 不执行资源级授权这一重要差异。

## 1. 为什么需要它

- **最小权限原则**：应用不该拿着管理员密钥跑。给 alice 只读 S3 一个桶的策略，
  是权限设计的起点。
- **角色优于密钥**：长期 AccessKey 会泄漏、要轮换；`AssumeRole` 换来的临时凭证
  15 分钟自动过期，无需注销——跨账号访问、EC2/Lambda 的执行角色全靠它。
- 不理解身份与凭证机制，后面所有实验的 `role` 参数就只是抄来的咒语。

## 2. 总览：核心机制一图看懂

![IAM 与 STS](images/iam_sts.svg)

> 怎么看：alice 持长期密钥（左侧实线）证明身份；通过 AssumeRole 用**信任策略**
> 换取角色的临时三元组（AccessKeyId/Secret/SessionToken，虚线），之后以
> `assumed-role` 身份访问资源。策略文档声明"能做什么"，信任策略声明"谁可以
> 扮演"——两个文件缺一不可。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/08_iam_sts/images/iam_sts.html)
> （或本地打开 [`images/iam_sts.html`](images/iam_sts.html)）。

心智模型一句话：**策略回答"能做什么"，信任策略回答"谁可以来"，STS 负责发"限时门票"。**

## 3. 快速开始

```bash
cd labs/08_iam_sts
./iam_sts.sh            # apply → observe → clean（约 20 秒）
./iam_sts.sh observe    # 只跑身份/AssumeRole 演示
```

真实运行输出（节选）：

```text
=====> [observe] 身份机制：alice 的密钥 → sts get-caller-identity 显示 her ARN
  ✅ 密钥确证身份: arn:aws:iam::000000000000:user/ho08-alice
=====> [observe] AssumeRole：alice 换取角色临时凭证（有效期 15 分钟）
  ✅ 临时凭证身份: arn:aws:sts::000000000000:assumed-role/ho08-reader-role/demo-session
=====> [observe] 越权行为实测（如实记录，不作为断言）
  ⚠️  alice 只有 s3:GetObject 权限，却 PutObject 成功 —— LocalStack 不执行 IAM 授权
  ⚠️  真实 AWS 此处返回 AccessDenied
```

## 4. 核心概念

### 4.1 用户、组与策略的挂法

策略不直接挂在用户上，而是挂在**组**上（alice 随组获得权限）；这对应真实组织
的"岗位"模型。策略是纯声明式 JSON：`Effect + Action + Resource`。

### 4.2 AssumeRole：临时凭证三元组

`sts assume-role` 返回 `AccessKeyId + SecretAccessKey + SessionToken`——**三个
都带上**才能用（缺 SessionToken 直接 403）。实测换到的身份是
`arn:aws:sts::...:assumed-role/ho08-reader-role/demo-session`，15 分钟后自动失效。

### 4.3 信任策略 vs 权限策略

角色有两份文件：信任策略（`configs/trust-policy.json`）声明"alice 可以扮演我"；
权限策略声明"扮演我的人能干什么"。AssumeRole 要求**两边同时点头**——这是双向
确认模型，比单向授权安全。

### 4.4 LocalStack 的能力边界（重要，如实记录）

- IAM 的**身份与凭证机制**（用户/密钥/AssumeRole/临时凭证）真实可用 ✅；
- **资源级授权不执行**：alice 只有 `s3:GetObject` 却能 PutObject 成功（实测）；
  `ENFORCE_IAM` 在此构建无效，策略模拟器 API 也不可用；
- 因此本实验的断言全部围绕"机制"，越权行为用 `⚠️` 记录而非断言——**诚实标注
  模拟能力边界，正是从本地走向真实 AWS 必备的知识**。

## 5. 配置关键字段（configs/*.json）

```jsonc
// trust-policy.json —— 谁可以扮演这个角色
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::000000000000:user/ho08-alice" },  // 可信主体
    "Action": "sts:AssumeRole"
  }]
}

// user-policy.json —— 最小权限：只读一个桶
{
  "Statement": [{
    "Sid": "minimal-s3-read",
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::ho08-vault",        // ListBucket 面向桶本身
      "arn:aws:s3:::ho08-vault/*"       // GetObject 面向对象，两个 ARN 都要
    ]
  }]
}
```

坑清单：

- 删用户前要依次解绑组、删密钥、解绑策略——`EntityAlreadyExists` 残留多半是
  清理顺序不对（本脚本已按序处理）；
- 组上的策略也要 detach 才能删组；
- `ListBucket` 的 Resource 是桶 ARN，`GetObject` 是 `bucket/*`——最经典的 ARN
  层级考题。

## 6. 文件结构

```text
labs/08_iam_sts/
├── README.md               # 本文件
├── iam_sts.sh              # 主演示脚本：建身份 → 验身份 → 换角色 → 越权实测 → 清理
├── configs/
│   ├── trust-policy.json   # 角色信任策略（谁可 AssumeRole）
│   └── user-policy.json    # 最小权限策略（只读指定桶）
└── images/
    ├── iam_sts.architecture.json  # 图源（Typed JSON IR）
    ├── iam_sts.html               # 交互版
    └── iam_sts.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: 用户与角色的本质区别？** A: 用户是"身份+长期凭证"，角色是"可被扮演的
  权限集合"本身无凭证；任何人（或服务）AssumeRole 后获得临时凭证。
- **Q: 临时凭证过期前能吊销吗？** A: 可以，通过更新角色的权限边界或吊销会话
  （revoke-sessions），但单一凭证本身不可删除——到期即焚是设计而非缺陷。
- **Q: AssumeRole 为什么要求双向授权？** A: 调用方需要 `sts:AssumeRole` 权限，
  目标角色信任策略要包含调用方——两侧任一缺失都被拒，防止权限意外提升。
- **Q: 什么是权限边界（Permissions Boundary）？** A: 策略的"上限钳"：实际权限
  = 身份策略 ∩ 边界策略；用来委派"可以发策略但发不出边界之外"的管理员。
- **Q: LocalStack 的 IAM 缺陷对学习的影响？** A: 资源 API 不校验策略，权限的
  "效果"验证不了，但"结构"（谁是谁、谁能扮演谁）完整可用；策略评估的最终验证
  要去真实 AWS 或 AWS Policy Simulator。

## 8. 总结

身份、凭证、角色、信任——AWS 权限模型的骨架在本实验全部动手搭了一遍，同时
精确标记了模拟器的能力边界。下一篇切换工程化视角：把前面的手工操作压缩成
Terraform 与 CloudFormation 的声明式模板——基础设施即代码。

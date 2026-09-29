# 08 · IAM 身份与权限：用户、角色与临时凭证

> AWS IAM（Identity and Access Management）是定义"谁能做什么"的权限服务；
> STS（Security Token Service）负责签发限时临时凭证。本实验创建最小权限用户、
> 演示 AssumeRole 换角色，并如实记录 LocalStack 不执行资源级授权的差异。

## Background

在统一权限模型出现之前，多服务协作的授权靠"共享管理员密钥"：应用配置里写
root 账号的 AccessKey，所有服务用同一把钥匙调 AWS API。

共享密钥撞上三堵墙。第一，无法区分责任：出了事查不到是哪个应用干的。第二，
无法收敛权限：本来只需要读一个桶的应用，拿着能删整个账号的钥匙。

第三，密钥泄漏后只能全量轮换，牵一发而动全身。IAM 把这些拆开：每个主体（用户
或角色）有独立身份与策略文档；需要跨身份授权时由 STS 签发限时临时凭证，到期
自动失效。

## What

一句话定义：IAM 是 AWS 的身份与权限管理服务，用用户（长期身份）、角色（可被
扮演的权限集合）和策略（JSON 权限文档）回答"谁能对什么做什么"。

心智模型：可以把角色想象成一张"岗位工牌"——工牌本身不隶属任何个人，权限写在
工牌上（权限策略），另外贴着一张"谁能来领这张工牌"的说明（信任策略）。

但和真实工牌不同的是：领取时不发实体卡，而是发一张 15 分钟后自动销毁的临时
通行证（AccessKeyId + SecretAccessKey + SessionToken 三元组），续用需重新
领取。

三份关键文档：

- **权限策略**：声明 Action 与 Resource 的 Allow/Deny（如"只读 ho08-vault 桶"）。
- **信任策略**：声明哪个主体可以 `sts:AssumeRole` 扮演这个角色。
- **队列/桶资源策略**：挂在资源上，与身份策略并行的另一道闸门。

## When to Use

典型场景：

- 应用最小权限化：给每个服务独立的用户或角色，只授必要 Action。
- 跨身份临时授权：人 or 服务通过 AssumeRole 换角色，不复制任何长期密钥。
- 云上服务的执行身份：Lambda/EC2（弹性云虚拟机）的执行角色就是"服务替你 AssumeRole 的角色"，
  本系列所有实验传的 `--role` 参数对应真实 AWS 的这个机制。

何时不用：本机 LocalStack 的学习验证之外，生产环境不要创建长期 AccessKey 给
人类日常操作——人类应该用 SSO/联合登录换临时凭证；单一账号内的简单场景也不
需要 AssumeRole 链。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| IAM 用户 + AccessKey | 长期凭证，静态 | 仅限无法换临时凭证的遗留集成 |
| IAM 角色 + STS | 临时凭证、自动过期 | 应用与服务的默认选择 |
| IAM Identity Center | 联合登录、SSO | 人类操作者的日常入口 |
| 资源策略（桶/队列策略） | 挂在资源上授权 | 跨账号资源访问、服务主体授权 |

## Quick Start

前置条件：LocalStack 运行中。注意：LocalStack 支持 IAM 的身份与凭证机制
（用户/密钥/AssumeRole），但**不执行**资源级授权——本实验的越权行为用 `⚠️`
如实记录而非断言。运行方式：

```bash
cd labs/08_iam_sts
./iam_sts.sh            # apply → observe → clean（约 20 秒）
./iam_sts.sh observe    # 只跑身份/AssumeRole 演示
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] 身份机制：alice 的密钥 → sts get-caller-identity 显示 her ARN
  ✅ 密钥确证身份: arn:aws:iam::000000000000:user/ho08-alice
=====> [observe] AssumeRole：alice 换取角色临时凭证（有效期 15 分钟）
  ✅ 临时凭证身份: arn:aws:sts::000000000000:assumed-role/ho08-reader-role/demo-session
  ✅ 有效期至: 2026-09-06T16:01:47.263704+00:00（到期自动失效，无需注销）
=====> [observe] 越权行为实测（如实记录，不作为断言）
  ⚠️  alice 只有 s3:GetObject 权限，却 PutObject 成功 —— LocalStack 不执行 IAM 授权
```

信任策略与权限策略是两份声明式文档（`configs/trust-policy.json` 与
`configs/user-policy.json`），信任策略的核心片段：

```jsonc
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::000000000000:user/ho08-alice" },  // 可信主体
    "Action": "sts:AssumeRole"
  }]
}
```

新手第一个失败点：AssumeRole 换来的临时凭证**三个都要用**——缺
SessionToken 直接 403。脚本用环境变量方式整组传递。

## How It Works

![IAM 与 STS](images/iam_sts.svg)

> 怎么看：alice 持长期密钥（左侧实线）证明身份；通过 AssumeRole 用**信任策略**
> 换取角色的临时三元组（AccessKeyId/Secret/SessionToken，虚线），之后以
> `assumed-role` 身份访问资源。策略文档声明"能做什么"，信任策略声明"谁可以
> 扮演"——两个文件缺一不可。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/08_iam_sts/images/iam_sts.html)
> （或本地打开 [`images/iam_sts.html`](images/iam_sts.html)）。

**身份如何被证明**：alice 的长期密钥调 `sts get-caller-identity`，返回的 ARN（Amazon Resource Name，AWS 资源的全球唯一地址）就是身份凭证（实测输出 `user/ho08-alice`）——"密钥对应谁"由 IAM 回答。

**临时凭证如何签发**：`sts assume-role` 校验两件事——调用方有
`sts:AssumeRole` 权限，且角色信任策略包含调用方。双向通过后 STS 返回三元组，
之后所有请求以 `assumed-role/角色名/会话名` 身份发出（实测断言），15 分钟后
自动失效。

**双向授权为什么安全**：只有权限策略 → 任何知道角色 ARN 的人都能扮演；只有
信任策略 → 扮演后权限不受控。两边同时点头才生效，防止权限意外提升。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **删用户报残留/重建报 `EntityAlreadyExists`**：清理顺序不对——先解绑组、
  删访问密钥、解绑策略，再删用户；组上的策略也要先 detach（脚本 apply 按序
  处理）。
- **临时请求 403**：三元组缺 SessionToken，或角色信任策略没包含调用方。
- **`ListBucket` 能用 `GetObject` 被拒（或反之）**：两条 Action 的 Resource
  层级不同——ListBucket 是桶 ARN，GetObject 是 `bucket/*`，都要声明。
- **LocalStack 不拦越权操作**：Community 版不执行资源级授权（实测 alice 只有
  GetObject 却 PutObject 成功）。解法：效果验证去真实 AWS 或 AWS Policy
  Simulator。

深入问答：

- **Q: 用户与角色的本质区别？** A: 用户是"身份 + 长期凭证"；角色是可被扮演的
  权限集合，本身无凭证，任何被信任的主体 AssumeRole 后获得临时凭证。
- **Q: 临时凭证能提前吊销吗？** A: 单个凭证不可删除，但可以更新角色的策略或
  吊销会话，让既有凭证立即失效。
- **Q: 权限边界（Permissions Boundary）是什么？** A: 策略的"上限钳"——实际
  权限 = 身份策略 ∩ 边界策略，用于委派"能发策略但发不出边界之外"的管理员。
- **Q: LocalStack 的 IAM 缺陷影响学习吗？** A: 影响"效果"验证不影响"结构"
  验证——谁是谁、谁能扮演谁完整可用；策略评估结论需真实 AWS 确认。

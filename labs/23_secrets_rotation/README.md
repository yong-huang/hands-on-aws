# 23 · Secrets Manager 轮换与治理：staging labels 与四步轮换

> Amazon Secrets Manager 是托管机密服务，在"存取"之上提供版本化与轮换：新密码
> 先写入 AWSPENDING 暂存，验证通过后把 AWSCURRENT 标签移过来，旧版本降为
> AWSPREVIOUS。本实验跑通 v1→v2 无感轮换、标签对账与四步轮换的关键步骤。

## Background

在机密服务出现之前，应用密码的更新靠"改配置 + 重启"：数据库改密码的那一刻，
所有用旧密码的应用断连，运维要在几秒内同步改完所有配置并重启。

这种做法撞上三堵墙。第一，停机窗口：新旧密码无法共存，改密码等于约定一次
集体停机。第二，无法回滚：改错了只能再改回来，期间持续断连。第三，无审计：
谁改过、用过、有没有泄漏，全无记录。

Secrets Manager 的解法是给每个机密维护
版本链：版本由 staging label（AWSCURRENT / AWSPREVIOUS / AWSPENDING 三个
浮动标签）标记状态，"轮换"就是按四步舞步安全地移动标签。

## What

一句话定义：Secrets Manager 的轮换机制把"更新密码"拆成四个原子步骤——
createSecret（写新值到 AWSPENDING）、setSecret（在数据库侧设置新密码）、
testSecret（用新密码连通验证）、finishSecret（移动 AWSCURRENT 标签）。

四个步骤由一个轮换 Lambda 按 Step 参数依次驱动。

心智模型：可以把 AWSPENDING 想象成新员工的试用期——先入职试用（新密码写入
但不生效），通过考核（testSecret 用新密码连通成功）才转正（finishSecret 移
动 AWSCURRENT 标签）；转正的同时旧员工自动变成"备岗"（AWSPREVIOUS），随时
可以顶上（回滚）。

但和真实员工不同的是：试用期与转正在本机构建里需要手动
驱动（托管执行非确定性，实测如实记录）。

三个标签：

- **AWSCURRENT**：消费方默认读取的当前有效版本。
- **AWSPREVIOUS**：上一版，回滚通道。
- **AWSPENDING**：轮换中的新版本，尚未发布。

## When to Use

典型场景：

- 数据库凭据定期轮换：安全基线要求 30/60/90 天一换，自动轮换把焦虑变成配置。
- 泄漏应急：密钥疑似泄漏时立即轮换，消费方无感切换。
- 版本回滚：轮换后出问题，把标签移回旧版本即可恢复。

何时不用：一次性配置（改了重启即可）；Secrets Manager 计费敏感且机密数量
巨大时可考虑 SSM SecureString + 自建轮换（lab 20 的对比表）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Secrets Manager 自动轮换 | 内置四步轮换模板，按计划执行 | 数据库凭据的标准选择 |
| SSM + 自建轮换 | 免费，逻辑自写 | 机密多但轮换要求低 |
| 手工轮换 | 零成本，停机与人为风险 | 一次性或极低频场景 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/23_secrets_rotation
./secrets_rotation.sh            # v1→v2 → labels 对账 → 四步轮换 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] 轮换 v1→v2：新值成为 AWSCURRENT，旧值落入 AWSPREVIOUS
  ✅ 消费方读取 AWSCURRENT 无感拿到 v2
  ✅ AWSPREVIOUS 仍可读 v1（回滚通道）
=====> [observe] createSecret：新凭据写入 AWSPENDING
  ✅ createSecret：新凭据写入 AWSPENDING
=====> [observe] AWSCURRENT 已是轮换后的值（消费方无感切换）
  ✅ AWSCURRENT 已是轮换后的值
```

四步轮换 Lambda 的核心逻辑（脚本内嵌的 `ho23_rotator.py`）——create 写
PENDING、finish 移标签：

```python
if step == "createSecret":
    nxt = dict(cur, password="pass-v3-rotated")   # 固定目标值，重复轮换幂等
    sm.put_secret_value(SecretId=arn, SecretString=json.dumps(nxt),
                        VersionStages=["AWSPENDING"])
if step == "finishSecret":
    desc = sm.describe_secret(SecretId=arn)
    stages = desc["VersionIdsToStages"]
    pending = [vid for vid, st in stages.items() if "AWSPENDING" in st]
    current = [vid for vid, st in stages.items() if "AWSCURRENT" in st]
    sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                                   RemoveFromVersionId=current[0],
                                   MoveToVersionId=pending[0])
```

新手第一个失败点：`put_secret_value` 的参数是 **`VersionStages`（复数
列表）**，写成 `VersionStage` 会报参数校验错。

## How It Works

![Secrets 轮换与治理](images/secrets_rotation.svg)

> 怎么看：rotate-secret 配置轮换 Lambda 与周期；四步中的关键两步——
> createSecret 把新凭据写进 AWSPENDING（暂存不生效），finishSecret 把
> AWSCURRENT 标签移到暂存版本（消费方下次读到即新值）；旧版本自动降为
> AWSPREVIOUS。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/23_secrets_rotation/images/secrets_rotation.html)
> （或本地打开 [`images/secrets_rotation.html`](images/secrets_rotation.html)）。

**v1→v2 如何无感切换**：`put-secret-value` 写入新值时，服务自动把 AWSCURRENT
标签移到新版本，旧版本降为 AWSPREVIOUS。

实测两组断言：AWSCURRENT 读到 v2、AWSPREVIOUS 读到 v1——消费方不改任何代码。

**四步轮换如何驱动**：`rotate-secret` 配置轮换 Lambda 后，本机的托管执行为
非确定性（实测如实记录），脚本改为手动按 Step 调用——createSecret 写入
AWSPENDING（断言通过），finishSecret 把标签移过去（实测断言 AWSCURRENT 变为
新值）。

这与真实 AWS 的四步语义完全同构。

**资源策略如何收敛读取**：`put-resource-policy` 限定"只有指定角色可
GetSecretValue"（配置成功）；执行鉴权本构建不实施（lab 08 的边界）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **put_secret_value 报 Unknown parameter VersionStage**：参数名是
  `VersionStages`（复数列表）。
- **标签移动报 RemoveFromVersionId 为空**：本构建要求显式传版本 ID——先
  describe 查出 AWSCURRENT 与 AWSPENDING 各自的版本 ID，再移动标签。
- **重复轮换密码叠加后缀**：轮换目标值不固定（如 `old + "-rotated"`）。解法：
  目标值幂等（本实验固定为 `pass-v3-rotated`）。
- **托管轮换非确定性**：rotate-secret 配置成功但不保证立即执行 Lambda。
  解法：按 Step 手动驱动做确定性验证。

深入问答：

- **Q: 四步为什么缺一不可？** A: create 备好新值、set 真正改数据库、test 用
  新密码连通验证、finish 才发布——顺序保证任何一步失败都能回退且服务不断。
- **Q: 轮换期间旧连接会断吗？** A: 已建立的连接用旧密码仍有效（直到数据库
  踢出）；新连接读 AWSCURRENT。双用户策略（准备管理、应用两个数据库账号交替更新，保证切换窗口内总有可用
  凭据）覆盖切换窗口。
- **Q: AWSPREVIOUS 保留几代？** A: 默认只上一代；需要更长历史就自定义标签
  （如 PRODUCTION）自行管理。
- **Q: 消费方如何无感？** A: 永不缓存明文、每次或定期重读 AWSCURRENT；连接
  池认证失败时重读一次再重试。

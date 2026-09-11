# 23 · Secrets Manager 轮换与治理：staging labels 与四步轮换

> lab 07 会存会取 Secret；生产级问题是"密码泄露了/到了轮换周期，怎么换才不炸"。
> 答案是**staging labels**：新密码先写到 AWSPENDING、消费方无感、验证通过后
> 提升 AWSCURRENT、旧值降 AWSPREVIOUS——四步轮换的标准舞步。本实验完整走一遍。

## 1. 为什么需要它

- 静态密码终会泄露；**自动轮换**把"换了没"从运维焦虑变成配置项。
- 直接改 AWSCURRENT 会让使用旧密码的连接全部失败——PENDING 缓冲期让新旧密码
  共存，双活切换。
- 出问题可回滚：AWSPREVIOUS 里的旧密码仍然可读。

## 2. 总览：核心机制一图看懂

![Secrets 轮换与治理](images/secrets_rotation.svg)

> 怎么看：rotate-secret 配置轮换 Lambda 与周期；四步中的关键两步——createSecret
> 把新凭据写进 AWSPENDING（暂存不生效），finishSecret 把 AWSCURRENT 标签移到
> 暂存版本（消费方下次读到即新值）；旧版本自动降为 AWSPREVIOUS。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/23_secrets_rotation/images/secrets_rotation.html)
> （或本地打开 [`images/secrets_rotation.html`](images/secrets_rotation.html)）。

心智模型一句话：**AWSPENDING 是新密码的试用期，标签移动的那一刻才是"发布"。**

## 3. 快速开始

```bash
cd labs/23_secrets_rotation
./secrets_rotation.sh            # v1→v2 → labels 对账 → 四步轮换 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] 轮换 v1→v2：新值成为 AWSCURRENT，旧值落入 AWSPREVIOUS
  ✅ 消费方读取 AWSCURRENT 无感拿到 v2
  ✅ AWSPREVIOUS 仍可读 v1（回滚通道）
=====> [observe] createSecret：新凭据写入 AWSPENDING
  ✅ createSecret：新凭据写入 AWSPENDING
=====> [observe] AWSCURRENT 已是轮换后的值（消费方无感切换）
  ✅ AWSCURRENT 已是轮换后的值
```

## 4. 核心概念

### 4.1 staging labels：指向版本的浮动指针

AWSCURRENT / AWSPREVIOUS / AWSPENDING 是挂在版本上的标签。消费方只读
AWSCURRENT——标签移动即"发布"，读取方无感（实测断言）。describe-secret 的
`VersionIdsToStages` 给出全部版本的标签对账。

### 4.2 四步轮换函数

真实轮换 Lambda 处理四种 Step：`createSecret`（写 PENDING）、`setSecret`（在
数据库里设新密码）、`testSecret`（用新密码连一次）、`finishSecret`（提升标签）。
本实验实现 create/finish 两步并手动驱动（本机构建的托管执行为非确定性，如实
记录）；骨架即生产四步轮换的模板。

### 4.3 本机 API 差异实录

- `put_secret_value` 用 `VersionStages=["AWSPENDING"]`（列表）；
- `update_secret_version_stage` 此构建要求 **MoveToVersionId/RemoveFromVersionId
  按版本 ID 显式指定**（不能按 stage 移动）——本实验按错误提示修正后通过。

### 4.4 资源策略：读权限收敛

put-resource-policy 限定"只有 ho23-consumer 角色能 GetSecretValue"（配置 ✅；
执行鉴权本构建不实施，见 lab 08）——最小权限在密钥治理里的落点。

## 5. 代码关键字段（rotator 骨架）

```python
# createSecret：新值进 AWSPENDING（不生效）
sm.put_secret_value(SecretId=arn, SecretString=json.dumps(nxt),
                    VersionStages=["AWSPENDING"])
# finishSecret：把 AWSCURRENT 标签移到 PENDING 版本（本机需显式版本 ID）
desc = sm.describe_secret(SecretId=arn)
stages = desc["VersionIdsToStages"]
pending = [vid for vid, st in stages.items() if "AWSPENDING" in st]
current = [vid for vid, st in stages.items() if "AWSCURRENT" in st]
sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                               RemoveFromVersionId=current[0],
                               MoveToVersionId=pending[0])
```

坑清单：

- put_secret_value 的参数是 `VersionStages` 复数列表；
- stage 移动在本机构建必须显式版本 ID（真实 AWS 支持按 stage 移动）；
- 轮换目标值要**幂等**（固定值或按时间生成），否则重复轮换叠加后缀；
- rotate-secret 配置后托管执行本机非确定性——按四步手动驱动验证最可靠。

## 6. 文件结构

```text
labs/23_secrets_rotation/
├── README.md                 # 本文件
└── secrets_rotation.sh       # 主脚本：v1→v2 → labels 对账 → 四步轮换 → 清理
                              # 轮换 Lambda 骨架由脚本生成（/tmp），核心逻辑见脚本内嵌
```

> 注：图片三件套见 `images/`。

## 7. 深入要点

- **Q: 四步轮换为什么需要 setSecret/testSecret？** A: create 只是"准备好"；set
  真正改数据库侧密码；test 用新密码连通验证；全部通过才 finish——顺序保证
  任何一步失败都能回退且服务不中断。
- **Q: 轮换期间正在使用旧密码的连接会断吗？** A: 不会立即断：已建立的连接用旧
  密码仍有效（直到数据库踢出）；新连接用 AWSCURRENT。双用户策略（新旧并存）
  覆盖切换窗口。
- **Q: AWSPREVIOUS 会保留几代？** A: 默认只保留上一代；需要更多历史就自定义
  标签（如 PRODUCTION）自行管理。
- **Q: 如何让消费方"无感"？** A: 消费方永不缓存密码明文、每次/定期重读
  AWSCURRENT；连接池在认证失败时重读一次再重试（标准 workaround）。
- **Q: 资源策略与 IAM 策略的叠加关系？** A: 资源策略是 Secret 级的附加授权，
  与 IAM 身份策略任一允许即可通过（同 S3 bucket policy 模型）。

## 8. 总结

staging labels 的移动就是密钥的"发布流程"：PENDING 试用 → 提升发布 → 旧版回滚
通道，四步轮换骨架可以直接搬进生产。下一篇把视角拉到全链路：S3-KMS 信封加密、
Grant 最小授权与撤销验证。

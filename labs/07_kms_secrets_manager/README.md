# 07 · KMS + Secrets Manager：信封加密与机密轮换

> 数据库密码硬编码在代码里，等于把家门钥匙焊在门上。AWS 的答案分两层：**KMS**
> 守护"加密这件事本身"（主密钥永不离开服务），**Secrets Manager** 管理"机密的
> 一生"（存储、版本、轮换）。本实验跑通加解密闭环、2MB 文件的信封加密和
> v1→v2 的无感轮换。

## 1. 为什么需要它

- **密钥与数据分离**：KMS 的主密钥（CMK）永远不可导出，加解密只能"请求服务代劳"；
  泄漏的密文没有 CMK 就是乱码。
- **大文件不能都发给 KMS**：信封加密——KMS 只加密一个 32 字节的"数据密钥"，
  海量数据用本地 AES 加密，性能与安全兼得。
- **机密需要版本而非覆盖**：轮换出新密码时旧的要能回滚，消费方要无感切换。

## 2. 总览：核心机制一图看懂

![KMS 与 Secrets Manager](images/kms_secrets_manager.svg)

> 怎么看：信封加密两条线——小流量走 KMS（encrypt/decrypt API，实线主路径），
> 大数据走本地 AES（虚线），两者靠"被 CMK 包裹的数据密钥"衔接；Secrets Manager
> 则按 staging label（AWSCURRENT/AWSPREVIOUS）管理版本链。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/07_kms_secrets_manager/images/kms_secrets_manager.html)
> （或本地打开 [`images/kms_secrets_manager.html`](images/kms_secrets_manager.html)）。

心智模型一句话：**CMK 加密"密钥"，密钥才加密"数据"；机密靠版本流转而非改文件。**

## 3. 快速开始

```bash
cd labs/07_kms_secrets_manager
./kms_secrets_manager.sh            # apply → observe → clean（约 20 秒）
./kms_secrets_manager.sh observe    # 只跑四组演示断言
```

真实运行输出（节选）：

```text
=====> [observe] 信封加密：KMS 只加密数据密钥，大文件用本地 AES 加密
  ✅ 2MB 信封加密往返一致（KMS 只碰 32B 密钥，不碰 2MB 数据）
=====> [observe] Secrets Manager 版本化：v1 → v2，AWSCURRENT / AWSPREVIOUS 流转
  ✅ 轮换后读到 v2
  ✅ AWSPREVIOUS 仍可读 v1（回滚通道）
=====> [observe] 加密上下文（EncryptionContext）：额外绑定身份的防篡改机制
  ✅ 带对的上下文才能解密
```

## 4. 核心概念

### 4.1 CMK 与别名

`create-key` 生成对称 CMK，`create-alias` 给它起人话名字（`alias/ho07-demo`），
代码里永远引用别名——轮换密钥时只改别名指向，代码零改动。密文比明文大（实测
29B → 100B）：密文携带密钥标识、算法、加密上下文等元数据。

### 4.2 信封加密三步

1. `generate-data-key`：拿到明文数据密钥（本地用）+ CMK 包裹的密文（随文件存）；
2. 本地 `openssl enc -aes-256-cbc` 加密大文件——**数据不出机器**；
3. 解密时先 `decrypt` 包裹的密钥，再解文件。实测 2MB 随机数据往返一致。

### 4.3 EncryptionContext：密文的"信封备注"

键值对（如 `{"app":"ho07"}`）被**签入密文**：解密时上下文不一致直接失败（实测
验证正反两例）。用途：把"这段密文属于谁"绑进密文，防止密文被挪用到别的场景。

### 4.4 Secret 版本化与 staging label

`put-secret-value` 不覆盖而是**新增版本**：`AWSCURRENT` 移到 v2，v1 自动降为
`AWSPREVIOUS` 仍可读（实测断言）。消费方永远只读 AWSCURRENT，轮换对它们透明。

## 5. 命令关键字段

```bash
awslocal kms encrypt --key-id alias/ho07-demo \
    --plaintext fileb:///tmp/pt.bin \        # fileb=二进制；CLI 会自动 base64
    --encryption-context '{"app":"ho07"}'    # 签进密文的身份备注

awslocal kms generate-data-key --key-id alias/ho07-demo --number-of-bytes 32
#   → Plaintext（本地 AES 用）+ CiphertextBlob（随文件存的"信封"）

awslocal secretsmanager put-secret-value --secret-id ho07/db-password \
    --secret-string '{"username":"app","password":"v2-new-password"}'   # 新版本非覆盖
```

坑清单：

- `--plaintext` 传二进制必须 `fileb://`，`file://`（文本按 base64 读）会解出乱码；
- KMS 返回的 `CiphertextBlob/Plaintext` 都是 base64，落盘成二进制要先解码；
- openssl 的 `-K`/`-iv` 要**满长度 hex**（AES-256 密钥 64 位 hex、IV 32 位 hex），
  短了会静默补零；
- LocalStack 删除密钥是"计划删除"（默认 30 天窗口），`--pending-window-in-days 7`
  只是最短窗口，不会物理消失——幂等重跑要按 Description 找旧键清理。

## 6. 文件结构

```text
labs/07_kms_secrets_manager/
├── README.md                  # 本文件
└── kms_secrets_manager.sh     # 主演示脚本：建键/Secret → 四组演示 → 清理
                                # （本实验全部操作经由 API，无声明式配置目录）
```

## 7. 面试要点

- **Q: 信封加密为什么快？** A: KMS 只加密 32B 数据密钥（一次 API 调用），GB 级
  数据用本地 AES-GCM 加密；KMS 吞吐有限（默认5500次/秒），信封加密把调用次数
  与数据量解耦。
- **Q: EncryptionContext 能防什么、不能防什么？** A: 防密文挪用与篡改（签入密文），
  不是访问控制；未授权者仍可能被授权解密，只是解不出"别处"的密文。
- **Q: KMS 自动轮换轮换的是什么？** A: 只轮换 CMK 的**后端密钥材料**，历史密文
  仍可解；KeyId 与别名不变。手动轮换则是新 CMK + 改别名。
- **Q: Secret 轮换时消费方如何无感？** A: 消费方只读 AWSCURRENT；四步轮换策略
  （create/set/finish/test）由 Lambda 驱动，新旧密码共存窗口保证不中断。
- **Q: KMS 和 Secrets Manager 职责边界？** A: KMS 管"密钥与加解密原语"；
  Secrets Manager 管"机密的生命周期"（存储/版本/轮换/审计），底层用 KMS 加密
  机密本身（SecureString）。

## 8. 总结

信封加密解决了"大数据怎么加密"，版本化 Secret 解决了"密码怎么换"——数据平面
与机密平面都有了标准答案。下一篇进入 IAM 的世界：谁、在什么条件下、能对什么
资源做什么——权限模型的三要素。

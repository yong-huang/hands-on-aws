# 07 · KMS + Secrets Manager：信封加密与机密轮换

> AWS KMS（Key Management Service）是托管加密密钥与加解密操作的服务，密钥永不
> 离开服务本身；Secrets Manager 在其上管理机密（数据库密码等）的存储与版本。
> 本实验跑通加解密闭环、2MB 文件的信封加密和 v1→v2 的无感轮换。

## Background

在托管密钥服务出现之前，应用自己管加密：密钥写配置文件或环境变量，用开源库做
AES 加解密。

自管方案撞上三堵墙。第一，密钥与代码同生共死——拿到代码或配置的人就拿到了
密钥，泄漏无法追溯。第二，轮换靠手工：换一次密钥要重新加密全部历史数据或自己
设计双层加密。

第三，合规审计无从谈起——谁在什么时候用过哪个密钥没有记录。KMS 把密钥放进
服务：密钥永不可导出，加解密只能调 API 请求，每次使用都有 CloudTrail（AWS 的操作审计日志服务）记录；
Secrets Manager 在此之上管理机密的版本与轮换。

## What

一句话定义：KMS 是一种托管密钥服务，提供"密钥永不出服务"的加解密原语；
Secrets Manager 是一种机密管理服务，用版本化的方式存储和轮换敏感字符串。

心智模型：可以把 KMS 的主密钥（CMK，Customer Master Key）想象成银行保管箱的
锁——锁永远不会离开银行，你只能申请"让银行替你锁/开"。

但和真实保管箱不同的是：你还可以请银行发一把"临时钥匙"（data key，数据密钥）
带回家用——回家用它加密 2GB 的文件毫无问题，而那把临时钥匙本身也被主锁锁着
存回银行。

两个服务的分工：

- **KMS**：管加密原语——encrypt / decrypt / generate-data-key / 授权（grant）。
- **Secrets Manager**：管机密生命周期——存储、版本（AWSCURRENT / AWSPREVIOUS /
  AWSPENDING 标签流转）、轮换策略。

## When to Use

典型场景：

- 数据落盘加密：S3 对象、EBS 磁盘（挂给云主机的块存储）、数据库字段用 CMK 加密，密文带审计。
- 信封加密：大文件先本地 AES 加密，只让 KMS 加密 32 字节的数据密钥（本实验
  2MB 实测往返一致）。
- 机密存储与轮换：数据库密码存 Secrets Manager，消费方只读 AWSCURRENT，轮换
  对应用透明。

何时不用：需要超低延迟的本地加密（KMS 每次调用是网络往返，且 Encrypt 明文
上限 4KB——大数据必须走信封加密）；需要用户端到端加密（密钥自己持有，如
Signal 协议）时托管密钥反而不合语义。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| KMS CMK | 密钥托管、API 加解密、可审计 | 通用加密、服务集成（S3/EBS） |
| CloudHSM | 独占的硬件密码机（HSM），满足 FIPS 加密合规标准 | 强合规场景、密钥完全自控 |
| Secrets Manager | 机密生命周期 + 自动轮换 | 数据库凭据、API Key |
| SSM Parameter Store | 免费参数存储（SecureString 走 KMS） | 一般配置、成本敏感（lab 20） |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/07_kms_secrets_manager
./kms_secrets_manager.sh            # apply → observe → clean（约 20 秒）
./kms_secrets_manager.sh observe    # 只跑四组演示断言
```

脚本 observe 阶段的真实输出（节选）：

```text
=====> [observe] KMS 加解密闭环：encrypt → decrypt → 字节级一致
  ✅ 加解密往返一致
=====> [observe] 信封加密：KMS 只加密数据密钥，大文件用本地 AES 加密
  ✅ 2MB 信封加密往返一致（KMS 只碰 32B 密钥，不碰 2MB 数据）
=====> [observe] Secrets Manager 版本化：v1 → v2，AWSCURRENT / AWSPREVIOUS 流转
  ✅ 轮换后读到 v2
  ✅ AWSPREVIOUS 仍可读 v1（回滚通道）
```

信封加密的核心三步（脚本节选，明文数据密钥用 openssl 的 AES-256-CBC 加密
文件）：

```bash
# 1) 向 KMS 要数据密钥：明文自用 + 被包裹的密文随文件存
awsx kms generate-data-key --key-id "$ALIAS" --number-of-bytes 32
# 2) 本地 AES 加密 2MB 文件（数据不出机器）
openssl enc -aes-256-cbc -K "$KEY_HEX" -iv "$IV_HEX" -in big.bin -out big.enc
# 3) 解密时先解开被包裹的数据密钥，再解文件
awsx kms decrypt --ciphertext-blob fileb:///tmp/dk_cipher.bin
```

新手第一个失败点：`--plaintext` / `--ciphertext-blob` 传的是二进制，CLI 参数
必须用 `fileb://`（用 `file://` 会按 base64 文本处理导致解不开）；KMS 返回的
CiphertextBlob 是 base64，落盘前要先解码。

## How It Works

![KMS 与 Secrets Manager](images/kms_secrets_manager.svg)

> 怎么看：信封加密两条线——小流量走 KMS（encrypt/decrypt API，实线主路径），
> 大数据走本地 AES（虚线），两者靠"被 CMK 包裹的数据密钥"衔接；Secrets
> Manager 则按 staging label（AWSCURRENT/AWSPREVIOUS）管理版本链。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/07_kms_secrets_manager/images/kms_secrets_manager.html)
> （或本地打开 [`images/kms_secrets_manager.html`](images/kms_secrets_manager.html)）。

**信封加密的三步回环**：`generate-data-key` 返回明文密钥（本地 AES 用）与被
CMK 包裹的密文（随文件一起存储）。加密 2MB 文件全程只有这 32 字节经过 KMS；
解密时先用 `decrypt` 恢复明文密钥，再解文件——实测往返字节级一致。

密文的 100 字节比明文 29 字节大，多出的部分是密钥标识、算法与上下文等元
数据。

**加密上下文（EncryptionContext）如何防挪用**：键值对（如 `{"app":"ho07"}`）
被签入密文。实测两组对照：带正确上下文可解密，缺上下文直接失败——密文不能
被"搬到别的场景"使用。

**Secret 的版本如何流转**：`put-secret-value` 不覆盖而是新增版本，AWSCURRENT
标签自动移到新版本，旧版降为 AWSPREVIOUS——实测轮换后读到 v2、AWSPREVIOUS
仍可读 v1，消费方无感切换。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **`--plaintext` 用 `file://` 解不开**：`file://` 按文本读，二进制必须
  `fileb://`。
- **KMS 返回值落盘后解不开**：CiphertextBlob/Plaintext 是 base64，写入二进制
  文件前要先解码。
- **openssl 报 key 长度不足**：`-K`/`-iv` 要求满长 hex（AES-256 密钥 64 个
  hex 字符、IV 32 个），短了会静默补零。
- **重复实验建出多个旧 CMK**：LocalStack 删密钥是"计划删除"（不物理消失）。
  解法：按 Description 找旧键清理（脚本 apply 已处理）。

深入问答：

- **Q: 信封加密为什么快？** A: KMS 只加密 32B 数据密钥（一次 API 调用），GB
  级数据用本地 AES-GCM；KMS 吞吐有限，信封加密把调用次数与数据量解耦。
- **Q: EncryptionContext 能防什么？** A: 防密文挪用与篡改（上下文签入密文），
  不是访问控制——未授权者仍可能被授权解密，只是解不出"别处"的密文。
- **Q: KMS 自动轮换轮换的是什么？** A: 只轮换 CMK 的后端密钥材料，历史密文
  仍可解，KeyId 与别名不变；手动轮换则是新 CMK + 改别名。
- **Q: Secret 轮换时消费方如何无感？** A: 消费方只读 AWSCURRENT；四步轮换
  策略（create/set/test/finish）由 Lambda 驱动，新旧密码共存窗口保证不断连
  （lab 23 完整演练）。

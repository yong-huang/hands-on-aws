# 24 · 端到端加密管道：SSE-KMS、Grant 与信封加密

> 本实验把数据加密的三层管道一次做实：S3 的服务端加密（SSE-KMS，对象用指定
> CMK 加密落桶）、KMS Grant（只授"解密"的最小授权并可撤销）、信封加密（KMS
> 只加密数据密钥，大文件本地 AES）。实测 5MB 文件往返一致，并验证 KMS Encrypt
> 的 4KB 明文上限——信封加密存在的理由。

## Background

在托管密钥服务普及之前，应用数据的加密靠自管密钥：密钥写在配置里，用开源库
加解密，密文与密钥放在同一台机器上。

自管方案撞上三堵墙。第一，密钥管理无解——密钥与密文同存，泄漏等于全泄。第二，
授权粒度粗——要么全team都能解密，要么都不能，无法"只授权某个服务解密一个月"。
第三，无审计——谁解密过什么没有记录。

KMS 把密钥托管后，三层管道可以分别落实：
S3 用 SSE-KMS 加密落桶、KMS Grant 做最小授权、信封加密解决大数据与密钥托管
的性能矛盾。

## What

一句话定义：这条管道分三层——存储层用 SSE-KMS（S3 对象以指定 CMK 加密落
桶）、授权层用 Grant（对特定主体授予特定密钥操作的临时许可）、应用层用信封
加密（KMS 只加密 32 字节的数据密钥，大文件由本地 AES 处理）。

心智模型：可以把 KMS 想象成一家"只锁不碰"的锁匠铺——你送去一把钥匙坯
（data key），它锁进保险柜并给你回执（wrapped key）；真正加密货物（数据）
用的是你带回家的复制品（明文 data key）。

但和真实锁匠不同的是：回执丢了可以
凭身份再要一次服务（decrypt），而且每次开锁服务都有台账（CloudTrail 审计）。

三个概念：

- **SSE-KMS**：put-object 时声明 `ServerSideEncryption: aws:kms` 与 CMK，
  对象加密落桶，授权方读取时透明解密（get-object 直接拿回明文，解密由 S3+KMS 自动完成，
  调用方无感）。
- **Grant**：`create-grant --operations Decrypt` 给指定主体授予单项密钥操作，
  可随时 revoke。
- **信封加密**：generate-data-key → 本地 AES 加密数据 → 密文数据密钥随文件
  存储 → 解密时先 KMS decrypt 包裹再解数据。

## When to Use

典型场景：

- 合规落盘：S3 对象、EBS 磁盘、RDS 快照用 CMK 加密，CloudTrail 可审计每次
  解密。
- 最小授权分发：给 Lambda/服务授 Decrypt-only Grant，不用宽泛的 IAM。
- 大文件加密归档：备份、日志、医疗影像——GB 级数据也能高效加密。

何时不用：数据量恒定小于 4KB 且调用量极低时可直接 KMS encrypt；终端到端
加密（密钥完全自持）时托管密钥反而不合语义。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| SSE-S3 | AWS 托管钥匙，无审计/控制力 | 低敏感静态资源 |
| SSE-KMS | 指定 CMK，可审计可授权 | 合规数据（本实验存储层） |
| 客户端信封加密 | 数据不上传明文 | 归档管道、大文件（本实验应用层） |
| CloudHSM | 独占硬件密码机（HSM） | 强合规（FIPS）场景 |

## Quick Start

前置条件：LocalStack 运行中；`pip3 install cryptography`。运行方式：

```bash
cd labs/24_encryption_pipeline
./encryption_pipeline.sh            # CMK+桶 → SSE-KMS/Grant/信封加密/对比 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] SSE-KMS 上传：对象用指定 CMK 加密落桶，读回校验元数据
  ✅ 对象以 SSE-KMS 落桶且使用指定 CMK
  ✅ 授权读取：密文透明解密，内容一致
=====> [observe] 信封加密大文件（5MB）：generate-data-key + 本地 AES 分块
  加密耗时 0.004s（纯本地 AES，0 次 KMS 调用加密数据）
  ✅ 5MB 信封加密往返字节级一致
=====> [observe] 性能对比：KMS 直加的 4KB 上限 vs 信封加密
  4KB 加密平均耗时 —— KMS 直加: 0.0045s | 信封(本地AES): 0.0000s
  ⚠️  关键实测：KMS Encrypt 对 >4KB 的明文直接拒绝——这正是信封加密存在的理由
```

信封加密的核心三步（脚本节选，cryptography 库做本地 AES）：

```bash
# 1) 向 KMS 要数据密钥：明文自用 + 包裹密文随文件存
awslocal kms generate-data-key --key-id "$ALIAS" --number-of-bytes 32
# 2) 本地 AES 加密 2MB/5MB 文件（数据不出机器）
openssl enc -aes-256-cbc -K "$KEY_HEX" -iv "$IV_HEX" -in big.bin -out big.enc
# 3) 解密时先解开被包裹的数据密钥，再解文件
awslocal kms decrypt --ciphertext-blob fileb:///tmp/dk_cipher.bin
```

新手第一个失败点：对 1MB 文件直接调 `kms encrypt` 得到 `ValidationException`
（明文上限 4KB）——这个报错本身就是"必须信封加密"的实证。

## How It Works

![端到端加密管道](images/encryption_pipeline.svg)

> 怎么看：小数据走 KMS 直加（受 4KB 上限约束）；大数据走信封加密——数据密钥
> 加密数据（本地 AES，快），CMK 只包裹数据密钥（一次 API，安全）；Grant 是
> KMS 上的临时最小授权。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/24_encryption_pipeline/images/encryption_pipeline.html)
> （或本地打开 [`images/encryption_pipeline.html`](images/encryption_pipeline.html)）。

**SSE-KMS 如何验证**：`put-object --server-side-encryption aws:kms
--ssekms-key-id "$KID"` 后，`head-object` 返回的元数据里可见
`ServerSideEncryption=aws:kms` 与指定 CMK（实测断言）。

授权方 `get-object` 透明解密，内容与原文逐字节一致。

**Grant 如何最小授权**：`create-grant --operations Decrypt
--grantee-principal <role>` 只授予解密这一种操作，可即时收回。

Grant 比 IAM 粒度更贴近密钥操作本身，且 `revoke-grant` 可即时收回。

本实验做配置验证；执行鉴权边界同 lab 08。

**性能对比如何解读**：4KB 数据 KMS 直加平均 0.0045s/次（网络往返），本地 AES
接近 0——数据量越大差距越大。

加上 4KB 明文上限的硬约束（本机实测拒绝超过 4KB 的明文），"大文件必走信封
加密"就不是风格偏好而是必然选择。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **put-object 报 Unknown options --s3-kms-key-id**：参数名是
  `--ssekms-key-id`。
- **KMS Encrypt 拒绝大明文**：明文上限 4KB。解法：走信封加密（本实验应用层）。
- **重复实验残留旧 CMK**：LocalStack 删密钥是计划删除。解法：按 Description
  找旧键 `schedule-key-deletion` 清理（脚本 apply 已处理）。
- **Grant 不生效即认定失败**：本构建不执行 KMS 鉴权。解法：Grant 配置验证 +
  效果验证去真实 AWS。

深入问答：

- **Q: SSE-S3 与 SSE-KMS 的区别？** A: SSE-S3 用 AWS 托管钥匙，无审计与控制
  力；SSE-KMS 用你的 CMK——每次解密可审计、可授权、可轮换。
- **Q: Grant 与 Key Policy/IAM 的关系？** A: Grant 是 KMS 内部的轻量授权
  （编程创建/撤销），与 Key Policy、IAM 任一允许即可通过。
- **Q: 信封加密为什么快？** A: 数据加密走本地 AES-NI（GB/s 级），KMS 只处理
  32B 密钥；调用次数与数据量解耦。
- **Q: 数据密钥要不要缓存？** A: 可进程内缓存（降 KMS 调用），但要设时间与
  字节数上限——缓存窗口即泄漏影响面。

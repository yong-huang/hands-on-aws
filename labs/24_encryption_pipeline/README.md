# 24 · 端到端加密管道：SSE-KMS、Grant 与信封加密

> 数据落桶要加密（SSE-KMS）、加密能力要最小授权（Grant）、大文件要高性能
> （信封加密）——本实验把三条加密管道一次做实，并实测出"为什么必须信封加密"
> 的硬约束：**KMS Encrypt 对超过 4KB 的明文直接拒绝**。

## 1. 为什么需要它

- 静态加密是合规底线：对象用指定 CMK 加密落桶，元数据可查（实测
  `ServerSideEncryption: aws:kms` + KeyId）。
- Grant 是比 IAM 更细的授权：只给"解密"不给"加密/管理"，且可随时撤销。
- 信封加密解决"大文件 + KMS 吞吐"的矛盾：KMS 只碰 32 字节数据密钥。

## 2. 总览：核心机制一图看懂

![端到端加密管道](images/encryption_pipeline.svg)

> 怎么看：小数据走 KMS 直加（受 4KB 上限约束）；大数据走信封加密——数据密钥
> 加密数据（本地 AES，快），CMK 只包裹数据密钥（一次 API，安全）；Grant 是
> KMS 上的临时最小授权。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/24_encryption_pipeline/images/encryption_pipeline.html)
> （或本地打开 [`images/encryption_pipeline.html`](images/encryption_pipeline.html)）。

心智模型一句话：**KMS 加密"钥匙"，本地加密"数据"；Grant 给的是单把钥匙的一次资格。**

## 3. 快速开始

```bash
cd labs/24_encryption_pipeline
./encryption_pipeline.sh            # CMK+桶 → SSE-KMS/Grant/信封加密/对比 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] SSE-KMS 上传：对象用指定 CMK 加密落桶
  ✅ 对象以 SSE-KMS 落桶且使用指定 CMK
  ✅ 授权读取：密文透明解密，内容一致
=====> [observe] 信封加密大文件（5MB）
  加密耗时 0.004s（纯本地 AES，0 次 KMS 调用加密数据）
  ✅ 5MB 信封加密往返字节级一致
=====> [observe] 性能对比
  4KB 加密平均耗时 —— KMS 直加: 0.0045s | 信封(本地AES): 0.0000s
  ⚠️  关键实测：KMS Encrypt 对 >4KB 的明文直接拒绝——这正是信封加密存在的理由
```

## 4. 核心概念

### 4.1 SSE-KMS：服务端加密用我的钥匙

`put-object --server-side-encryption aws:kms --ssekms-key-id <kid>`：对象加密落
桶，`head-object` 可验证加密算法与 KeyId（实测）。读取时授权用户透明解密。

### 4.2 Grant：KMS 的"单次能力授予"

`create-grant --operations Decrypt` 给被授权者仅解密能力——比 IAM 策略更贴近
密钥操作本身，且可 `revoke-grant` 即时收回（本实验做配置验证；执行层鉴权边界
同 lab 08）。

### 4.3 信封加密三步回环

`generate-data-key`（得明文密钥+包裹密钥）→ 本地 AES 加密任意大小数据 → 解密
时先 `decrypt` 包裹再解数据。实测 5MB 往返字节级一致，加解密都在本地毫秒级。

### 4.4 4KB 上限：信封加密的存在理由（本机实测）

对 >4KB 明文调用 KMS Encrypt 直接 `ValidationException`——大文件"不可能"走
KMS 直加。同时 KMS 吞吐有限（约 5500-10000 次/秒共享配额），信封加密把 API
调用量与数据量解耦。

## 5. 命令关键字段

```bash
awslocal s3api put-object --bucket vault --key doc --body doc.txt \
  --server-side-encryption aws:kms --ssekms-key-id "$KID"    # 注意是 ssekms-key-id

awslocal kms create-grant --key-id "$KID" \
  --grantee-principal arn:aws:iam::...:role/decryptor \
  --operations Decrypt                    # 只授解密；Retire/Revoke 可撤销
```

坑清单：

- CLI 参数是 `--ssekms-key-id`（不是 s3-kms-key-id）；
- KMS Encrypt 明文上限 4KB（实测 ValidationException）；
- Grant 的 grantee-principal 是角色 ARN，配合 IAM 才能真正生效；
- 计划删除的 CMK 最短 7 天窗口，重复实验按 Description 找旧键清理。

## 6. 文件结构

```text
labs/24_encryption_pipeline/
├── README.md                  # 本文件
└── encryption_pipeline.sh     # 主脚本：CMK/桶 → SSE-KMS/Grant/信封加密/对比 → 清理
```

> 注：图片三件套见 `images/`；依赖 `pip3 install cryptography`。

## 7. 深入要点

- **Q: SSE-S3 与 SSE-KMS 的区别？** A: SSE-S3 用 AWS 托管钥匙，审计与控制力弱；
  SSE-KMS 用你的 CMK——可审计每一次解密（CloudTrail）、可撤权、可设定轮换。
- **Q: Grant 与 Key Policy/IAM 的关系？** A: Grant 是 KMS 内部的轻量授权（可
  编程创建/撤销，不占 IAM 配额），三者任一允许即可用（KMS 策略评估模型）。
- **Q: 信封加密为什么快？** A: 数据加密走本地 AES-NI（GB/s 级），KMS 只处理
  32B 密钥（一次网络调用），把"安全调用次数"与"数据量"解耦。
- **Q: 数据密钥要不要缓存？** A: 可以进程内缓存（降低 KMS 调用），但要设上限
  时间/字节数；泄露影响面与缓存窗口成正比。
- **Q: 4KB 上限怎么记住？** A: KMS 是密钥服务不是数据服务——Encrypt/Decrypt
  都限 4KB，GenerateDataKey 最大 32B（本机实测超限即 ValidationException）。

## 8. 总结

SSE-KMS 落桶、Grant 最小授权、5MB 信封加密往返一致、4KB 上限实测——数据加密
管道的三层（存储层、授权层、应用层）全部贯通。下一篇做审计：CloudTrail 让
"谁在什么时候对什么做了什么"可查询。

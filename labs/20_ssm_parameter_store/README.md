# 20 · SSM Parameter Store：分层配置中心

> AWS SSM Parameter Store 是一种托管配置存储：参数按路径分层组织，敏感项以
> SecureString 类型加密存储，每个参数自带版本与标签。本实验建一套
> `/ho20/{env}/key` 分层参数，跑通按路径拉取、加解密、版本 Label 流转与
> Lambda 动态读取，共 10 项真实断言。

## Background

在托管配置中心普及之前，应用配置散落在三类地方：环境变量（部署时固化）、
配置文件（打进镜像）和代码常量（改一次发一版）。

散落配置撞上三堵墙。第一，改配置必须重新部署——换个数据库地址也要走一遍
发布流程。第二，多环境易错：dev 的密码写进 prod 的配置，全靠人眼核对。第三，
敏感项与普通项同权展示——谁读过密码没有记录。

SSM Parameter Store（AWS
Systems Manager 的组件）把配置集中托管：路径即命名空间，SecureString 走 KMS
加密，每次读写可审计，版本可回滚。

## What

一句话定义：SSM Parameter Store 是一种分层的键值配置存储——参数名是路径
（如 `/ho20/prod/db-password`），值支持纯文本与 SecureString（KMS 加密），
自带版本与标签。

心智模型：可以把参数层级想象成一本按目录组织的活页配置手册——`/ho20/dev/`
一章是开发环境、`/ho20/prod/` 一章是生产环境，应用"翻开自己那一章"即可
（GetParametersByPath 一次拉全）。

但和真实手册不同的是：每一页都有版本历史
（可回滚），敏感页是加密的（需要 WithDecryption 这把钥匙才能读），还能给某
一页贴 `beta` 便签实现灰度（新值先放给部分环境验证）。

三种核心操作：

- **按路径拉取**：`GetParametersByPath` 一次返回一个前缀下全部参数。
- **SecureString 读取**：加 `--with-decryption` 才返回明文。
- **Label 流转**：`label-parameter-version` 给某版本贴标签（如 beta），用
  `参数名:标签` 读取。

## When to Use

典型场景：

- 多环境配置隔离：`/app/{env}/{service}/{key}` 的路径规范让 dev/prod 天然
  分离，IAM 还能按路径限制谁能读哪一章。
- 应用动态配置：改参数即生效（应用轮询（定时反复拉取）或订阅变更事件），不用重新部署。
- 敏感项托管：数据库地址、第三方 API Key 以 SecureString 存储，读写可审计。

何时不用：高敏感凭据需要自动轮换时选 Secrets Manager（lab 23，SSM 的轮换要
自建）；超大配置体（MB 级文档）超参数大小上限（4KB/8KB）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| SSM Parameter Store | 免费、分层、版本 | 一般配置、成本敏感 |
| Secrets Manager | 计费、内置自动轮换 | 高敏感凭据（lab 23） |
| 环境变量 | 随部署固化，无版本 | 极少变化的基础配置 |
| AppConfig | 特性开关、部署策略 | 需要灰度发布配置的应用 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/20_ssm_parameter_store
./ssm_parameter_store.sh            # 建分层参数 → 四段演示 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] SecureString：密文存储、WithDecryption 解密
  ⚠️  如实记录：此构建对 SecureString 未做 KMS 加密（不 WithDecryption 也返回明文）
  ✅ WithDecryption 解出明文
=====> [observe] 版本与 Label：put-parameter 追加版本，Label 流转实现'发布'
  ✅ 覆盖后版本号 +1
  ✅ :beta 标签读到 2.0.0
  ✅ 参数历史含 2 个版本（可回滚）
=====> [observe] Lambda 运行时拉配置（GetParametersByPath + WithDecryption）
  ✅ 函数按 env 拉到正确配置（含解密的密码占位）
```

分层参数的创建与按路径拉取（脚本 apply/observe 核心命令）：

```bash
awslocal ssm put-parameter --name /ho20/prod/db-password \
  --type SecureString --value "prod-secret-456"      # 敏感项

awslocal ssm get-parameters-by-path --path /ho20/dev \
  --with-decryption --recursive                       # 一次拉全 + 解密
```

新手第一个失败点：`GetParametersByPath` 不加 `--recursive` 只返回直接子节点，
取不到嵌套路径的参数（脚本的预清理就曾因此漏删）。

## How It Works

![SSM 配置中心](images/ssm_parameter_store.svg)

> 怎么看：参数按 `/ho20/{env}/{key}` 分层；应用按环境路径一次拉全（实线）；
> SecureString 参数读取时可要求解密；写侧用 Label（beta/AWSCURRENT）流转
> 版本。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/20_ssm_parameter_store/images/ssm_parameter_store.html)
> （或本地打开 [`images/ssm_parameter_store.html`](images/ssm_parameter_store.html)）。

**版本与 Label 如何实现"发布"**：`put-parameter --overwrite` 覆盖写入时版本
号自动 +1（实测 v1→v2）。

`label-parameter-version` 给 v2 贴 `beta` 标签，`get-parameter --name
/app/version:beta` 即读到灰度值；`get-parameter-history` 返回完整版本链
（实测 2 个版本）——回滚就是把 AWSCURRENT 指回旧版本。

**Lambda 如何动态拉配置**：函数启动时按 `event.env` 拼
`GetParametersByPath(Path="/ho20/{env}", WithDecryption=True)` 一次拉全。
实测返回 prod 的 db-url 与解密后的密码占位。配置与
代码解耦后，换环境只是换一个入参。

**SecureString 的本机边界**：实测此构建未做 KMS 加密（不加 WithDecryption 也
返回明文，已如实记录）；API 契约不变——代码始终带 WithDecryption，迁移真实
AWS 即获得加密语义。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **按路径清理/拉取漏参数**：`GetParametersByPath` 不加 `--recursive` 只返回
  直接子节点。解法：嵌套路径一律加 `--recursive`。
- **覆盖写入报 `ParameterAlreadyExists`**：put 默认只新建。解法：加
  `--overwrite`（版本号自动 +1）。
- **SecureString 读到明文**：本构建未加密（实测）。解法：API 保持
  WithDecryption 不变，加密语义迁移真实 AWS 获得。
- **Label 挂错版本**：标签跟随版本而非参数名，重挂前先确认目标版本号。

深入问答：

- **Q: SSM 与环境变量的取舍？** A: 环境变量随部署固化、改动要重新发布；SSM
  运行时可读、集中审计、跨服务共享——非敏感且极少变的仍可留环境变量。
- **Q: SecureString 的加密粒度？** A: 值级 KMS 加解密；可用自定义 CMK（客户主密钥，可控制谁能解密） 通过
  IAM 条件（kms:Decrypt）控制"谁能解密"。
- **Q: 配置热更新怎么做？** A: 应用轮询（秒级间隔）或订阅 SSM 参数变更事件
  触发刷新；进程内缓存 + TTL 平衡延迟与调用量。
- **Q: SSM 与 Secrets Manager 怎么分工？** A: 一般配置 SSM（免费）；高敏感
  凭据 Secrets Manager（自动轮换）；两者底层都用 KMS 加密。

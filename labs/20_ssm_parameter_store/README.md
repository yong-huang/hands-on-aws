# 20 · SSM Parameter Store：分层配置中心

> 配置散落在环境变量、代码常量、配置文件里的日子该结束了。SSM Parameter Store
> 用**路径分层**组织配置、用 SecureString 存敏感项、用版本 + Label 实现"发布与
> 回滚"——应用启动时按路径一次拉全。本实验把配置中心的标准玩法全部跑通。

## 1. 为什么需要它

- **环境隔离**：`/ho20/dev/*` 与 `/ho20/prod/*` 各自独立，同一个应用改个路径
  参数就切换环境。
- **敏感配置**：数据库密码以 SecureString 存储（底层 KMS），审计可见谁在何时
  读过。
- **发布语义**：参数也是版本化的——新值打 `beta` 标签灰度，出问题回滚到旧版本。

## 2. 总览：核心机制一图看懂

![SSM 配置中心](images/ssm_parameter_store.svg)

> 怎么看：参数按 `/ho20/{env}/{key}` 分层；应用按环境路径一次拉全（实线）；
> SecureString 参数读取时可要求解密；写侧用 Label（beta/AWSCURRENT）流转版本。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/20_ssm_parameter_store/images/ssm_parameter_store.html)
> （或本地打开 [`images/ssm_parameter_store.html`](images/ssm_parameter_store.html)）。

心智模型一句话：**路径是命名空间，Label 是发布指针，WithDecryption 是敏感项的钥匙。**

## 3. 快速开始

```bash
cd labs/20_ssm_parameter_store
./ssm_parameter_store.sh            # 建分层参数 → 四段演示 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] SecureString：密文存储、WithDecryption 解密
  ⚠️  如实记录：此构建对 SecureString 未做 KMS 加密
  ✅ WithDecryption 解出明文
=====> [observe] 版本与 Label：put-parameter 追加版本，Label 流转实现'发布'
  ✅ :beta 标签读到 2.0.0
  ✅ 参数历史含 2 个版本（可回滚）
=====> [observe] Lambda 运行时拉配置
  ✅ 函数按 env 拉到正确配置（含解密的密码占位）
```

## 4. 核心概念

### 4.1 分层路径：GetParametersByPath 一次拉全

`/ho20/dev/db-url`、`/ho20/dev/db-password`……`GetParametersByPath(Path=/ho20/dev)`
一次返回该环境全部配置——应用启动时一次网络调用完成初始化，比逐个 Get 快一个
数量级。

### 4.2 SecureString 与 WithDecryption

SecureString 用 KMS 加密存储。**本机构建实测未做加密**（不 WithDecryption 也
返回明文，如实记录）；真实 AWS 中不解密时拿到的是密文。API 契约不变——代码
写 WithDecryption 即可平滑迁移。

### 4.3 版本、Label 与回滚

覆盖写入版本号自动 +1（实测 1→2）；`label-parameter-version` 给 v2 打 `beta`，
`get-parameter --name /param:beta` 按标签读取。`get-parameter-history` 看到完整
版本链（实测 2 个版本，v1 仍是 1.0.0）——回滚就是"把 AWSCURRENT 指回 v1"。

### 4.4 SSM vs Secrets Manager 选型

| 维度 | SSM Parameter Store | Secrets Manager |
|:---|:---|:---|
| 成本 | 免费（标准参数） | 每密钥每月计费 |
| 轮换 | 手动 | 内置自动轮换（Lambda 四步） |
| 加密 | SecureString(KMS) | 默认 KMS |
| 适用 | 一般配置 | 数据库凭据等高敏感项 |

## 5. 命令关键字段

```bash
awslocal ssm put-parameter --name /ho20/prod/db-password \
  --type SecureString --value "prod-secret-456"          # 敏感项

awslocal ssm get-parameters-by-path --path /ho20/dev \
  --with-decryption --recursive                          # 一次拉全 + 解密

awslocal ssm label-parameter-version --name /app/version \
  --parameter-version 2 --labels beta                    # 灰度标签
awslocal ssm get-parameter --name /app/version:beta      # 按标签读
```

坑清单：

- `GetParametersByPath` 不加 `--recursive` 只取直接子节点（清理脚本曾因此漏删）；
- 本机构建 SecureString 未加密（实测如实记录），敏感效果验证去真实 AWS；
- 参数名大小写敏感、只能以 `/` 开头的字母数字路径组成；
- 覆盖写入必须 `--overwrite`，否则 ParameterAlreadyExists。

## 6. 文件结构

```text
labs/20_ssm_parameter_store/
├── README.md                  # 本文件
└── ssm_parameter_store.sh     # 主脚本：分层参数 → 四段演示 → 清理
                               # （全部 API 操作，无声明式配置目录）
```

> 注：图片三件套见 `images/`（图源 JSON / 交互 HTML / 内嵌 SVG）。

## 7. 深入要点

- **Q: SSM 与环境变量的取舍？** A: 环境变量随部署固化，改配置要重新部署；
  SSM 运行时可读、集中审计、跨服务共享——非敏感且极少变的仍可用环境变量。
- **Q: SecureString 的加密粒度？** A: 值级别用 KMS 加解密；可用自定义 CMK 控制
  谁能解密（IAM 条件 kms:Decrypt）。
- **Q: 如何做配置热更新？** A: 轮询（间隔秒级）或 EventBridge 收 ssm 变更事件
  触发刷新；进程内缓存 + TTL 平衡延迟与调用量。
- **Q: 大量参数怎么治理？** A: 路径规范（/app/env/service/key）+ 标签分类 +
  IAM 按路径授权；参数太多考虑 Parameter Store 的层次化与文档化。
- **Q: SSM 与 Secrets Manager 怎么分工？** A: 一般配置 SSM（免费），高敏感凭据
  Secrets Manager（自动轮换）；Secrets Manager 底层也是 KMS 加密。

## 8. 总结

分层、加密、版本、Label——配置中心的四块基石就位，第五阶段（16-20）的
"无服务器生产化"收官。下一篇进入可观测性：让 Lambda 的日志变成可查询的结构化
数据（CloudWatch Logs 全家桶）。

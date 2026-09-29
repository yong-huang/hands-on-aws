# 17 · API Gateway 深化：API Key、Authorizer 与能力边界

> 在 lab 05 的基础上给 API 加上生产级门面：API Key + Usage Plan（识别客户端并
> 限流）、Lambda Authorizer（自定义鉴权），并探活 HTTP API v2 与本构建的执行
> 边界。共 7 项真实断言与 3 处如实记录。

## Background

lab 05 的 API 建好后谁都能调——真实对外开放时立刻出现三个问题。

第一，不认识调用者：无法区分免费用户与付费用户，也没有计量依据。第二，不限
流：一个失控的客户端能打垮后端。第三，鉴权逻辑散落在每个 Lambda 里，改一次
规则要动所有函数。

API Gateway 的门面机制分别作答：API Key 识别客户端、Usage
Plan 挂限流配额、Lambda Authorizer 把"是否放行"做成独立函数。

## What

一句话定义：API Key 是客户端标识（不是安全机制）；Usage Plan 是把限流配额
（rate/burst）绑定到一组 Key 的计量单元；Lambda Authorizer 是网关在转发前
调用的鉴权函数，返回"允许/拒绝"的策略文档。

心智模型：可以把这套机制想象成演唱会票务——API Key 是门票条码（识别你是
谁），Usage Plan 是票种规则（内场每分钟限入 1 次），Authorizer 是安检员。

但和真实演唱会的区别在于：安检员的决定是一份机器可执行的策略文档，可以被
网关缓存（TTL：缓存保留秒数，可配）。

两种 API 形态：

- **REST API**：功能全——Key/Plan、请求校验、WAF、私有化（本实验主体）。
- **HTTP API**：便宜约 70%、延迟低、内置 JWT（JSON Web Token，自带签名的令牌格式）授权，但不支持 API Key
  （本构建 create-api 不支持，探活如实记录）。

## When to Use

典型场景：

- 对外开放计费 API：Key 分发给合作方，Usage Plan 按套餐限流（免费 1 rps /
  付费 100 rps）。
- 自定义鉴权：调用方身份在自家用户体系里，用一个 Lambda 统一验签并注入身份
  上下文给后端。
- 轻量内部代理：HTTP API 挂 Lambda 直通，省成本。

何时不用：纯内部服务间调用（IAM/直接函数调用更简单）；强安全诉求把 Key 当
认证手段（Key 只是识别，安全靠 TLS + 真实鉴权）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| API Key + Usage Plan | 识别 + 限流，最轻量 | 开放平台的计量与配额 |
| Lambda Authorizer | 任意自定义鉴权逻辑 | 自有用户体系、复杂鉴权 |
| Cognito/JWT Authorizer | 标准 IdP 集成 | 用户登录体系已上 Cognito/OAuth |
| IAM 授权 | AWS 主体签名调用 | 服务间 AWS 内部调用 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/17_apigw_http_api_auth
./apigw_http_api_auth.sh            # 建 API + 双层防护 → 对照实验 → 清理
```

脚本的真实输出（节选）：

```text
=====> [observe] API Key：无 key 访问 /secure → 403；带 key → 200
  ✅ 无 API Key 被拒（403 Forbidden）
  ✅ 带 API Key 放行
=====> [observe] Usage Plan 限流：1 rps/burst1 连打 5 发
  状态码序列: 200200200200200
  ⚠️  此构建未触发 429（Usage Plan 限流未强制执行，真实 AWS 会限流）
=====> [observe] Lambda Authorizer：无/错 token → 401；allow-me → 200
  ⚠️  Authorizer 探活：错误 token 也返回 200——此构建不执行 Lambda Authorizer（如实记录）
=====> [observe] HTTP API v2 探活
  ⚠️  此构建不支持 apigatewayv2 create-api
```

Authorizer 的核心返回（`token_authorizer.py`）——策略文档即放行凭证：

```python
def handler(event, context):
    token = event.get("authorizationToken", "")
    if token == "allow-me":
        return {
            "principalId": "user-bob",
            "policyDocument": {                      # 这份文档就是"放行凭证"
                "Version": "2012-10-17",
                "Statement": [{"Action": "execute-api:Invoke",
                               "Effect": "Allow",
                               "Resource": event.get("methodArn", "*")}]},
            "context": {"team": "platform"}}         # 注入给后端的身份上下文
    raise Exception("Unauthorized")                  # 网关约定：抛它 => 401
```

新手第一个失败点：Key 创建后必须**同时**绑到 Usage Plan 并关联 stage，缺一
步则 apiKeyRequired 的方法全部 403。

## How It Works

![API Gateway 深化](images/apigw_http_api_auth.svg)

> 怎么看：/secure 方法要求 API Key（无 key 直接 403，实线主路径），Key 又绑定
> 在 Usage Plan 上（限流参数挂在计划而非单个 Key）；/admin 挂 Lambda
> Authorizer（虚线）——网关先调它拿"允许/拒绝"策略文档再决定转发；HTTP API
> v2 是旁路探活（此构建不可用，如实标注）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/17_apigw_http_api_auth/images/apigw_http_api_auth.html)
> （或本地打开 [`images/apigw_http_api_auth.html`](images/apigw_http_api_auth.html)）。

**Key → Plan → Stage 的绑定链**：create-api-key 生成 Key，create-usage-plan
把 `{burstLimit:1, rateLimit:1}` 绑到 `{apiId, stage}`，最后
create-usage-plan-key 关联两者。

实测：无 Key 403、有 Key 200——识别与放行
闭环成立。

**Authorizer 的执行边界**：Authorizer 创建成功并挂到 /admin（CUSTOM 鉴权类型
生效），但本构建网关**不调用**它——错误 token 也返回 200（实测如实记录）。
配置结构与真实 AWS 完全一致，迁移后即自动生效。

**HTTP API v2 的本机边界**：`apigatewayv2 create-api` 不被此构建支持（探活
如实记录）。真实 AWS 中一条命令即可建好"路由 + Lambda 集成 + 默认阶段"。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **Key 建了但方法仍 403 放不过去**：Key 没绑 Usage Plan 或 Plan 没关联
  stage。解法：三步链路逐一核对。
- **Authorizer 调试结果"不变化"**：网关缓存了策略文档。解法：调试期把
  `--authorizer-result-ttl-in-seconds` 设为 0。
- **改方法配置报错**：`update-method` 用 JSON Patch 语法（patch-operations），
  不是直接赋值。
- **本构建 429/Authorizer 执行不可用**：如实记录（本实验已标注），效果验证
  迁移真实 AWS。

深入问答：

- **Q: API Key 是安全机制吗？** A: 不是——它只是识别与计量手段，Key 会泄漏
  也会被转发；真正的访问控制是 Authorizer/IAM + TLS。
- **Q: 429 什么时候触发？** A: 超过 Usage Plan 的 rateLimit（持续速率）或
  burstLimit（瞬时并发）；客户端应指数退避重试。
- **Q: Lambda Authorizer 的缓存如何工作？** A: 按 identity source（token 值）
  缓存策略文档 TTL 秒；token 自带过期语义时把 TTL 设小或 0。
- **Q: REST API 与 HTTP API 的鉴权差异？** A: HTTP API 内置 JWT Authorizer
  （任意 IdP（身份提供商）的 JWKS（公钥集合））并支持 Lambda Authorizer；不支持 API Key。

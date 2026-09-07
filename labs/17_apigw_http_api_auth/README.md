# 17 · API Gateway 深化：API Key、Authorizer 与能力边界

> lab 05 的 API 谁都能调。生产 API 要回答三个问题：**怎么计费限流**（API Key +
> Usage Plan）、**怎么鉴权**（Lambda Authorizer / IAM / Cognito）、**轻量场景
> 用什么**（HTTP API v2）。本实验把三件都配上，并如实记录本构建的执行边界。

## 1. 为什么需要它

- 开放 API 没有配额 = 被刷爆；API Key + Usage Plan 是最轻量的"识别 + 限流"。
- Authorizer 把鉴权逻辑从业务代码剥离：一个函数发放"是否放行"的策略文档。
- HTTP API v2 是 REST API 的轻量替代：便宜、延迟低、路由语法简单。

## 2. 总览：核心机制一图看懂

![API Gateway 深化](images/apigw_http_api_auth.svg)

> 怎么看：/secure 方法要求 API Key（无 key 直接 403，实线主路径），Key 又绑定在
> Usage Plan 上（限流参数挂在计划而非单个 Key）；/admin 挂 Lambda Authorizer
> （虚线）——网关先调它拿"允许/拒绝"策略文档再决定转发；HTTP API v2 是旁路
> 探活（此构建不可用，如实标注）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/17_apigw_http_api_auth/images/apigw_http_api_auth.html)
> （或本地打开 [`images/apigw_http_api_auth.html`](images/apigw_http_api_auth.html)）。

心智模型一句话：**Key 识别"你是谁"，Plan 限制"你能多快"，Authorizer 决定"你能不能"。**

## 3. 快速开始

```bash
cd labs/17_apigw_http_api_auth
./apigw_http_api_auth.sh            # 建 API + 双层防护 → 对照实验 → 清理
```

真实运行输出（节选）：

```text
=====> [observe] API Key：无 key 访问 /secure → 403；带 key → 200
  ✅ 无 API Key 被拒（403 Forbidden）
  ✅ 带 API Key 放行
=====> [observe] Usage Plan 限流：1 rps/burst1 连打 5 发
  状态码序列: 200200200200200
  ⚠️  此构建未触发 429（Usage Plan 限流未强制执行，真实 AWS 会限流）
=====> [observe] Lambda Authorizer
  ⚠️  错误 token 也返回 200——此构建不执行 Lambda Authorizer（如实记录）
=====> [observe] HTTP API v2 探活
  ⚠️  此构建不支持 apigatewayv2 create-api
```

## 4. 核心概念

### 4.1 API Key + Usage Plan：识别与限流分离

Key 只是"身份证"；配额/限流挂在 **Usage Plan** 上，一个计划绑定多个 Key——
"免费版/付费版"就是两个计划。本实验实测：无 Key 访问 /secure 得 403，带 Key
200（机制完整）；连续 5 发未触发 429（此构建不强制限流，如实记录，真实 AWS
按 throttle rate/burst 返回 429）。

### 4.2 Lambda Authorizer：策略即返回值

TOKEN 型 Authorizer 从 `Authorization` 头取 token，Lambda 返回**策略文档**
（Allow/Invoke + Resource + principalId + context）。网关缓存策略（TTL 可配）。
本机实测：authorizer 创建并挂载成功（CUSTOM 鉴权类型生效），但网关**不执行**
它——配置验证 ✅、效果验证留给真实 AWS。

### 4.3 HTTP API v2：轻量一代

`create-api --target <lambda>` 一条命令建好路由+集成+默认 stage。本构建实测
不支持（如实记录）；概念上记住三点：比 REST API 便宜约 70%、延迟更低、JWT
授权器内置（不需要自己写 Lambda）。

## 5. 命令关键字段

```bash
awslocal apigateway update-method --patch-operations \
  '[{"op":"replace","path":"/apiKeyRequired","value":"true"}]'     # 方法级 API Key

awslocal apigateway create-usage-plan --name plan \
  --throttle '{"burstLimit":1,"rateLimit":1}' \
  --api-stages '[{"apiId":"...","stage":"v1"}]'                    # 限流绑 stage

awslocal apigateway create-authorizer --type TOKEN \
  --authorizer-uri "arn:aws:apigateway:...:functions/.../invocations" \
  --identity-source 'method.request.header.Authorization' \
  --authorizer-result-ttl-in-seconds 0                             # 调试用 0 缓存
```

坑清单：

- API Key 必须绑到 Usage Plan 并关联 stage 才会生效；
- Authorizer 抛 `Unauthorized` 异常 = 401；返回空/错 policy = 403/500；
- 调试 Authorizer 时把 result TTL 设 0，否则旧策略缓存会骗你；
- update-method 用 patch-operations（JSON Patch 语法），不是直接赋值。

## 6. 文件结构

```text
labs/17_apigw_http_api_auth/
├── README.md                    # 本文件
├── apigw_http_api_auth.sh       # 主脚本：双防护 API + 三段探活 + 清理
├── echo_backend.py              # 回显后端（authorizer 上下文可见）
├── token_authorizer.py          # TOKEN 型 Lambda Authorizer（allow-me 放行）
└── images/
    ├── apigw_http_api_auth.architecture.json  # 图源（Typed JSON IR）
    ├── apigw_http_api_auth.html               # 交互版
    └── apigw_http_api_auth.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: API Key 是安全机制吗？** A: 不是，只是客户端识别与配额计量；真正的
  访问控制用 IAM/Cognito/Lambda Authorizer + HTTPS。
- **Q: 429 何时触发？** A: 超过 Usage Plan 的 rateLimit（持续速率）或
  burstLimit（瞬时并发）；客户端应指数退避重试。
- **Q: Lambda Authorizer 的缓存如何工作？** A: 按 identity source（token 值）
  缓存策略文档 TTL 秒；token 包含过期语义时把 TTL 设小或 0。
- **Q: REST API 与 HTTP API 的鉴权差异？** A: HTTP API 内置 JWT Authorizer
  （Cognito/任何 IdP 的 JWKS）且支持 Lambda Authorizer；不支持 API Key。
- **Q: usage plan 生效但没限住流量的排查顺序？** A: stage 是否关联计划 → key
  是否绑计划 → 方法是否 apiKeyRequired → 计数器是否被缓存（本构建即此情况）。

## 8. 总结

Key/Plan/Authorizer 的配置链路全部打通，本构建的三个执行边界（429、Authorizer
执行、HTTP API v2）如实入档——这正是"本地模拟 → 真实 AWS"迁移清单的素材。
下一篇回到 Step Functions 深水区：Map 动态并行与 Saga 补偿。

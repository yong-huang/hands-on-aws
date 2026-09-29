# 05 · API Gateway + Lambda REST API：无服务器后端的第一扇门

> Amazon API Gateway 是 AWS 的托管 API 网关：把 HTTP 请求路由到后端（本实验是
> Lambda），并替你处理鉴权、限流、部署版本等"API 门面"事务。本实验从零搭建一个
> REST API（items 资源的增删查），用 curl 完成 7 项全链路断言。

## Background

在托管网关普及之前，对外提供一个 API 意味着自己维护 Web 服务器（Nginx/应用
框架）：配置路由、TLS 证书、限流、部署版本、监控——每一项都是运维工作，而它们
与业务逻辑毫无关系。

自建方案的痛点集中在发布与运维：改一条路由要动服务器配置；要加限流得引入
网关插件；API 版本并存（v1/v2）需要自己设计灰度方案。API Gateway 把这些"API
门面事务"产品化：声明资源树与后端集成，平台接管路由、部署快照、鉴权与限流
（本实验覆盖前两项，鉴权限流在 lab 17 深化）。

## What

一句话定义：API Gateway 是一种托管 API 网关，把 HTTP 请求按资源树路由到后端
（本实验用 Lambda），并以"代理集成"方式在请求与函数之间做双向翻译。

心智模型：可以把网关想象成公司前台——访客（HTTP 请求）报上门牌（URL 路径），
前台按门牌转接对应部门（Lambda），再把部门的答复原样转述出去。但和真实前台
不同的是：它会强制检查答复的"格式规范"（必须含 statusCode/headers/body 三
要素），格式不对一律回 502，部门说了什么它不关心。

三个构成要素：

- **资源树**：`/items`、`/items/{id}` 这样的路径结构，`{id}` 是路径参数模板。
- **AWS_PROXY 代理集成**：把整个 HTTP 请求（方法/路径/头/体）打包成一个 event
  传给 Lambda，函数的返回值原样成为 HTTP 响应。
- **Stage**：部署快照的名字，URL 里的 `v1` 就是它——改动资源树必须重新部署才
  生效。

## When to Use

典型场景：

- 无服务器 REST API：网关 + Lambda + DynamoDB 三件套，按请求计费、无服务器
  可维护，是中小型后端的标准形态。
- 需要门面能力的系统：统一入口上挂鉴权（lab 17）、限流、CORS（跨域请求的
  放行机制）、请求校验，业务代码保持干净。
- API 版本管理：靠 stage 与部署快照实现"v1 不动、v2 试新"（灰度——新版本
  先放给一小部分流量的发布方式——的基础）。

何时不用：内部服务间点对点调用（直接函数调用更简单）；超高每秒请求数且延迟
敏感的内部接口（网关按请求计费且增加一跳延迟）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| API Gateway REST API | 功能全：API Key/Usage Plan、请求校验、WAF | 对外 API、需要门面能力 |
| API Gateway HTTP API | 便宜约 70%、延迟低、路由简单 | 内部或轻量代理场景（lab 17 探活） |
| ALB | 七层负载均衡，按使用量（LCU，负载均衡容量单位）计费 | 已有 ECS/EC2 服务群、规则简单 |
| 自建 Nginx | 完全控制，运维自负 | 已有运维体系、特殊协议需求 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/05_apigw_lambda_rest
./apigw_lambda_rest.sh            # apply → observe → clean（约 60 秒）
./apigw_lambda_rest.sh observe    # 只跑 7 个 HTTP 断言
# 手动测试：
# curl http://<api-id>.execute-api.localhost.localstack.cloud:4566/v1/items
```

脚本的真实输出（节选）：

```text
=====> [apply] 部署到 Stage v1（得到可调用的 execute-api URL）
  Invoke URL: http://1lenysrwgc.execute-api.localhost.localstack.cloud:4566/v1
=====> [observe] GET /items/{id}：路径参数正确传入 pathParameters
  ✅ i1 名字正确
=====> [observe] GET /items/nope：未找到 → 业务 404
  ✅ 不存在的 id 返回 404
=====> [observe] DELETE /items/i1：删除后再 GET → 404 闭环
  ✅ 删除后 GET 404
```

代理集成后端的核心代码（`lambda_function.py`）——入口解析 event，出口统一
构造响应（处理函数按 event 的 method 与路径分派到 items 的增删查）：

```python
def handler(event, context):
    method = event["httpMethod"]            # GET/POST/...
    path  = event["path"]                   # /items/i1
    item_id = (event.get("pathParameters") or {}).get("id")   # {id} 模板参数
    body = json.loads(event.get("body") or "{}")              # POST 请求体

def resp(code, payload):
    return {"statusCode": code,
            "headers": {"Access-Control-Allow-Origin": "*", ...},  # CORS 必须由响应带头
            "body": json.dumps(payload)}
```

新手第一个失败点：手动测试时走 `/restapis/...` 路径会撞上 S3 路由。解法：始终
用 `<api-id>.execute-api.localhost.localstack.cloud` 子域名——该保留域名解析到
127.0.0.1。

## How It Works

![API Gateway + Lambda REST API](images/apigw_lambda_rest.svg)

> 怎么看：客户端只认 `execute-api` 域名下的 URL；网关按资源树路由请求，以
> AWS_PROXY 模式把整个 HTTP 请求打包成 event 丢给 Lambda。
> 函数返回的 `{statusCode, headers, body}` 被网关翻译回 HTTP 响应（含 CORS
> 头）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/05_apigw_lambda_rest/images/apigw_lambda_rest.html)
> （或本地打开 [`images/apigw_lambda_rest.html`](images/apigw_lambda_rest.html)）。

**一次请求的完整旅程**：`POST /v1/items` 到达网关 → 按资源树匹配 `/items` 的
POST 方法 → 代理集成把请求打包成 event 调用 Lambda → 函数解析 body、写
DynamoDB、返回 `{statusCode: 201}` → 网关翻译回 HTTP 201。

Quick Start 里看到的每个状态码，都对应链路中某一步的业务结果：404 是函数返回
的业务码，502 是集成格式错误的网关码。

**Stage 为什么必须 redeploy**：`create-deployment` 把当前资源树做成一份不可变
快照，stage 指向快照。改资源树后不重新部署，URL 行为不变——这是"改了没生效"
这类新手问题的根源，也是灰度发布的基础（lab 17 深化）。

**CORS 的位置**：跨域请求的放行凭据是响应头 `Access-Control-Allow-Origin`，
由函数统一注入（实测断言）。完整的 CORS 还需处理浏览器的 OPTIONS 预检请求
（在网关加 MOCK 集成），GET/POST 简单请求场景本实验的做法已够用。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **客户端收到 502，Lambda 日志却是 200**：代理集成要求返回
  `{statusCode, headers, body}` 三件套，缺 statusCode 或 body 不是字符串即
  502（`Malformed Lambda proxy response`）。解法：统一走 `resp()` 封装。
- **`pathParameters` 取值报错**：路径不含参数时它是 `null`。解法：取值前兜底
  `(event.get("pathParameters") or {}).get("id")`。
- **改了路由没生效**：资源树改动未重新部署到 stage。解法：改完执行
  `create-deployment`。
- **手动测试撞 404**：用了 `/restapis/...` 直连路径会撞 S3 路由。解法：始终用
  `<api-id>.execute-api.localhost.localstack.cloud` 子域名。

深入问答：

- **Q: REST API 与 HTTP API 怎么选？** A: REST API 功能全（API Key/Usage
  Plan、请求校验、WAF（Web 应用防火墙））；HTTP API 便宜约 70%、延迟更低、内置 JWT 授权。轻量
  代理场景选 HTTP API（lab 17 有本机探活）。
- **Q: 代理集成和非代理集成的取舍？** A: 代理集成零映射模板、函数全权负责；
  非代理可在网关层做请求转换与静态响应（如 MOCK 的 OPTIONS 预检）。
- **Q: stage 在部署链路里的作用？** A: 部署是资源树的不可变快照，stage 指向
  快照并挂环境变量/日志/限流配置。
- **Q: API Gateway 保证幂等吗？** A: 不保证——幂等（同一请求重复执行，结果
  不变）要靠业务侧实现。防重复提交靠业务侧幂等键（如
  DynamoDB 条件写，lab 14 工程化）。

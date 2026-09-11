# 05 · API Gateway + Lambda REST API：无服务器后端的第一扇门

> Lambda 已经能干活，但它是"内部员工"——只有 IAM 主体能调用。前端、移动端、
> 第三方要进门，需要一个把 HTTP 翻译成函数调用的门卫。API Gateway 干的就是这个：
> 把 URL 路径映射到 Lambda，把请求打包成 event 传入，把返回值包成 HTTP 响应。
> 本实验从零搭一个真正的 REST API 并用 curl 全链路验证。

## 1. 为什么需要它

- **HTTP 契约与业务代码解耦**：路由、参数、状态码、CORS 这些"HTTP 杂事"交给
  网关，Lambda 只写业务分支。
- **无服务器 API 的标准形态**：网关 + Lambda + DynamoDB 三件套，没有一台服务器
  要维护，按请求计费。
- 它也是后续所有"可调用系统"的骨架：lab 10 的订单入口、lab 19 的全栈留言板、
  lab 17 的鉴权限流，都长在这扇门上。

## 2. 总览：核心机制一图看懂

![API Gateway + Lambda REST API](images/apigw_lambda_rest.svg)

> 怎么看：客户端只认 `execute-api` 域名下的 URL；网关把请求按资源树
> （`/items`、`/items/{id}`）路由，以 AWS_PROXY 模式把**整个 HTTP 请求**打包成
> event 丢给 Lambda；函数查/写 DynamoDB 后返回 `{statusCode, headers, body}`，
> 网关原样翻译回 HTTP 响应（含 CORS 头）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/05_apigw_lambda_rest/images/apigw_lambda_rest.html)
> （或本地打开 [`images/apigw_lambda_rest.html`](images/apigw_lambda_rest.html)）。

心智模型一句话：**代理集成 = 网关只管翻译，业务逻辑全在函数里。**

## 3. 快速开始

```bash
cd labs/05_apigw_lambda_rest
./apigw_lambda_rest.sh            # apply → observe → clean（约 60 秒）
./apigw_lambda_rest.sh observe    # 只跑 7 个 HTTP 断言
# 手动玩：
# curl http://<api-id>.execute-api.localhost.localstack.cloud:4566/v1/items
```

真实运行输出（节选）：

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

## 4. 核心概念

### 4.1 资源树四件套

REST API 的每个叶子路径 = 资源(resource)；每个资源上声明方法(method)；方法背后
挂集成(integration)；最后 `create-deployment` 到 stage 才可调用。本实验：
`/items`(GET,POST) + `/items/{id}`(GET,DELETE)，`{id}` 是路径参数模板——Lambda
从 `event.pathParameters.id` 读到它。

### 4.2 AWS_PROXY 代理集成

`type=AWS_PROXY`（Lambda 代理）把请求头、路径、查询串、body 全部塞进一个 event，
函数返回 `{statusCode, headers, body}` 原样成为 HTTP 响应。与之相对的 AWS 非代理
集成要在网关配"请求/响应映射模板"——灵活但繁琐，代理集成是现在的默认选择。

### 4.3 Stage：可调用版本的快照

资源树改完必须**重新部署到 stage** 才生效；URL 里的 `v1` 就是 stage 名。这给了
你"v1 不动、v2 试新"的灰度能力（lab 17 深化）。

### 4.4 本机调用的域名魔法

LocalStack 的网关走 `<api-id>.execute-api.localhost.localstack.cloud:4566`——
`localhost.localstack.cloud` 是官方保留域名，解析到 127.0.0.1，用子域名区分 API。
直接访问 `/restapis/...` 路径会撞上 S3 路由（踩坑实录），必须用 execute-api 子域名。

## 5. 代码关键字段（lambda_function.py）

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

坑清单：

- 返回缺 `statusCode/body` 结构网关直接 502 `Malformed Lambda proxy response`；
- `pathParameters` 可能为 `null`，取值前要兜底；
- 正式的 CORS 还需要浏览器预检 OPTIONS + MOCK 集成，本实验只演示响应头注入
  （GET/POST 简单请求场景够用，复杂场景在网关补 OPTIONS）；
- 改了资源树忘 redeploy = "改了没生效"，这是 API Gateway 第一大新手坑。

## 6. 文件结构

```text
labs/05_apigw_lambda_rest/
├── README.md               # 本文件
├── apigw_lambda_rest.sh    # 主演示脚本：建资源树/部署/7 项 HTTP 断言/清理
├── lambda_function.py      # 代理集成后端：items CRUD，统一 CORS 与错误码
└── images/
    ├── apigw_lambda_rest.architecture.json  # 架构图源（Typed JSON IR）
    ├── apigw_lambda_rest.html               # 交互版架构图
    └── apigw_lambda_rest.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **Q: REST API 与 HTTP API 怎么选？** A: REST API 功能全（API Key/Usage Plan、
  请求校验、WAF、私有化）；HTTP API 便宜延迟低、路由简单。lab 17 有实测对比。
- **Q: 代理集成和非代理集成的取舍？** A: 代理集成零映射模板、函数全权负责响应；
  非代理可在网关层做请求转换/静态响应（如 MOCK 的 OPTIONS 预检）。
- **Q: Lambda 返回了 200 但客户端 502？** A: 典型的代理集成响应格式不对——缺
  `statusCode` 或 `body` 不是字符串。
- **Q: stage 在部署链路里的作用？** A: 部署是资源树的不可变快照，stage 指向某个
  快照并挂环境变量/日志/限流；不 redeploy 改动不生效。
- **Q: API Gateway 幂等吗？怎么防重复提交？** A: 网关不管业务幂等；用客户端请求
  去重键（如 DynamoDB 条件写）或 idempotency key（lab 14 工程化）。

## 8. 总结

资源树、代理集成、Stage 三板斧搭出了一个真前端能调的 REST API，7 项 HTTP 断言
全部真机通过。下一篇离开"单函数"视角：Step Functions 把多个 Lambda 编排成带
分支、并行、重试的状态机——工作流的骨架。

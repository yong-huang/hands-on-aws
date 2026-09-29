# 19 · S3 静态网站 + 无服务器后端联调

> 用 S3 的 website 托管能力放前端静态页，用 API Gateway + Lambda + DynamoDB 做
> 后端，组成一个真的能在浏览器打开的迷你全栈应用（留言板），并覆盖预签名直传
> 与 CORS 两个前后端联调的关键机制，共 9 项真实断言。

## Background

在"静态托管 + 托管 API"普及之前，上一个全栈网站要租一台或两台服务器：Web
服务器放前端，应用服务器跑后端，Nginx 做反代与跨域配置。

自建方案撞上两堵墙。第一，前端页面是一堆静态文件，却要为此养一台常驻 Web
服务器，流量小是浪费、流量大要自己扩。第二，前端域名与应用域名不同，浏览器
的同源策略（same-origin policy，浏览器禁止页面脚本读取不同源服务器的响应）
直接拦截调用，跨域配置成了每次联调的必踩坑。

S3 的 website 托管让静态文件
按 URL 直接分发，API Gateway 挂后端，CORS 头由后端注入——前端与后端从此
各自独立部署。

## What

一句话定义：这套架构用 S3 website 端点分发静态页（部署时注入 API 地址），
页面脚本 `fetch` 调用 API Gateway 读写 DynamoDB，文件直传则走后端签发的预
签名 URL。

心智模型：可以把 S3 想象成一个只读的公共文件柜（放页面），API Gateway 是
柜子旁的服务窗口（处理留言），CORS 头是窗口贴出的"欢迎跨楼来访"告示。

但和
真实文件柜不同的是：往柜子里放新文件可以不经窗口——后端签发的预签名 URL
（presigned URL，把"一次 PUT 操作 + 有效期"签进 URL）让浏览器直接上传。

三个联调关键机制：

- **部署期注入**：index.html 不写死 API 地址，部署脚本注入后再上传——多环境
  只换注入值。
- **CORS 响应头**：后端统一注入 `Access-Control-Allow-Origin`，浏览器据此
  放行跨域读取。
- **预签名直传**：签发与上传分离，后端只授权不搬运。

## When to Use

典型场景：

- 官网/营销页/文档站：纯静态，S3 直发，流量成本极低。
- 轻量全栈应用：留言板、问卷、内部工具——静态页 + 托管 API 足够。
- 客户端直传文件：头像、附件上传，后端签 URL 前校验业务资格。

何时不用：需要服务端渲染（SEO 强需求选 SSR 框架 + 常驻服务）；强一致事务
密集的业务；前端需要隐藏后端结构时（用反向代理同域化）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| S3 website（本实验） | 直发静态文件，HTTP | 本地开发与学习 |
| S3 + CloudFront | 加 CDN（内容分发网络，把静态文件缓存到离用户近的节点）、HTTPS、自定义域名 | 生产前端的标准形态 |
| Vercel/Netlify 类 | 构建-部署一体，功能多 | 前端框架项目的快速上线 |
| 传统双服务器 | 前后端同域，无 CORS | 团队已有该运维体系 |

## Quick Start

前置条件：LocalStack 运行中。运行方式：

```bash
cd labs/19_s3_website_fullstack
./s3_website_fullstack.sh            # 建站点+API → 闭环断言 → 清理
# 打开浏览器访问: http://ho19-site.s3.localhost.localstack.cloud:4566/index.html
```

脚本的真实输出（节选）：

```text
=====> [observe] 网站端点：curl 静态页 → 200 且含 API 地址
  ✅ S3 website 端点返回 200（/index.html）
  ✅ 页面已注入 API 地址（fetch 可用）
=====> [observe] 后端闭环：POST 留言 → GET 回显（模拟页面 fetch）
  ✅ POST 留言 201
  ✅ GET 回显留言（CORS 响应头由函数注入）
=====> [observe] 预签名直传：前端持 URL 直接 PUT 文件到桶
  ✅ 预签名 PUT 直传成功
  ✅ 直传内容落桶正确
```

后端的核心代码（`board_lambda.py`）——每个响应统一注入 CORS 头：

```python
CORS = {"Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*"}   # 生产应收敛为站点域名

def handler(event, context):
    if event.get("httpMethod") == "POST":
        ...                                    # 校验 → put_item
        return {"statusCode": 201, "headers": CORS, ...}
    rows = ddb.scan(TableName=TABLE).get("Items", [])
    ...                                        # GET 按时间排序返回
```

新手第一个失败点：浏览器访问根路径 `/` 在本构建返回桶列表而非 index——直接
访问 `/index.html` 即可（本机差异，脚本断言与提示已注明）。

## How It Works

![S3 静态网站全栈](images/s3_website_fullstack.svg)

> 怎么看：浏览器从 S3 website 端点拿到注入了 API 地址的 index.html；页面
> fetch 到 API Gateway（跨域，靠函数注入的 CORS 头放行）；POST 写入 / GET
> 回显留言全部落 DynamoDB；文件直传走预签名 URL（虚线），不经过任何后端。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/19_s3_website_fullstack/images/s3_website_fullstack.html)
> （或本地打开 [`images/s3_website_fullstack.html`](images/s3_website_fullstack.html)）。

**部署期注入如何工作**：`static/index.html` 里 API 地址留空（`const API =
""`），部署脚本用字符串替换写入真实的 `execute-api` 端点后上传 S3——改环境
只改注入值，页面代码零改动（现代前端 `.env` 构建的原始形态）。

**CORS 如何放行**：页面在 `s3.localhost` 域，API 在 `execute-api.localhost`
域，浏览器视为跨域。函数的每个响应都带
`Access-Control-Allow-Origin: *`

实测 GET/POST 的响应头存在且调用成功。
完整 CORS 还需处理 OPTIONS 预检（网关加 MOCK 集成，简单请求场景可省）。

**预签名直传如何工作**：后端 `generate_presigned_url("put_object", ...)` 把
"对指定 key 的一次 PUT + 120 秒有效期"签进 URL；浏览器持 URL 直接 PUT——
实测上传 200、桶内内容逐字节一致。后端全程只签发授权，不搬运字节。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **根路径 404 或返回列表**：本构建 website 端点对 `/` 不做 index 重定向
  （实测）。解法：直接访问 `/index.html`；真实 AWS 会返回 index 文档。
- **配置网站后立刻访问行为不对**：website 配置最终一致。解法：轮询到首页内容
  正确（脚本已内置）。
- **预签名 URL 报签名不匹配**：URL 绑定 method + key + 过期时间，任一改动即
  失效。解法：签发后原样使用，不手工改参数。
- **带 cookie 的跨域请求被拒**：`Access-Control-Allow-Origin: *` 与携带凭据
  互斥。解法：生产上写具体域名并加 `Allow-Credentials`。

深入问答：

- **Q: 静态站要不要加 CDN？** A: 生产必开 CloudFront：HTTPS（S3 website 端点
  只有 HTTP）、自定义域名、边缘缓存——S3 只当源站。
- **Q: SPA（单页应用，整站一个 HTML 由前端路由切换页面）路由刷新 404？** A: website 配置把 error.html 指向 index.html，
  前端路由接管；CloudFront 用自定义错误响应实现同样效果。
- **Q: 预签名直传如何防滥用？** A: 只签特定 key 与短有效期；签发前校验业务
  资格；落桶后接事件管道做扫描（lab 13）。
- **Q: 为什么不前后端同域？** A: 可以（CloudFront 把 /api 分流到网关），同域
  免 CORS；本实验刻意分离以演示 CORS 机制。

# 19 · S3 静态网站 + 无服务器后端联调

> 前端也能上 AWS：S3 的 website 托管能力 + 静态页 fetch API Gateway + DynamoDB，
> 组成一个真的能在浏览器打开的**迷你全栈应用**（留言板）。再加预签名直传，
> 覆盖前端与云交互的三种标准姿势。

## 1. 为什么需要它

- 静态资源（HTML/JS/CSS）放 S3、动态能力靠 API——**前后端彻底分离**的零服务器
  架构，个人项目与营销页的标准解。
- **跨域（CORS）**是前后端分离绕不开的第一坑：页面在 `s3.localhost`，API 在
  `execute-api.localhost`，浏览器视角就是跨域。
- 预签名直传让文件"从浏览器直达 S3"，不经过后端中转。

## 2. 总览：核心机制一图看懂

![S3 静态网站全栈](images/s3_website_fullstack.svg)

> 怎么看：浏览器从 S3 website 端点拿到注入了 API 地址的 index.html；页面 fetch
> 到 API Gateway（跨域，靠函数注入的 CORS 头放行）；POST 写入 / GET 回显留言
> 全部落 DynamoDB；文件直传走预签名 URL（虚线），不经过任何后端。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/19_s3_website_fullstack/images/s3_website_fullstack.html)
> （或本地打开 [`images/s3_website_fullstack.html`](images/s3_website_fullstack.html)）。

心智模型一句话：**S3 当 Web 服务器，API 当后端，CORS 是它们之间的一纸通行证。**

## 3. 快速开始

```bash
cd labs/19_s3_website_fullstack
./s3_website_fullstack.sh            # 建站点+API → 闭环断言 → 清理
# 打开浏览器访问: http://ho19-site.s3.localhost.localstack.cloud:4566/index.html
```

真实运行输出（节选）：

```text
=====> [observe] 网站端点：curl 静态页 → 200 且含 API 地址
  ✅ S3 website 端点返回 200（/index.html）
  ✅ 页面已注入 API 地址（fetch 可用）
=====> [observe] 后端闭环：POST 留言 → GET 回显（模拟页面 fetch）
  ✅ POST 留言 201 / ✅ GET 回显留言 / ✅ CORS 头存在
=====> [observe] 预签名直传：前端持 URL 直接 PUT 文件到桶
  ✅ 预签名 PUT 直传成功
```

## 4. 核心概念

### 4.1 website 托管 vs REST 访问

`aws s3 website` 配置 index/error 文档后，`bucket.s3.localhost.localstack.cloud`
走**网站语义**。实测差异：本构建 `/` 不做 index 重定向（返回桶列表），直接访问
`/index.html` 正常——真实 AWS 根路径会返回 index 文档。

### 4.2 CORS：三要素缺一不可

跨域请求能成，需要响应带 `Access-Control-Allow-Origin`（本实验由 Lambda 统一
注入 `*`）。生产上收紧为站点域名；浏览器还会对非简单请求先发 OPTIONS 预检
（网关需配 MOCK 集成，lab 05 有述）。

### 4.3 预签名直传

后端用 IAM 凭证签出 `put_object` 的预签名 URL 交给前端，浏览器直接 `PUT`——
后端只做授权不做搬运。实测：URL PUT 200，对象内容逐字节一致。

### 4.4 部署期注入：配置与代码分离

index.html 里不写死 API 地址，部署脚本把 `execute-api` 端点**注入**静态页后
再上传——多环境（dev/prod）只换注入值，这正是现代前端 `.env` 构建的原始形态。

## 5. 代码关键字段

```python
# board_lambda.py：每个响应都带 CORS 头
CORS = {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"}

# 预签名直传（后端签发，前端直传）
url = s3.generate_presigned_url("put_object",
    Params={"Bucket": bucket, "Key": "uploads/demo.txt"}, ExpiresIn=120)
# 浏览器: fetch(url, {method:"PUT", body: file})
```

坑清单：

- website 配置是最终一致，配置后立刻访问可能命中旧行为（脚本轮询兜底）；
- 预签名 URL 绑定 HTTP method + key + 过期时间，改任何一项签名即失效；
- `Access-Control-Allow-Origin:*` 与"携带 cookie"互斥，生产带凭据要写具体域名；
- 留言内容入库前截断/清洗——静态页输入不可信。

## 6. 文件结构

```text
labs/19_s3_website_fullstack/
├── README.md                    # 本文件
├── s3_website_fullstack.sh      # 主脚本：站点+API 部署 → 三段联调断言 → 清理
├── board_lambda.py              # 留言板后端（POST/GET + CORS）
├── static/index.html            # 静态页模板（部署时注入 API 地址）
└── images/
    ├── s3_website_fullstack.architecture.json  # 图源（Typed JSON IR）
    ├── s3_website_fullstack.html               # 交互版
    └── s3_website_fullstack.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: 静态站要不要开 CDN？** A: 生产必开 CloudFront：缓存、HTTPS（S3 website
  端点只有 HTTP）、自定义域名、防抖——S3 website 端点只作源站。
- **Q: 预签名直传如何防滥用？** A: URL 只签特定 key+method+短过期；后端签发前
  校验业务资格；落桶后用事件通知做病毒扫描/内容审核（lab 13 管道）。
- **Q: SPA 路由刷新 404？** A: website 配置把 error.html 指向 index.html（前端
  路由接管）；CloudFront 用自定义错误响应。
- **Q: 前后端联调最常踩的坑？** A: CORS 预检、响应头大小写、API 地址环境注入
  遗漏、预签名过期——本实验全部脚手架化。
- **Q: 为什么不把 API 也挂到同一域名？** A: 可以（CloudFront 分发 /api 到网关），
  同源免 CORS；本实验刻意分离以演示 CORS 机制。

## 8. 总结

静态托管、跨域放行、预签名直传、部署期注入——"浏览器直连云"的四个关键动作
全部落地，一个能在浏览器打开的迷你全栈应用就位。下一篇用 SSM Parameter Store
把散落的配置收进配置中心。

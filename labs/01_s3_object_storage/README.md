# 01 · S3 对象存储：版本化桶、生命周期与预签名 URL

> 想学 AWS，第一道坎是"没有账号不敢动手"。LocalStack 在本机容器里模拟了 S3 的
> API，`aws` CLI 只需换个 `--endpoint-url` 就能把对象存储玩明白。本实验从最朴素
> 的"上传一个文件"开始，一路做到版本回滚和免凭证下载——这四件事几乎覆盖了 S3
> 面试与日常运维的全部高频考点。

## 1. 为什么需要它

- S3 是 AWS 生态的"地基"：静态资源、备份、数据湖、Lambda 事件源，全都长在桶上。
- 生产事故里最贵的一类是**误删/误覆盖**。S3 的答案是版本控制：写入即追加新版本，
  删除只是打"删除标记"，任何一步都可回退。
- 而把文件安全地交给第三方（浏览器、临时脚本）又不泄漏凭证，靠的是**预签名 URL**：
  把"一次特定操作"签进 URL，到期自动作废。

## 2. 总览：核心机制一图看懂

![S3 对象存储架构](images/s3_object_storage.svg)

> 怎么看：开发者用带凭证的 CLI 访问 S3 API（实线主路径）；CLI 还能"签出"一个
> 预签名 URL 给 curl 免凭证下载（上方虚线）；桶内是**版本链**而非单文件（桶节点
> 标签），生命周期规则只是挂在桶上的配置（下方虚线）。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/01_s3_object_storage/images/s3_object_storage.html)
> （或本地打开 [`images/s3_object_storage.html`](images/s3_object_storage.html)）。

心智模型一句话：**桶是版本链的容器，"覆盖"和"删除"都只是往链上加新节点。**

## 3. 快速开始

```bash
cd labs/01_s3_object_storage
./s3_object_storage.sh            # apply → observe → clean 一条龙（约 15 秒）
./s3_object_storage.sh apply      # 只建资源
./s3_object_storage.sh observe    # 只跑演示与断言
./s3_object_storage.sh clean      # 删干净，环境复原
```

真实运行输出（节选）：

```text
=====> [observe] 覆盖写入 → 同一 key 出现两个版本
  ✅ readme.txt 有 2 个历史版本
=====> [observe] 回滚：按 VersionId 读回 v1
  ✅ v1 内容可完整读回（VersionId=AaByvQq8WVAHdayRHEB94FPr5dhW7XzN）
=====> [observe] 删除对象 → 版本化桶只是打了 delete marker
  ✅ GET 已 404：客户端视角对象消失了
  ✅ delete marker 落桶（这就是'删除'的真相）
=====> [observe] 预签名 URL：生成 → 真实 HTTP 下载 → 过期失效
  ✅ 预签名 URL 下载内容正确（无需任何凭证）
  ✅ 过期 URL 返回 200（注：LocalStack 对极短有效期不严格，真实 AWS 会 403）
=====> [clean] 删除桶内全部版本 + delete markers + 桶本身
  ✅ 桶已删除，环境复原
```

## 4. 核心概念

### 4.1 桶与对象：没有"目录"

`notes/readme.txt` 里没有目录 `notes/`，key 是**完整字符串**，前缀只是约定。
所以 S3 的"列目录"就是按前缀列出对象（`list-objects-v2 --prefix`），这也解释了
为什么"空目录"无法独立存在。

### 4.2 版本控制：写入即追加

启用 Versioning 后，同一个 key 每次 `PutObject` 生成新 `VersionId`，最新版标
`IsLatest=true`。**删除的真相**是插入一条 delete marker——GET 命中 marker 返回
404，但历史版本都在。移除 marker（`delete-object --version-id <marker>`）对象就
"复活"。

> ⚠️ 易错点：版本化桶直接 `delete-bucket` 会报 `BucketNotEmpty`——必须先物理删光
> 所有版本**和 delete markers**。本实验的 `purge_bucket()` 就是标准写法。

### 4.3 生命周期规则：过期是声明，不是命令

`configs/lifecycle.json` 声明"raw/ 前缀 30 天过期、非当前版本 7 天过期"。
注意：**LocalStack 只保存这份配置，不会真的删数据**；真实 AWS 由后台任务异步
执行，且"到期删除"通常在到期后 24~48 小时内才发生。

### 4.4 预签名 URL：把一次操作签进 URL

`aws s3 presign` 用 SigV4 把"GET 这个对象 + 过期时间"签名成 URL。持 URL 者
无需任何凭证即可完成这一次下载。本机实测：下载内容一致 ✅；但 LocalStack 不严格
校验极短有效期（`--expires-in 2` 过期后仍 200），真实 AWS 返回 403——这是
模拟器的已知差异，以真实环境为准。

## 5. 配置关键字段（configs/lifecycle.json）

```jsonc
{
  "Rules": [
    {
      "ID": "expire-raw-logs",              // 规则名，桶内唯一，运维靠它对账
      "Status": "Enabled",                  // Enabled/Disabled，停用不删配置
      "Filter": { "Prefix": "raw/" },       // 只对 raw/ 前缀生效；留空 {} 即全桶
      "Expiration": { "Days": 30 }          // 对象 30 天后整体过期
    },
    {
      "ID": "cleanup-noncurrent-versions",
      "Status": "Enabled",
      "Filter": {},
      "NoncurrentVersionExpiration": { "NoncurrentDays": 7 }  // 旧版本转非当前 7 天后清
    }
  ]
}
```

坑清单：

- `Filter` 与废弃的 `Prefix` 顶层字段不能混用，新版 API 一律写进 `Filter`；
- `NoncurrentDays` 从"变成非当前版本"起算，不是从创建起算；
- 版本化桶不加 `NoncurrentVersionExpiration` 等于永不释放空间，账单刺客。

## 6. 文件结构

```text
labs/01_s3_object_storage/
├── README.md                 # 本文件：原理 + 用法 + 考点
├── s3_object_storage.sh      # 主演示脚本：apply 创建 / observe 演示断言 / clean 清理
├── configs/
│   └── lifecycle.json        # 生命周期规则的声明式配置（apply 阶段挂载）
└── images/
    ├── s3_object_storage.architecture.json  # 架构图源（Typed JSON IR）
    ├── s3_object_storage.html               # 交互版架构图（自包含单文件）
    └── s3_object_storage.svg                # 双主题矢量图（本 README 内嵌）
```

## 7. 面试要点

- **Q: 开了版本控制后 delete 掉的对象还能恢复吗？** A: 能。删除只是插入 delete
  marker，用 `list-object-versions` 找到历史 VersionId 直接 GET，或删掉 marker 复活。
- **Q: S3 如何做到"强一致"？** A: 2020 年 12 月起 S3 对新建与覆盖写都是强一致
  (read-after-write)；同 key 并发写以最后写入者获胜，GET 永不读到旧版本。
- **Q: 预签名 URL 的签名里包含什么？过期后访问会怎样？** A: SigV4 把 method、
  path、过期时间、凭证范围签进 query；过期返回 403（LocalStack 对极短有效期不严格）。
- **Q: 桶名为什么要求全局唯一？** A: 桶名同时是虚拟主机域名的一部分
  (`bucket.s3.amazonaws.com`)，全局 DNS 命名空间里必须唯一；LocalStack 单机无此
  约束，但命名习惯应与真实一致。
- **Q: 生命周期规则误配了怎么止损？** A: 规则可改为 Disabled 立即停止匹配；已进入
  过期队列的对象不可撤回，所以生产上先 Disabled→观察→再删除。

## 8. 总结

一个桶 + 版本链 + 声明式过期 + 签名 URL，就是 S3 的日常。回滚、防误删、临时分享
三个故事在本实验全部真机验证。下一篇把"文件系统"换成"键值数据库"：DynamoDB 的
分区键、排序键与条件写入——当你的访问模式从"整存整取"变成"按维度查询"，S3 就
不再是答案。

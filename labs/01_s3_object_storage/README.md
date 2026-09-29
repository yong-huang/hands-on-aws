# 01 · S3 对象存储：版本化桶、生命周期与预签名 URL

> S3（Simple Storage Service，AWS 的对象存储服务）是云端"放文件"的事实标准。
> 本实验在本机 LocalStack（一个模拟 AWS API 的容器）里，用一个脚本跑通对象上传、
> 版本回滚、声明式过期与免凭证下载，并配 14 项真实断言。

## Background

在没有对象存储之前，把文件放在云端通常意味着自己开一台服务器挂载磁盘，再用
FTP 或自建 HTTP 服务对外提供下载。

这种方式会撞上三堵墙。第一，磁盘容量与扩容要自己管，文件多了还得自己做分片。
第二，文件被误删或误覆盖没有任何补救手段——磁盘上就是一份，删了就没了。第三，
把文件给别人下载需要分发长期凭证或自己写鉴权，凭证一旦泄漏，整台机器暴露。

S3 在 2006 年应运而生：它把"存文件"抽象成"往桶（bucket，存储的顶层容器）里放
对象（object，文件内容加上一个叫键 key 的完整路径字符串）"，容量、冗余、按次
计费全部由服务端接管。本实验要做的，是在本机把这套模型的核心机制逐个跑通。

## What

一句话定义：S3 是一种通过"桶 + 键"来存放和读取不可变对象的对象存储服务——
每次写入都产生一个新版本，而不是修改旧文件。

心智模型：可以把启用版本控制的桶想象成一本只追加的账本——每次"覆盖"是在账本
末尾加一行，"删除"只是贴一张"此行作废"的便签（delete marker，删除标记）。

但和真实账本不同的是：贴了作废便签后，GET 请求会拿到 404，普通使用者视角里
文件确实消失了；只有知道版本号（VersionId，每次写入生成的唯一标识）的人才能
翻回历史行。

三个容易误解的基础事实：

- **没有目录**：`notes/readme.txt` 是一个完整的键名字符串，`notes/` 只是前缀
  约定。所以"列目录"实际是按前缀过滤对象，"空目录"无法独立存在。
- **删除的真相**：删除操作插入的是一条 delete marker，历史版本仍然在桶里。
- **过期是声明**：生命周期规则（lifecycle rule，一段描述"哪些对象在什么条件
  下过期"的 JSON 配置）只是声明意图，清理由服务端后台执行。

## When to Use

典型场景——在做什么事的时候需要它：

- 托管静态资源：网站的前端文件、软件安装包、图片视频，直接以 HTTP 方式分发。
- 备份与归档：数据库 dump、日志文件按天落桶，配合生命周期规则自动降冷、过期。
- 作为事件源：文件一落桶就通知下游处理（缩略图、病毒扫描、或流入数据湖——集中存放原始数据供后续分析的大仓库）。

何时不用：数据需要随机更新其中一小块、或要求事务（多条记录同生共死）时，对象
存储的"整存整取"模型会很别扭，应该用数据库；需要像本地盘一样挂载、随机读写的
场景应选块存储或文件存储。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| S3 | 对象存储，HTTP 存取，按版本追加 | 静态资源、备份、事件源 |
| EBS | 块存储，挂到单台虚拟机当磁盘 | 数据库文件、操作系统盘 |
| EFS | 文件存储，可被多台机器像共享文件夹一样同时挂载（遵循 Unix 文件系统接口）| 多机共享的文件系统语义 |
| DynamoDB | 键值数据库，随机更新与查询 | 结构化数据的增删改查 |

## Quick Start

前置条件：LocalStack 容器已运行（可用仓库根的 `bash scripts/load_resources.sh
probe` 确认），本机装有 aws CLI。以下命令全部通过 `--endpoint-url` 指向
LocalStack，凭证使用固定的 `test/test`。

```bash
cd labs/01_s3_object_storage
./s3_object_storage.sh            # apply → observe → clean 一条龙（约 15 秒）
./s3_object_storage.sh apply      # 只建资源
./s3_object_storage.sh observe    # 只跑演示与断言
./s3_object_storage.sh clean      # 删干净，环境复原
```

脚本 observe 阶段的真实输出（节选）：

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

新手最可能遇到的第一个失败点是 `Unable to locate credentials`——脚本内部已
固定导出 `AWS_ACCESS_KEY_ID=test` 等环境变量，手动敲命令时需要先 export 同样的
值。第二个失败点是 404：LocalStack 没启动，或端口被其他进程占用。

实验用到的声明式配置 `configs/lifecycle.json`，它定义了两条过期规则：

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

## How It Works

![S3 对象存储架构](images/s3_object_storage.svg)

> 怎么看：实线主路径是开发者带凭证调用 S3 API；桶内是**版本链**而非单文件。
> 上方虚线是"签出预签名 URL 给 curl 免凭证下载"的旁路；下方虚线表示生命周期
> 规则只是挂在桶上的声明式配置。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/01_s3_object_storage/images/s3_object_storage.html)
> （或本地打开 [`images/s3_object_storage.html`](images/s3_object_storage.html)）。

**版本链如何工作**：apply 阶段执行 `put-bucket-versioning` 启用版本控制后，
每次 `PutObject` 都生成新的 VersionId，最新版标记 `IsLatest=true`。

输出里"readme.txt 有 2 个历史版本"来自 `list-object-versions` 对这条链的计数；
"按 VersionId 读回 v1"的断言能通过，是因为删除操作只插入 delete marker，从未
物理移除任何字节。

**预签名 URL 如何工作**：`aws s3 presign` 用 SigV4（AWS 第四版签名算法）把
请求方法、路径、过期时间和凭证范围一起哈希，签成带查询参数的 URL；签名验证由
服务端完成，持 URL 者不需要任何凭证。

脚本里 `--expires-in 2` 加 `sleep 3` 的对照实验，演示的就是过期时间的时效性。

**生命周期规则如何工作**：规则只是桶上的配置。你在 Quick Start 看到脚本 clean
后桶里空空如也，那是脚本主动删除的结果，不是过期规则执行的——LocalStack 只保存
规则配置，不模拟后台清理；真实 AWS 的过期删除通常在到期后 24~48 小时内完成。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法）：

- **版本化桶删不掉，报 `BucketNotEmpty`**：原因——启用了版本控制的桶里还有
  历史版本和 delete marker。解法——先 `list-object-versions` 列出全部，再逐个
  `delete-object --version-id` 物理删除；脚本里的 `purge_bucket()` 就是标准写法。
- **生命周期规则配了但文件没消失**：LocalStack 只保存配置不执行过期；真实 AWS
  的清理也是异步的（到期后 24~48 小时）。验证配置用
  `get-bucket-lifecycle-configuration` 即可。
- **预签名 URL 过期了还能下载**：现象——`--expires-in 2` 过期后请求仍 200；
  原因——LocalStack 不严格校验有效期（脚本断言里已注明）；解法——以真实 AWS
  的 403 行为为准。
- **`Filter` 与 `Prefix` 混用报错**：新版 API 的过滤条件必须写在 `Filter` 里，
  顶层 `Prefix` 字段已废弃，二者不能混用。
- **版本化桶不加过期规则**：旧版本永不释放，存储费用持续累积——生产桶应搭配
  `NoncurrentVersionExpiration`。

深入问答：

- **Q: 删掉的对象还能恢复吗？** A: 能。删除只是插入 delete marker，用
  `list-object-versions` 找到历史 VersionId 直接 GET，或删除 marker 让对象
  复活。
- **Q: S3 是强一致的吗？** A: 2020 年 12 月起新建与覆盖写均为强一致
  （read-after-write）；同 key 并发写以最后写入者获胜，GET 不会读到旧版本。
- **Q: 预签名 URL 里签了什么？过期后会怎样？** A: SigV4 把 method、路径、
  过期时间、凭证范围签进查询参数；过期后真实 AWS 返回 403。
- **Q: 桶名为什么要求全局唯一？** A: 桶名会出现在虚拟主机域名
  （`bucket.s3.amazonaws.com`）里，属于全局 DNS 命名空间；LocalStack 单机没有
  这个约束，但命名习惯应与真实一致。
- **Q: 生命周期规则配错了怎么止损？** A: 把规则改成 `Disabled` 立即停止匹配新
  对象；已进入过期队列的对象不可撤回，生产上先 Disabled、观察、再删除。

# 09 · 部署机制解剖：bootstrap、资产 staging 与手工变更集

> 把 CDK deploy 的黑盒拆开：bootstrap 建出的 CDKToolkit 栈与资产桶里到底
> 有什么；`Code.from_asset` 的 zip 如何以内容散列落入 staging 桶；以及——
> 对同一份 synth 模板，用原生 CFN 变更集三步手工部署并跑通资产 Lambda，
> 证明 CDK 产出就是普通 CFN 模板。

## Background

前八个实验一直把 `cdklocal deploy` 当黑盒用。这个黑盒其实是一条清晰的
流水线：**synth（构造树 → cdk.out）→ 资产（zip/模板文件 → staging 桶）→
参数（AssetParameters 填桶名与键）→ CFN（拿模板走标准部署）**。

bootstrap 是流水线的地基：`cdklocal bootstrap` 创建一个名为 CDKToolkit 的
CFN 栈，内含资产 staging 桶（命名 `cdk-hnb659fds-assets-<账号>-<区域>`）与
部署角色。cdk/01 曾因"无 bootstrap 禁资产"绕开 BucketDeployment——本实验
正面把这条链路拆开看：CLI 与 CFN 的接口契约就是模板里那几个
AssetParameters。

## What

一句话定义：部署一个带 `Code.from_asset` 真资产的栈，断言 zip 以内容散列
（`assets/<hash>.zip`）落进 staging 桶且 Lambda 可 invoke；再用
`create-change-set → describe（审阅）→ execute-change-set` 三步，亲手填好
资产参数部署同一份模板的变体，跑通同样的资产 Lambda。

心智模型：CDK CLI 是个"带资施工队"——图纸（模板）它画，建材（zip 资产）
它运进它自己的仓库（staging 桶），再在图纸上写好建材位置（Parameters）。
手工变更集证明：仓库谁都可以用，图纸谁都可以施工——CLI 没有任何魔法。

## When to Use

典型场景：

- 部署失败要"看清现场"：资产没上传？参数没填对？还是 CFN 侧问题——
  知道流水线四段才能定位是哪段断了。
- 审计/合规：change set 先审后行是生产部署的标准关口（labs/26 的
  CFN 层变更集在这里升级为"部署 CDK 产物"）。
- CI 自建部署通道：绕过 CLI、直接消费 CDK synth 产物的团队管线。

何时不用：日常部署（CLI 全自动）；无 bootstrap 环境的实验（cdk/01/32
的约束；本实验前置就是先 bootstrap）。

## Quick Start

前置条件：LocalStack 运行中；`cdklocal bootstrap` 已就绪（脚本内含探活，
缺失时自动补）。

```bash
cd cdk/09_cdk_deploy_anatomy
./cdk_deploy_anatomy.sh    # apply（bootstrap+资产栈）→ observe（手工变更集）→ clean
```

observe 阶段 9 条断言全绿即通过：资产入桶、资产 Lambda invoke、变更集
审阅、手工部署、双栈资源可用、解剖笔记落盘。

## How It Works

部署链路四段（output/deploy_anatomy.md 有完整笔记）：

| 段 | 发生什么 | 本实验断言 |
|:---|:---|:---|
| 1 synth | 构造树 → cdk.out（模板 + asset.<hash>/ + manifest） | 模板含 AssetParameters |
| 2 资产 | `Code.from_asset` 打包 zip → 上传 `assets/<hash>.zip` | staging 桶按散列找到对象 |
| 3 参数 | CLI 填模板 Parameters：S3Bucket / S3VersionKey / ArtifactHash | 手工部署亲手填同样三个 |
| 4 CFN | 标准 CFN 部署，从桶拉资产 | 变更集三步 + Lambda invoke |

手工变更集的资产参数（从 CDK CLI 成功部署的栈里照抄格式）：

- `S3Bucket` = staging 桶名；
- `S3VersionKey` = `assets/||<hash>.zip`（**双竖线分隔**，模板用
  `Fn::Select(0/1, Fn::Split("||", …))` 把两段拼回完整键——格式错一个
  字符就是 S3 NoSuchKey）；
- `ArtifactHash` = 资产内容散列。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **资产对象键带 `assets/` 前缀**：按 `<hash>` 前缀在 staging 桶里找不到
  对象。解法：按 `assets/<hash>` 查。
- **`create-change-set` 对不存在的栈报 ValidationError**：LocalStack 要求
  显式 `--change-set-type CREATE`（AWS 默认值本可自动判定）。
- **cdk.out 陈旧资产目录导致部署旧代码**：synth 不清理 cdk.out 里上一次的
  `asset.<旧散列>/` 目录——用 `ls | head -1` 推导散列会选中陈旧目录，引用
  旧 zip 部署出旧代码（系列迁移改名时实测踩中）。解法：散列从合成模板的
  `AssetParameters<64位散列>ArtifactHash` 参数名提取，那是 CDK 记录的唯一
  可信来源。
- **AWS CLI v2 重复 list 选项最后一个生效**：三个 `--parameters` 只活
  下来 ArtifactHash，报 "must have values"。解法：单 flag 多 token
  （`--parameters "K1=V1" "K2=V2"`）。
- **`S3VersionKey` 分隔符是双竖线**：单竖线会让 `Fn::Select` 报
  "requires a list argument with two elements"；拼错内容则是部署期
  S3 NoSuchKey。解法：照抄 CDK CLI 成功部署的栈参数
  （`describe-stacks → Parameters`）——这是排这类错的最快路径。
- **手工栈 CDK CLI 不认识**：`cdklocal destroy ho09-manual-stack` 无效，
  必须走原生 `cloudformation delete-stack`——恰好证明它是普通 CFN 栈。
- **heredoc 消息里 `$SB）` unbound**：多字节字符紧跟 `$var`（cdk/02
  同款）。解法：`${SB}` 定界已成纪律。

深入问答：

- **Q: bootstrap 的 CDKToolkit 栈里有什么？** A: 资产 staging 桶 +
  文件资产/容器资产的上传角色（DeployRole、FilePublishingRole 等）+
  输出（BucketName/DomainName）。destroy 它会破坏所有依赖资产的部署。
- **Q: 资产散列是内容散列还是路径散列？** A: 内容散列——改一行代码，
  散列变、上传新 zip、旧 zip 留在桶里（可清理）；不改代码重复部署，
  散列不变、零上传。与逻辑 ID 散列（cdk/01：只看构造路径）互补。
- **Q: 手工通道和 `cdk deploy --no-execute` 的关系？** A: CLI 可以生成
  change set 不执行（审核模式）。本实验手工三步是同一件事的"裸奔版"——
  适合 CI 里"先审后行"的闸门，或没有 CLI 的环境。
- **Q: staging 桶会无限膨胀吗？** A: 会。每次资产内容变化都新增对象，
  旧对象不自动删。清理策略：按"当前模板引用的散列"保留，其余定期
  手工清理（真实 AWS 有生命周期规则方案）。

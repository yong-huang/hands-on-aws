# 🏗️ cdk — AWS CDK 进阶实验系列（11 个）

> 与 [`labs/`](../labs/)（AWS 服务基础 30 实验）平行的独立系列：从「会用
> [labs/28](../labs/28_cdk_stack/) 的一键栈」到「构造库设计 → 栈工程 →
> IaC 测试 → 流水线交付」的生产级 CDK 工程能力。
> 全部基于 LocalStack（cdklocal）、不触碰真实 AWS 账户；Python 栈
> （aws-cdk-lib 2.x）；学习清单见 [docs/cdk.md](../docs/cdk.md)。
> **编号 01-11 与清单项目 1-11 一一对应。**

## 实验总表

| 实验 | 清单项目 | 主题 | 一句话 |
|:---|:---:|:---|:---|
| [01](01_cdk_construct_anatomy/) | 1 | CDK 构造解剖 | L1/L2/L3 三层写法逐项对照、escape hatch 三连（含模板≠终态实测） |
| [02](02_cdk_construct_lib/) | 2 | 自定义 Construct 库 | Props 合成期校验、默认值覆盖、命名隔离，双栈端到端冒烟 |
| [03](03_cdk_aspect_governance/) | 3 | Aspect 治理 | 标签强制 + 三类违规合成期拦截（L2 未加密/L1 绕过/通配 IAM） |
| [04](04_cdk_stack_sharing/) | 4 | 跨栈引用三通道 | Export/ImportValue · NestedStack · SSM，URL 逐一比对 + 产物差异表 |
| [05](05_cdk_env_lifecycle/) | 5 | 多环境与生命周期 | context 形状分支、--parameters 部署期取值、RETAIN 存活与人工收尾 |
| [06](06_cdk_custom_resource/) | 6 | Custom Resource | CR 三幕（播种/刷新/清场）、物理 ID 稳定走 Update、零孤儿 |
| [07](07_cdk_assertions/) | 7 | fine-grained 断言测试 | aws_cdk.assertions 12 条合成期断言 + 两种注入抓红（不触云，秒级） |
| [08](08_cdk_snapshot_diff/) | 8 | 快照与 diff 守门 | 模板钉进仓库、单行改动双红、显式更新快照恢复绿、部署归零 |
| [09](09_cdk_deploy_anatomy/) | 9 | 部署机制解剖 | bootstrap/资产 staging/AssetParameters，手工变更集部署 CDK 产物 |
| [10](10_cdk_local_pipeline/) | 10 | ⛓️ 本地 CI 流水线 | make 六阶段（synth→test→diff→deploy→smoke→destroy），注入拦在 test |
| [11](11_cdk_order_platform/) | 11 | 🏁 综合实战·订单平台 | 十能力合流：L1 API GW + CR 种子 + Aspect + 双环境 + 流水线，prod 全绿 |

## 学习路线

- **阶段一 构造深化（01-03）**：从会用 L2 到会设计自己的 Construct
- **阶段二 Stack 工程（04-06）**：跨栈组合、多环境、部署生命周期扩展
- **阶段三 测试与部署机制（07-09）**：把 CDK 代码当生产代码对待
- **阶段四 交付与综合（10-11）**：一条命令从源码到可用系统

## 快速开始

```bash
# 前置（同根 README 环境要求）：LocalStack + cdklocal + aws-cdk-lib
localstack start -d
bash scripts/load_resources.sh            # 根目录体检脚本

# 含资产的实验（04/09/11）首次需 bootstrap
cdklocal bootstrap aws://000000000000/us-east-1

# 跑一个实验（每个实验主脚本默认 apply → observe → clean 全生命周期）
cd cdk/01_cdk_construct_anatomy && ./cdk_anatomy.sh

# 流水线形态的两个实验
cd cdk/10_cdk_local_pipeline && make pipeline
cd cdk/11_cdk_order_platform && make pipeline APP_ENV=prod
```

目录约定与 `labs/` 一致：每个实验 = 主脚本（或 Makefile）+ 六段式 README +
架构图三件套（`images/`）；所有断言均在本机真实跑通，模拟器差异如实记录在
各 README「Pitfalls & Q&A」。

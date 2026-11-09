# 08 · 快照测试与 diff 守门：把模板钉进仓库

> 模板快照进 snapshot/，单行属性改动触发"双红"（快照测试红 + diff 非空），
> 显式更新快照（= 审阅并接受变更）恢复绿，部署后 diff 归零。IaC 版
> "改一行，全链路知道"。

## Background

cdk/07 的断言是"点检"——挑关键属性验证。快照测试是"全量对账"：整份
合成模板钉进仓库，任何漂移（哪怕一个字段）都红。两者互补：断言抓
"关键性质"，快照抓"一切未审阅的变化"。

diff 守门是同一思想在部署侧的延伸：`cdk diff` 对比"本地合成"与"线上
部署"，非空即拦截。快照（进 CI 前的图纸审）+ diff（部署前的现状对账）
构成两道门——前者防止"无意识改模板"，后者防止"部署了没审过的东西"。

## What

一句话定义：pytest 把 `Template.from_stack` 的产物与
`snapshot/ho08-stack.template.json` 逐字段比对（报出精确 JSON 路径的
漂移清单）；`cdklocal diff` 的变更行数作为门禁退出码。显式更新走
`UPDATE_SNAPSHOT=1`——把"接受变更"变成一个显式动作。

心智模型：快照是"图纸备案"——每次改图都要重新备案（git diff 备案变更
一目了然）；diff 守门是"开工对图"——施工队（CFN）进场前，先核对图纸
与在建工程，有出入就得先说明。

## When to Use

典型场景：

- 模板漂移零容忍的仓库：任何依赖升级、CDK 版本变化引起的模板变化，
  都必须被"看见并审阅"。
- 变更审查：`git diff snapshot/` 就是这次部署的全部影响面，review 成本
  最低的 IaC 变更说明。
- 与 cdk/07 组合：断言管"性质"，快照管"全量"，双保险覆盖模板层面。

何时不用：高频参数化部署（快照会天天红，噪音淹没问题）；团队还在
频繁探索阶段（备案成本大于收益）；已经有严格的 change set 人工审批
流程且模板巨大（快照 diff 会淹没真正的语义变更）。

## Quick Start

前置条件同 cdk/01-36（需 LocalStack，diff 要和线上对账）。

```bash
cd cdk/08_cdk_snapshot_diff
./cdk_snapshot_diff.sh    # apply（基线归零）→ observe（双红→更新→归零）→ clean
```

observe 阶段 7 条断言全绿即通过：单行改动双红、显式更新恢复绿、
部署归零、还原归零。

## How It Works

`cdk_app/`（~100 行）：

- **app.py**：`VISIBILITY_SECONDS = 30` 是单行改动点（脚本 sed 30↔60）。
- **test_snapshot.py**：`normalized()` 剔除每次合成都漂移的元数据字段
  （Metadata 版本戳）；`_diff()` 递归比对输出精确 JSON 路径
  （`$.Resources.JobsDF1CC2D4.Properties.VisibilityTimeout: 30 → 60`）；
  `UPDATE_SNAPSHOT=1` 重录并 skip（"更新"不算"通过"，重跑才算——防止
  更新动作掩盖真实回归）。
- **diff_gate**：`cdklocal diff` 变更行计数，0 行才算通过（CI 门禁语义）。
- **observe 全链路**：改一行 → 双红（漂移 2 处：队列属性 + 对应 Output）
  → `UPDATE_SNAPSHOT=1` 审阅接受 → 部署 → 线上 60s + diff 归零 →
  单行还原 → 再审 → 再部署 → 全部归零。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **diff 变更行走 stderr**：本版 CDK CLI 把 `[~]` 行打到 stderr，
  `2>/dev/null` 会把门禁变成"永远通过"。解法：`cdklocal diff 2>&1`。
  这是本实验最危险的一个坑——门禁静默失效比没有门禁更糟。
- **diff 默认走 read-only change set**：输出前有一行
  "Hold on while we create a read-only change set..."。要纯模板对比
  可加 `--method=template`（更快但拿不到替换级别的精确信息）。
- **快照里混入每次都变的字段**：Metadata 版本戳会让快照永远红。
  解法：归一化时剔除已知易变键（本实验的 VOLATILE_KEYS）。
- **中断现场会污染重跑**：单行改动停留在 60 时基线必红。解法：
  apply 开头归一现场（常量回 30 + 重录快照），脚本幂等。
- **UPDATE_SNAPSHOT 更新不算通过**：更新后 pytest skip，必须重跑一次
  green——否则"接受变更"的动作会掩盖同一次运行里的其他漂移。

深入问答：

- **Q: 快照测试和 git 里的 cdk.out 模板有什么区别？** A: cdk.out 是
  构建产物（该 gitignore），snapshot 是审阅基线（该提交）。前者是
  "这次合成了什么"，后者是"我们认可的应该是什么"。
- **Q: 快照红了一定是坏事吗？** A: 不一定——依赖升级带来的合理变化也红。
  快照测试的价值不是"禁止变化"，而是"变化必须被显式看见"：git diff
  快照文件就是最诚实的变更说明。
- **Q: 为什么不用 pytest 快照插件（pytest-snapshot/instantiate）？**
  A: 自带 40 行实现的收益是流程完全透明（更新即写文件、语义归一可控、
  无新依赖），教学与维护都更直接。
- **Q: 守门放 CI 哪个位置？** A: 快照测试进 PR 检查；diff 守门在部署
  作业最前（diff 非空且未获批准 → 终止）。两道门分别对应"代码合并"与
  "环境变更"两个审批关口。

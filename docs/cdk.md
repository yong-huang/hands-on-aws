# 🏗️ AWS CDK 进阶 11 小项目学习清单 · Todo List

> 通过 11 个小项目（每项目 150-300 行 Python CDK + 断言验证）把 CDK 从「会用 labs/28 的一键栈」
> 推进到「构造库设计 → 栈工程化 → IaC 测试 → 流水线交付」的生产级工程能力
> 约束：全部项目基于 **LocalStack 免费版（cdklocal）**，不触碰真实 AWS 账户、断网可跑；
> Python 栈（aws-cdk-lib 2.x）与 labs/28 一致；动手实验落 `cdk/01_cdk_*` 起延续编号
> 串联机制：知识体系型——阶段即能力等级（构造深化 → Stack 工程 → 测试与部署机制 → 交付与综合），
> 项目 2 产出的构造库被项目 4-11 反复复用，项目 11 终极串联
> 预计周期：4 周（每天 2 小时）

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 LocalStack 项目「[名称]」（CDK 进阶清单项目 [N]）。请给我完整 Python CDK 代码（cdklocal + aws-cdk-lib 2.x），约 [行数] 行，实验目录 cdk/（编号=项目号，两位），附可执行验收命令与断言。只输出代码。` |
| **写断言测试** | `用 aws_cdk.assertions 给 CDK 构造「[名称]」写 pytest 测试：hasResourceProperties/Matchers 断言 [要点]，并故意注入 [错误配置] 验证测试能抓红。` |
| **synth 产物看不懂** | `解释这段 cdklocal synth 模板片段：[粘贴]。重点说明逻辑 ID 散列、Fn::GetAtt、DependsOn 排序的成因。` |
| **排障** | `cdklocal [命令] 报错：[粘贴]。结合 LocalStack 免费版能力边界分析根因并给修复。` |

## 📊 总进度

进度：███░░░░░░░░░░░░░░░░░ 3/11 (27%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：构造深化 | 3 | 3 |
| 第二阶段：Stack 工程 | 3 | 3 |
| 第三阶段：测试与部署机制 | 3 | 3 |
| 第四阶段：交付与综合 | 2 | 2 |
| **合计** | **11** | **11** |

---

## 🗂️ 第一阶段：构造深化（项目 1-3）

> **目标**：从「会用 L2」到「会设计自己的 Construct」——理解三层构造模型并亲手造轮子

### [x] 项目 1：三层构造解剖与 escape hatch

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | L1（CfnBucket）、L2（s3.Bucket）、L3（官方 pattern）、合成模板差异、escape hatch（defaultChild/addOverride） |
| **技术栈** | cdklocal + aws-cdk-lib 2.268（✅ 已实测，labs/28） |
| **验收标准** | 同一 S3 bucket 用 L1/L2/L3 三种写法各 synth 一份模板存档，产出逐项差异对照表（默认注入属性数、命名散列、加密默认值）；用 escape hatch 改写 L2 的一个默认属性后 deploy，`awslocal s3api` 断言该属性在线上资源真实生效 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「三层构造解剖与 escape hatch」（CDK 进阶清单项目 1）。请给我完整 Python CDK 代码约 180 行：同一 S3 bucket 用 CfnBucket(L1)/s3.Bucket(L2)/官方 L3 pattern 三种写法实现，分别 synth 存档并输出逐项差异对照表；用 defaultChild/addOverride 改写 L2 一个默认属性，附 deploy + awslocal s3api 断言命令。只输出代码。`

**完成日期**：2026-10-27（cdk/01_cdk_construct_anatomy，11 断言全绿）
**踩坑记录**：override 必须瞄准 CFN 规范属性名（ServerSideEncryptionByDefault），SDK 名会静默合成假键；PAB 单字段 False 被引擎归一化成全 True（模板≠终态）；CDK 2.268 的 L2 不再注入 PublicAccessBlock；auto_delete_objects 生成资产需 bootstrap；BucketDeployment 撞 jsii+typeguard 协议检查 bug → L3 换 Trail

---

### [x] 项目 2：自定义可复用 Construct 库

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | Construct 属性接口、入参校验、默认值设计、命名空间隔离、跨 Stack 复用 |
| **前置** | 项目 1 |
| **验收标准** | 同一 App 的两个 Stack 各实例化一份构造，deploy 后断言 2 组「S3+SQS+Lambda+DDB」全部可用且命名互不冲突；传入非法属性（如空队列名）在 synth 阶段抛出带原因的错误（退出码非零） |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「自定义可复用 Construct 库」（CDK 进阶清单项目 2）。请给我完整 Python CDK 代码约 250 行：把 S3+SQS+Lambda+DDB 封装为带属性接口、入参校验、默认值的 OrderPipelineConstruct，在两个 Stack 中各实例化一份，附 synth 期非法入参报错断言与 awslocal 资源可用性断言。只输出代码。`

**完成日期**：2026-10-27（cdk/02_cdk_construct_lib，14 断言全绿，双管道端到端冒烟）
**踩坑记录**：lambda.Function 无 removal_policy 参数；bash 消息多字节字符紧跟 $var 会并进变量名（一律 ${var}）；事件源映射部署后非即时 Enabled 需轮询；InlineCode 有 4096 字符上限

---

### [x] 项目 3：Aspect 治理——标签强制与合规拦截

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | IAspect/visit、Tags.of 批量打标、合成期合规检查、违规累积与抛出 |
| **前置** | 项目 1 |
| **验收标准** | 故意构造「未加密 bucket + 通配 Action IAM」的栈被 Aspect 在合成期拦截：报错一次性列出全部违规项、退出码非零；修复后 deploy 成功，逐资源断言标签齐全（s3api get-bucket-tagging 等） |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Aspect 治理——标签强制与合规拦截」（CDK 进阶清单项目 3）。请给我完整 Python CDK 代码约 150 行：自定义 IAspect 给全资源打标签并拦截未加密 bucket 与通配 IAM，违规累积到 synth 期一次抛出；附不合规栈被拦截的断言与修复后标签齐全的 awslocal 断言。只输出代码。`

**完成日期**：2026-10-27（cdk/03_cdk_aspect_governance，10 断言全绿，3 类违规拦截验证）
**踩坑记录**：Aspects.of().add() 在 Python 侧触发 jsii 序列化 bug（@jsii.implements 亦无效）→ find_all+visit 等价应用；ITaggable 非 runtime_checkable 需鸭子判定；CfnBucket kwarg 走 camelCase jsii struct；deploy 会重新合成须带 context；拦截逻辑必须有人调用（"0 违规"假阴性）

---

## 🗂️ 第二阶段：Stack 工程（项目 4-6）

> **目标**：像平台工程一样组织栈——跨栈组合、多环境、部署生命周期扩展

### [x] 项目 4：跨栈引用与参数共享三通道

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行 |
| **核心知识点** | Stack 间属性引用（自动 GetAtt/ImportValue）、NestedStack、SSM Parameter Store 共享 |
| **前置** | 项目 2 |
| **技术栈** | 嵌套栈/Export 机制已在 labs/26 实测（CFN 层面 ✅） |
| **验收标准** | 三通道各部署成功且消费端断言拿到正确值（Lambda 环境变量 / SSM get-parameter）；产出对照表记录 synth 产物差异（Export/Import vs 嵌套模板 vs SSM 查询）与各自适用场景 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「跨栈引用与参数共享三通道」（CDK 进阶清单项目 4）。请给我完整 Python CDK 代码约 220 行：同一队列 URL 用 Stack 间属性引用、NestedStack、SSM Parameter 三种方式共享给消费方 Stack，附各通道部署断言与 synth 产物差异对照表。只输出代码。`

**完成日期**：2026-10-27（cdk/04_cdk_stack_sharing，8 断言全绿，三通道 URL 逐一比对）
**踩坑记录**：AWS::SSM::Parameter 的 CFN provider 不可用（双写自撞）→ 参数改脚本写入；get-parameter 对含 / 路径名全异常 → 参数名无斜杠；NestedStack 资产需 bootstrap（已探活可用）；嵌套队列断言基准别拿错

---

### [x] 项目 5：多环境参数化与生命周期策略

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | context 环境分支、CfnParameter vs Context 取舍、RemovalPolicy/DeletionPolicy、环境差异化配置 |
| **前置** | 项目 4 |
| **⚠️ 风险** | LocalStack 对 `DeletionPolicy: Retain` 的栈删除语义未实测 → 开工先最小探活；若不实现则验收降级为 synth 模板级断言，学习目标不变 |
| **验收标准** | `-c env=dev` 与 `-c env=prod` 各部署一次，断言两套配置差异真实落地（模板属性不同 + awslocal 线上资源属性不同）；prod 资源带 Retain 策略，destroy 后探查保留资源仍在、dev 资源全清 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「多环境参数化与生命周期策略」（CDK 进阶清单项目 5）。请给我完整 Python CDK 代码约 200 行：context 驱动 dev/prod 双环境（副本数、加密开关、RemovalPolicy 差异），对比 CfnParameter 与 Context 取舍，附双环境部署差异断言与 Retain 资源存活探查命令。只输出代码。`

**完成日期**：2026-10-27（cdk/05_cdk_env_lifecycle，11 断言全绿，Retain 线上验证）
**踩坑记录**：CfnParameter 赋值走 --parameters 而非 context；BillingModeSummary 在 PROVISIONED 时省略；查询空集输出 "None" 被 read 当对象键造删除标记；版本化桶要清到删除标记；CfnOutput/CfnParameter 撞构造 ID（33 同款）

---

### [x] 项目 6：Custom Resource——把任意动作接进部署生命周期

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | CustomResource L2、Lambda-backed CR、physicalResourceId、Create/Update/Delete 事件 |
| **前置** | 项目 2 |
| **技术栈** | Lambda-backed CR 已在 labs/26 实测（CFN 层面 ✅）；CDK L2 侧开工验证；AwsCustomResource 为选做 ⚠️ 探活 |
| **验收标准** | deploy 完成后断言 DDB 表中存在 3 条种子数据；改种子配置再部署触发 Update 事件且数据刷新；destroy 后 awslocal 断言无孤儿资源残留 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「Custom Resource——把任意动作接进部署生命周期」（CDK 进阶清单项目 6）。请给我完整 Python CDK 代码约 180 行：Lambda-backed CustomResource 在 Create/Update/Delete 时播种/刷新/清理 DDB 种子数据，附 deploy/update/destroy 三阶段的数据断言命令。只输出代码。`

**完成日期**：2026-10-27（cdk/06_cdk_custom_resource，9 断言全绿，Create/Update/Delete 三幕验证）
**踩坑记录**：CR Lambda 崩溃=栈永久卡死（需重启 LocalStack 清内存状态）；batch_writer 同键 delete+put 被拒（BatchWriteItem 重复键，真实 AWS 同规）；batch 删除要 Key={..}；管道 tail 吞退出码

---

## 🗂️ 第三阶段：测试与部署机制（项目 7-9）

> **目标**：把 CDK 代码当生产代码对待——测试它，并读懂它合成的每一段

### [x] 项目 7：fine-grained 断言测试

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（测试为主） |
| **核心知识点** | aws_cdk.assertions、Template.hasResourceProperties、Matchers、countResources |
| **前置** | 项目 2 |
| **技术栈** | aws-cdk-lib 内置 assertions 模块（纯合成期测试不触云 ✅，pytest 8.4.2 已装） |
| **验收标准** | 对项目 2 的构造库写齐断言测试套件，pytest 全绿；故意注入两处错误配置（去掉加密、改错 Lambda runtime）至少各 1 条测试抓红（退出码非零） |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「fine-grained 断言测试」（CDK 进阶清单项目 7）。请给我完整 pytest 测试代码约 200 行：用 aws_cdk.assertions 对构造库断言加密/事件源/环境变量/资源计数，并附两个故意注入错误配置的抓红用例与运行命令。只输出代码。`

**完成日期**：2026-10-27（cdk/07_cdk_assertions，12 绿 + 两种注入各抓红）
**踩坑记录**：默认值不进模板（BatchSize 省略）；find_outputs 必须给 logical_id；runtime 枚举名 NODEJS_20_X 无下划线；管道 tail 吞退出码

---

### [x] 项目 8：快照测试与 diff 守门

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | 模板快照、快照显式更新流程、cdk diff 脚本化、变更门禁 |
| **前置** | 项目 7 |
| **验收标准** | 无变更时快照测试通过且 `cdklocal diff` 输出为空；单行资源属性改动同时触发快照测试失败与 diff 非空（列出变更资源）；显式更新快照后恢复全绿 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「快照测试与 diff 守门」（CDK 进阶清单项目 8）。请给我完整代码约 150 行：模板快照测试 + cdklocal diff 守门脚本（变更非空即退出非零），附「改一行→双红→更新快照→恢复绿」的完整验证命令序列。只输出代码。`

**完成日期**：2026-10-27（cdk/08_cdk_snapshot_diff，7 断言全绿，双红→更新→归零闭环）
**踩坑记录**：本版 cdk diff 变更行走 stderr（2>/dev/null 会让门禁静默失效）；Metadata 版本戳会漂移；UPDATE_SNAPSHOT 更新后必须重跑才算绿；中断现场要归一（幂等 apply）

---

### [x] 项目 9：部署机制解剖——bootstrap、资产与合成产物

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（含解剖笔记） |
| **核心知识点** | cdklocal bootstrap、CDKToolkit 栈、资产 staging 桶、逻辑 ID 散列、手工变更集部署 synth 产物 |
| **前置** | 项目 1 |
| **⚠️ 风险** | bootstrap 在 LocalStack 免费版未实测（labs/28 未跑 bootstrap 也部署成功）→ 开工先最小探活；若 bootstrap 不可用，降级为「无 bootstrap 部署流程差异分析」，学习目标不变 |
| **验收标准** | 探活后能列出 CDKToolkit 栈与资产 staging 桶；对同一份 synth 模板用 labs/26 实测过的变更集流程手工部署成功且资源可用（证明 CDK 产出即普通 CFN 模板） |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「部署机制解剖——bootstrap、资产与合成产物」（CDK 进阶清单项目 9）。请给我完整脚本约 150 行：cdklocal bootstrap 探活（列 CDKToolkit 栈/资产桶）、观察 Lambda 资产如何进 staging 桶、再用 awslocal cloudformation 变更集手工部署 synth 产物验证资源可用，附逐步断言。只输出代码。`

**完成日期**：2026-10-27（cdk/09_cdk_deploy_anatomy，9 断言全绿，手工变更集部署 CDK 产物成功）
**踩坑记录**：资产键带 assets/ 前缀；AWS CLI v2 重复 --parameters 只留最后一个；S3VersionKey 分隔符是双竖线（格式错=S3 NoSuchKey，照抄 CDK 成功部署的栈参数最快）；手工栈 CDK 不认识须原生 CFN 删除；create-change-set 需显式 CREATE

---

## 🗂️ 第四阶段：交付与综合（项目 10-11）

> **目标**：一条命令从源码到可用系统

### [x] 项目 10：⛓️ 本地 CI 流水线（CDK Pipelines 降级版）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行（Makefile + 流水线脚本） |
| **核心知识点** | CDK Pipelines 阶段语义、流水线即代码、变更门禁、smoke test |
| **前置** | 项目 7、8 |
| **⚠️ 风险** | CodePipeline 是 LocalStack Pro 能力（免费版不可用）→ 用 make 流水线在本地实现同等阶段语义，学习目标不变 |
| **验收标准** | `make pipeline` 一条命令顺序跑完 synth→unit test→diff 审查→deploy→smoke→destroy 六阶段；注入未加密 bucket 构造后在 test 阶段被拦截（流水线退出码非零，不进入 deploy） |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「本地 CI 流水线——CDK Pipelines 降级版」（CDK 进阶清单项目 10）。请给我完整 Makefile 与脚本约 220 行：本地实现 synth→unit test→diff 审查→deploy→smoke→destroy 六阶段流水线，任一阶段失败即中止且退出码非零，附全绿与拦截两个场景的验证命令。只输出代码。`

**完成日期**：2026-10-28（cdk/10_cdk_local_pipeline，绿流水线 exit=0 + 注入拦在 test、deploy 未发生）
**踩坑记录**：CodeSuite（CodePipeline/CodeBuild）不在本机授权内（pro 版也排除）；$(shell) 解析期执行产物未在输出空串；make 无 -j 才保证串行语义；diff 首部署全量创建需分语义放行

---

### [x] 项目 11：🏁 综合实战——订单平台全栈工程化交付

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行 |
| **核心知识点** | 全能力整合：构造库 + Aspect 治理 + 双环境 + CR 种子 + 断言测试 + 流水线交付 |
| **前置** | 项目 2-10 |
| **技术栈** | API GW(HTTP)/Lambda/DDB/S3 均 labs/17、19 实测可用 ✅ |
| **验收标准** | `make deploy APP_ENV=prod` 一条命令部署成功且 pytest 全绿，smoke 断言 API 端到端可用；`make destroy` 清理干净，Retain 资源被显式清理脚本处理，awslocal 探查无残留 |

**🤖 开始提示词**：
> `我要开始 LocalStack 项目「综合实战——订单平台全栈工程化交付」（CDK 进阶清单项目 11）。请给我完整代码约 300 行：整合项目 2-10 全部能力（构造库/Aspect/双环境/CR 种子/测试/流水线）交付 API GW+Lambda+DDB+S3 前端的全栈应用，make deploy APP_ENV=prod 一键部署 + smoke 断言 + make destroy 清理，附端到端验收命令。只输出代码。`

**完成日期**：2026-10-28（cdk/11_cdk_order_platform，prod pipeline exit=0 + destroy 零残留五连查）
**踩坑记录**：apigatewayv2 服务不在授权内（CFN 资源能建但服务不可用）；v1/v2 L2 集成类全撞 jsii+typeguard 协议 bug → API GW 全 L1；L1 嵌套 dict 键 jsii camelCase；Fn::Sub 带映射与 Join+Ref(Region) 解析不可靠 → self.region 显式化；Output 级变更 diff 盲区 → 清栈重建；RETAIN 资产与重建撞名 → deploy 前置收尾；NO_PROXY 要罩 execute-api 子域

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-3（构造深化）✅ | 3 |
| **第 2 周** | 项目 4-6（Stack 工程）✅ | 3 |
| **第 3 周** | 项目 7-9（测试与部署机制）✅ | 3 |
| **第 4 周** | 项目 10-11（交付与综合）✅ | 2 |

## 🏆 里程碑

- [x] **完成项目 1-3** → 构造设计与复用能力（会写自己的「L2.5」）
- [x] **完成项目 4-6** → 栈组织与环境工程能力
- [x] **完成项目 7-9** → IaC 测试与部署机制理解能力
- [x] **完成项目 10-11** → 平台化交付能力（一条命令从代码到系统）
- [x] **全部完成** → 具备 CDK 生产级工程形态完整能力（本地模拟 → 真实 AWS 仅差 endpoint）

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| 2026-10-27 | 1 (cdk/01) | ~2.5h | L1/L2/L3 模板差异全对照；散列只看路径不看属性；escape hatch 三连（版本化/aws:kms/PAB） | override 用 SDK 属性名静默无效；PAB 部分字段被 CFN 引擎归一化；BucketDeployment 撞 typeguard 协议检查；L2 默认注入随版本变 |
| 2026-10-27 | 2 (cdk/02) | ~2h | 构造库四要素（校验/默认/命名/封装）落地；同一构造双栈零冲突；SQS→Lambda→DDB 双管道冒烟 | Function 无 removal_policy；事件源映射非即时；bash 多字节变量名坑 |
| 2026-10-27 | 3 (cdk/03) | ~2.5h | Aspect=合成期质检机器人；违规累积一次列全；L1 绕过无所遁形；修复路径 fix=1 验证 | Aspects.of/add Python 侧 jsii 序列化 bug（find_all+visit 替代）；ITaggable 需鸭子判定；deploy 重新合成须带 context |
| 2026-10-27 | 4 (cdk/04) | ~2h | 三通道产物差异全对照；bootstrap 解锁资产；SSM 通道=部署期落值/运行时取值 | SSM CFN provider 双写自撞；get-parameter 斜杠路径回归；嵌套队列基准别拿错 |
| 2026-10-27 | 5 (cdk/05) | ~2h | context 改形状 vs --parameters 填数值分野；Retain 资产存活与人工收尾闭环 | 空集 "None" 被当对象键；版本化桶清到删除标记；CfnOutput/CfnParameter 撞 ID |
| 2026-10-27 | 6 (cdk/06) | ~2h | CR 三幕全链路（播种/刷新/清场）；物理 ID 稳定=Update；Data 输出可 GetAtt | CR 崩溃即栈卡死（重启清状态）；batch 同键 delete+put 被拒；管道 tail 吞退出码 |
| 2026-10-27 | 7 (cdk/07) | ~1.5h | 断言=合成期单元测试（1.4s vs 部署分钟级）；反面断言抓回归式修复；注入证明红得其所 | 默认值不进模板；NODEJS_20_X 拼写；find_outputs 签名 |
| 2026-10-27 | 8 (cdk/08) | ~1.5h | 快照=全量对账，diff=部署对账；双红→显式更新→归零闭环；git diff 快照即变更说明 | diff 变更行在 stderr（门禁静默失效最危险）；Metadata 漂移需归一 |
| 2026-10-27 | 9 (cdk/09) | ~2h | 部署链路四段拆解；资产三参数=CLI 与 CFN 的接口契约；手工变更集证明 CDK 产物即普通 CFN 模板 | 重复 --parameters 末位生效；VersionKey 双竖线（照抄成功栈参数排错最快） |
| 2026-10-28 | 10 (cdk/10) | ~1.5h | Pipelines=阶段语义而非服务；test 门拦注入（deploy 未发生）；diff 首部署语义分叉 | CodeSuite 不在授权；$(shell) 解析期执行；make -j 破坏串行 |
| 2026-10-28 | 11 (cdk/11) | ~2.5h | 十能力合流交付；prod RETAIN+版本化+PROVISIONED 全分支；RETAIN 收尾进 deploy 前置 | apigwv2 服务不在授权；L2 集成全撞协议 bug → 全 L1；Join+Ref(Region) 解析错乱；Output diff 盲区 |

## 🔧 环境配置

```bash
# 0. 已就绪（2026-10-26 本机实测）
#    node v22.23.2 / npm 10.9.8 / cdk CLI 2.1139.0 / cdklocal 3.0.4
#    Docker 29.8.2 / LocalStack CLI / Python 3.13.9
#    pip: aws-cdk-lib 2.268.0 / constructs 10.8.1 / pytest 8.4.2
#    （断言测试用 aws_cdk.assertions 是 aws-cdk-lib 内置模块，无需另装）

# 1. 每项目开工前
export LOCALSTACK_AUTH_TOKEN="你的token"   # 2026-03 起免费版需 token（见 docs/aws.md）
localstack start -d
curl -s http://localhost:4566/_localstack/health | head -c 200   # 探活

# 2. 动手实验目录约定
#    系列目录 cdk/（01-11 对应项目 1-11）；labs/28 为入门线，本清单全部为进阶
```

## ⚠️ 与已有清单的关系

| 已有清单/实验 | 关系 |
|:---|:---|
| docs/aws.md 项目 28（labs/28_cdk_stack） | **入门线**：三层概念、synth/diff/deploy/destroy、四资源一键栈、Context 参数化已覆盖 → 本清单默认你已完成它，全部项目为进阶，不再重复教基本流程 |
| docs/aws.md 项目 30（labs/30） | 曾用 CDK 一键部署综合平台 → 本清单项目 11 是其**工程化重构版**（构造库/测试/治理/流水线），验收维度完全不同 |
| labs/26_cloudformation_advanced | **手写模板线**：变更集/嵌套栈/自定义资源已实测 → 本清单项目 4、6 在 CDK 形态下复用这些已验证机制，项目 9 把两者对照 |
| labs/09、27（CFN/Terraform） | 声明式 IaC 对照组 → 本清单不覆盖 Terraform，CDK vs Terraform vs CFN 对比已在 labs/28 README，不重复 |

## ⚠️ LocalStack 免费版能力覆盖速查

| 能力 | 计划 | 实测结论 |
|:---|:---|:---|
| CDK synth/diff/deploy/destroy | 全部项目 | ✅ labs/28 全断言跑通（cdk 2.1139.0 + cdklocal 3.0.4） |
| S3/DynamoDB/SQS/Lambda/API GW(HTTP)/SNS/CFN/IAM/SSM | 项目载体 | ✅ labs/01-30 实测可用（免费版） |
| aws_cdk.assertions 断言测试 | 项目 7、8 | ✅ 纯合成期测试不触云，pytest 8.4.2 已装 |
| SSM get-parameter 含 / 路径名 | 项目 4 | ❌ 本版 LocalStack 回归（put 正常 get 异常）→ 参数名无斜杠；真实 AWS 无此限制 |
| 嵌套栈（AWS::CloudFormation::Stack） | 项目 4 | ✅ CFN 层面 labs/26 实测；CDK 侧同底层机制 |
| cloudtrail.Trail（L3 形态示例） | 项目 1 | ✅ cdk/01 实测 synth 4 资源（BucketDeployment 因 jsii+typeguard 协议检查 bug 改用） |
| Lambda-backed Custom Resource | 项目 6 | ✅ CFN 层面 labs/26 实测；CDK L2 侧开工首验 |
| AwsCustomResource（SDK 调用型） | 项目 6 选做 | ⚠️ 未启用：Provider 框架 Lambda 为大段内联代码，手写 CR 已覆盖验收（cdk/06），不再增风险面 |
| Aspects.of().add()（Python 实现 aspect） | 项目 3 | ❌ 本环境（Py3.13+jsii 1.14x）触发内核序列化 bug，@jsii.implements 亦无效 → cdk/03 用等价 find_all+visit |
| DeletionPolicy: Retain 删除语义 | 项目 5、11 | ⚠️ 待开工探活；不可用则降级为 synth 模板级断言 |
| cdklocal bootstrap | 项目 9 | ✅ cdk/04 实测一次通过（CDKToolkit 栈+资产桶）；NestedStack 资产依赖它 |
| CodePipeline / CodeBuild | 项目 10 | ❌ 探活实锤：CodeSuite 不在 pro 授权内 → cdk/10 make 降级流水线（阶段语义等价） |
| apigatewayv2 服务（含 execute-api 运行时） | 项目 11 | ❌ 探活实锤：不在授权内（CFN 资源能建但服务不可用）→ REST API v1（labs/17 验证） |
| DeletionPolicy: Retain 删除语义 | 项目 5、11 | ✅ cdk/05 实测：L2/L1 两种写法 destroy 后均真实保留（PAB 归一化坑不影响 Retain） |
| 真实 AWS 部署 | 不涉及 | 仓库铁律：不触碰真实账户 |

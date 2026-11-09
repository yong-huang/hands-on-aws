# 11 · 🏁 综合实战：订单平台全栈工程化交付

> 整合 cdk/01-10 全部能力的一锤定音：构造库组装 + Aspect 治理 + 双环境 +
> CR 种子 + 断言测试 + 流水线交付。`make pipeline APP_ENV=prod` 一条命令
> 从代码到在线平台（POST 201 → 队列消费 → GET PROCESSED），
> `make destroy APP_ENV=prod` 清栈 + RETAIN 资产显式收尾 + 零残留。

## Background

cdk/01-10 各练一块能力。真实交付要求它们**同时工作**：平台代码要有构造
库式的内聚组装，要有组织级标签与合规拦截，dev/prod 要结构性分支，数据
要有种子与生命周期策略，测试要进流水线门，验收要端到端可断言。这个实验
就是把这些块拼成一个可交付的整体——拼的过程会暴露所有"单块实验里看不出"
的集成问题（本实验的踩坑实录有 8 条，全是集成期现形的）。

## What

一句话定义：`OrderPlatformStack` 交付 HTTP API（POST /orders 入队 /
GET /orders/{id} 查询）→ 订单队列(+DLQ) → 处理器 Lambda → 明细表（CR
播种 3 条菜单数据）+ 归档桶。dev/prod 结构性分支（计费/版本化/RETAIN/
可见性超时），全资源强制标签，合成期合规检查。

心智模型：前十个实验是"练级"，这个是"打 Boss"——Boss 的攻击方式不是
新知识，而是你已学知识的组合与边角（L1/L2 边界、token 解析、RETAIN 与
重建的交互、服务授权边界）。

## When to Use

典型场景：

- 团队第一个 CDK 平台项目的骨架参考：本仓库的 app.py 可直接改造。
- 评估 CDK 迁移可行性：本实验的踩坑清单就是"本机模拟环境 + 真实 AWS
  差异"的实测清单。
- 教学收尾：让学生在一个真实拓扑上同时看到 IaC 的十个维度。

何时不用：生产直接照搬（真实 AWS 上 API GW 应该用 L2 而非本实验的
L1 兜底、域名的 localhost 段要去掉、CodePipeline 换真服务）。

## Quick Start

前置：LocalStack 运行中；cdk/01-09 的依赖（cdklocal + bootstrap）。

```bash
cd cdk/11_cdk_order_platform
make pipeline APP_ENV=dev     # 全绿：部署 + 端到端冒烟（在线）
make destroy APP_ENV=dev      # 收尾归零
make pipeline APP_ENV=prod    # prod：RETAIN + 版本化 + PROVISIONED
make destroy APP_ENV=prod     # RETAIN 资产显式收尾 + 零残留
```

验收：pipeline exit=0（test 21 条双环境断言 + deploy + smoke 三连断言）；
destroy 零残留五连查（栈/表/桶/Lambda/资产）。

## How It Works

`cdk_app/app.py`（~270 行）的平台拓扑：

```
HTTP API（L1 REST API v1，POST/GET 两条路由）
  └─ order-api Lambda（校验 ORD- 前缀 → SQS；GET 查表）
       └─ 订单队列(+DLQ, maxReceiveCount=3)
            └─ processor Lambda（事件源映射 → 落表 PROCESSED）
明细表 ho11-<env>-orders（CR 播种 seed-*；prod PROVISIONED+RETAIN）
归档桶 ho11-<env>-archive（prod 版本化+RETAIN）
Aspect：全资源打标 platform=ho11/env=<env>；合成期加密合规检查
```

十个实验的能力落点：构造库思维（单栈内聚组装，输出契约清晰）· Aspect
（find_all visit 等价形式，cdk/03 实测机制）· 双环境（`-c env`，cdk/05
分支模式）· CR（物理 ID 恒定 `ho11-seeds-v1`，cdk/06 协议）· 断言
（dev 10 + prod 11 条，cdk/07 机制）· 流水线（make 阶段语义，cdk/10）·
L1 兜底（cdk/01/39 的 escape hatch 思想在 API GW 上的应用）。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测，8 条全是集成期现形）：

- **apigatewayv2 服务不在 LocalStack 授权内**：CFN 资源能建
  （CREATE_COMPLETE）但服务 API（get-apis）直接 InternalFailure——
  "资源存在"与"服务可用"是两回事。解法：切 REST API v1（labs/17 验证过）。
- **v1/v2 的 L2 集成类全部撞 jsii+typeguard 协议 bug**：
  `HttpLambdaIntegration`/`LambdaIntegration` 的 IFunction 参数触发
  `grant_invoke` 签名对比失败（cdk/03 序列化 bug 的姊妹篇）。解法：
  API GW 全 L1 裸资源（CfnRestApi/Resource/Method/Deployment/Stage）。
- **`HttpRouteKey.with_` 参数顺序**：`(path, method)`——path 在前。
- **L1 嵌套 dict 是 jsii camelCase**：`integration_http_method`（snake）
  被静默丢弃、`IntegrationHttpMethod`（Pascal）反序列化报错——只有
  `integrationHttpMethod`（camel）正确。键名三种大小写试出正确一种，
  是 L1 开发的日常。
- **Fn::Sub 带变量映射不可靠 / Fn::Join+Ref(Region) 解析错乱**：
  Output 值出现 "unknown" 或 region 丢失、":4566" 串位。解法：能显式
  就显式——`self.region`（env 已具体化，无 token）；smoke 不信任
  Output，自行从 `get-rest-apis` 按名字取 api id 构造端点。
- **本版 LocalStack 对 Output 级变更的 diff 有盲区**：改 Output 表达式
  后 deploy 报 "no changes"，线上仍是旧值。解法：deploy 前清栈重建
  （付出的代价是部署时间，换来的确定性）。
- **prod RETAIN 资产与重建撞名**：预清栈后 RETAIN 表保留 → 重建时
  `Table already exists` → 整栈回滚。解法：deploy 前置
  `purge_retained.sh`——"重建环境前先显式收尾上次的保留资产"是 prod
  工作流的正字。
- **make 配方里 `(... && exit 1)` 退不出**：小括号是子 shell。解法：
  `{ ...; exit 1; }`。
- **NO_PROXY 要罩 `*.localhost.localstack.cloud`**：curl 到 execute-api
  子域的请求会被本机代理劫持（000 或代理自己的 404）。

深入问答：

- **Q: 真实 AWS 上要改哪里？** A: ① API GW 换 L2（jsii 协议 bug 是本机
  typeguard 版本问题）；② endpoint 去掉 `.localhost` 段；③ CR 的
  LOCALSTACK_HOSTNAME 端点改真实 VPC 配置；④ PROVISIONED 容量换
  auto-scaling；⑤ 流水线换 CodePipeline/GitHub Actions（本机授权不含
  CodeSuite）。
- **Q: CR 播种的 seed-* 与业务订单共存一张表安全吗？** A: 靠前缀约定
  （seed- vs ORD-）+ CR 只清理自己前缀——单表设计里"配置与数据同表"
  是常见做法，但前缀即契约，没有约束力的团队要改成分表。
- **Q: 为什么 GET 查表而不查队列？** A: 查询走读模型（表），写入走
  队列异步处理——读写分离是这条链路的教学点；GET 到 404 说明"已受理
  未处理完"，正好演示异步语义。
- **Q: 平台在线时 LocalStack 重启会怎样？** A: 无状态卷容器重启即全丢
  （cdk/06 已实测）——本地平台的"在线"只在容器生命周期内，交付物是
  代码与流水线，不是常驻环境。

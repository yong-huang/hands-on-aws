# 29 · AWS SAM 无服务器应用：模板化事件源一键上线

> AWS SAM（Serverless Application Model）是 CFN（AWS CloudFormation，AWS 托管的 IaC 服务）的无服务器专用方言：SimpleTable
> 一行建表、Api 事件一行挂网关、Schedule 一行定定时。本实验用 samlocal 完成
> validate → build → deploy → invoke → delete 全生命周期，上线一个任务清单
> 应用，共 7 项真实断言。

## Background

在 SAM 出现之前，无服务器应用用原生 CFN 搭建：一个 Lambda 要写 IAM Role、
LogGroup、ApiGateway Resource/Method/Deployment/Permission 五六个资源块，样板
代码远超业务逻辑。

样板膨胀撞上两堵墙。第一，声明冗长：一行业务（"这个函数挂个 API"）对应五六十
行 CFN。第二，本地调试缺失：改一行代码要上传部署才能验证。

SAM（2016 年推出的
CFN Transform）把无服务器样板件收敛成三种高级资源（Function/SimpleTable/
Api），配合 samlocal CLI 实现"validate → build → invoke → deploy"的开发
循环。

## What

一句话定义：SAM 是一种 CFN 变换方言——`Transform: AWS::Serverless-2016-10-31`
展开后仍是普通 CFN； samlocal CLI 提供 build（打包代码）、deploy（上传并落地
CFN）、invoke（直接调用单函数）的全生命周期命令。

心智模型：可以把 SAM 模板想象成"无服务器应用的全家桶图纸"——一份
template.yaml 同时画出函数、表、API 与定时器。但和真实图纸不同的是：同一份
图纸还能"局部试用"——deploy 之前先用 invoke 直接调用某个函数验证逻辑，不必
先建全整套 API。

三种事件源（本实验配置）：

- **Api**：自动创建 API Gateway、Stage、Lambda 权限——一行完成 lab 05 的
  手工五步。
- **Schedule**：rate/cron 定时触发（实测随栈注册 TaskFnDailyTick）。
- **SimpleTable**：一行声明带主键的 DynamoDB 表。

## When to Use

典型场景：

- 函数为主的应用：几个 Lambda + 一张表 + 一个 API，SAM 模板最省字。
- 开发期高频调试：改代码 → samlocal invoke → 看结果，秒级循环。
- 定时任务 + API 混合：同一份模板声明两种事件源（本实验实测两者随栈注册）。

何时不用：资源组合复杂且非函数为主（用 CDK/CFN）；需要严格 API Key/Usage
Plan 门面（SAM 的 Api 事件偏简单，复杂配置回退手写 CFN 资源）。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| SAM | 无服务器方言 + 全生命周期 CLI | 函数为主的应用（本实验） |
| CDK | 编程语言构造树（lab 28） | 资源组合复杂、需抽象复用 |
| 原生 CFN | 完整控制力 | 非 SAM 覆盖的资源组合（lab 26） |
| Serverless Framework | 多云、插件生态 | 多云无服务器应用 |

## Quick Start

前置条件：LocalStack（本机模拟 AWS API 的工具）运行中；`pip3 install aws-sam-cli aws-sam-cli-local`
（提供 sam 与 samlocal）。运行方式：

```bash
cd labs/29_sam_serverless
./sam_serverless.sh            # validate/build → deploy → invoke+API 闭环 → 清理
```

脚本的真实输出（节选）：

```text
=====> [apply] samlocal validate + build
  ✅ 模板合法（SimpleTable + Function + Api/Schedule 事件源）
  ✅ build 产出 .aws-sam 构建物
=====> [observe] 部署后的 API 实际可调通：POST + GET
  ✅ POST 经 API 写入
  ✅ GET 回显任务
=====> [clean] sam delete 清栈
  ✅ 已删净，环境复原
```

SAM 模板的核心（`template.yaml`）——三种资源加两种事件源：

```yaml
Resources:
  Table:
    Type: AWS::Serverless::SimpleTable       # 一行建表（id 主键）
  TaskFn:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/                    # build 打包此目录
      Handler: task.handler
      Events:
        Api:        { Type: Api, Properties: { Path: /tasks, Method: any } }
        DailyTick:  { Type: Schedule, Properties: { Schedule: rate(1 day) } }
```

新手第一个失败点：samlocal 报 `AWS Region was not found`——SAM CLI 不接受
顶层 `--region`，需要 `AWS_DEFAULT_REGION` 环境变量（脚本的 samlocal 包装
函数已处理）。

## How It Works

![SAM 无服务器应用](images/sam_serverless.svg)

> 怎么看：template.yaml 声明 SimpleTable + Function（挂 Api / Schedule 两种
> 事件源）；build 打包 CodeUri；deploy 经 S3 上传模板与代码，由 CFN 落地全套
> 资源；invoke 直接调用单函数做本地调试。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/29_sam_serverless/images/sam_serverless.html)
> （或本地打开 [`images/sam_serverless.html`](images/sam_serverless.html)）。

**build 与 deploy 的分工**：build 把 CodeUri 打包进 `.aws-sam`（含依赖安
装）；

deploy 把构建物与转换后的模板上传对象存储 S3、交给 CFN 落地——实测栈
CREATE_COMPLETE，资源表列出全部 9 个资源（Table/TaskFn/RestApi/ProdStage/
DailyTick 等）。

**invoke 如何本地调试**：`samlocal invoke ho29-task-fn --event <json>` 直接
调用部署后的函数，不经 API Gateway——本机实测该命令偶发无输出（如实记录），
改用 API 路线（POST/GET 断言）作为主要验证通道。

**API 端点如何推导**：本构建不回填 SAM 的隐式 Outputs。解法：从
`list-stack-resources` 取 ServerlessRestApi 的物理 ID，拼
`<api-id>.execute-api...:4566/Prod/tasks`——实测 POST 201、GET 回显。

## Pitfalls & Q&A

踩坑清单（现象 → 原因 → 解法，均为本机实测）：

- **samlocal 不认 `--region` 顶参**：用 `AWS_DEFAULT_REGION` 环境变量。
- **删除命令是 `sam delete`**：没有 `delete-stack` 子命令；删栈是异步的，
  要用 `wait stack-delete-complete` 等待。
- **隐式 Outputs 不回填**：API 端点从资源表推导（脚本已做）。
- **re-deploy 状态是 UPDATE_COMPLETE**：幂等部署的断言要同时接受 CREATE 与
  UPDATE。

深入问答：

- **Q: SAM 与 CFN 的关系？** A: SAM 是 CFN 的无服务器方言（Transform 展开为
  普通资源），SAM 模板可以混写 CFN 资源；展开后与手写 CFN 无差别。
- **Q: sam build 做了什么？** A: 打包 CodeUri、安装依赖（requirements.txt）、
  产出 .aws-sam/build；deploy 上传构建物到 S3。
- **Q: 本地调试的两种姿势？** A: sam local invoke/start-api 用 Docker 模拟
  运行时（本实验走 LocalStack 真函数）；两者都应接入自动化断言。
- **Q: Globals 节的作用？** A: 给所有函数统一默认（Runtime/Memory/Env）——
  组织级基线。

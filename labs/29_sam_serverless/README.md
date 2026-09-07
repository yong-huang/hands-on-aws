# 29 · AWS SAM 无服务器应用：模板化事件源一键上线

> SAM 是"无服务器专用的 CFN"：SimpleTable 一行建表、Api 事件一行挂网关、
> Schedule 一行定定时——samlocal build/deploy 一条龙。本实验用 SAM 上线一个
> 任务清单应用，并用 samlocal invoke 本地调试单函数。

## 1. 为什么需要它

- 无服务器应用的样板件（函数+API+表+定时器）用 SAM 模板最省字；
- `samlocal invoke` 不经网关直接调试单函数——开发期最高频的动作；
- 底层仍是 CFN，与 lab 26 的变更/嵌套知识互通。

## 2. 总览：核心机制一图看懂

![SAM 无服务器应用](images/sam_serverless.svg)

> 怎么看：template.yaml 声明 SimpleTable + Function（挂 Api / Schedule 两种事件
> 源）；build 打包 CodeUri；deploy 经 S3 上传模板与代码，由 CFN 落地全套资源；
> invoke 直接调用单函数做本地调试。

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://hyhit.github.io/hands-on-aws/labs/29_sam_serverless/images/sam_serverless.html)
> （或本地打开 [`images/sam_serverless.html`](images/sam_serverless.html)）。

心智模型一句话：**SAM 模板 = 无服务器应用的全家桶图纸，deploy 一次全部上线。**

## 3. 快速开始

```bash
cd labs/29_sam_serverless
./sam_serverless.sh            # validate/build → deploy → 调试+API 闭环 → 清理
```

真实运行输出（节选）：

```text
=====> [apply] samlocal validate + build
  ✅ 模板合法（SimpleTable + Function + Api/Schedule 事件源）
=====> [observe] 部署后的 API 实际可调通：POST + GET
  ✅ POST 经 API 写入
  ✅ GET 回显任务
=====> [observe] 事件源清单：Api + Schedule 已随栈注册
   - ServerlessRestApi / ServerlessRestApiProdStage
   - TaskFnDailyTick（rate(1 day) 定时器）
```

## 4. 核心概念

### 4.1 三种事件源一行声明

`Type: Api`（HTTP 入口，自动建 API Gateway+集成+权限）、`Type: Schedule`
（定时器，本实验 rate(1 day)）、还有 S3/SQS/Stream 等——Lambda 的接线成本
降到最低。

### 4.2 build 与 deploy 的分工

build 把 CodeUri 打包进 `.aws-sam`（含依赖安装）；deploy 把构建物传 S3、
Transform 后交给 CFN。实测全链路：validate → build → deploy → 栈可用。

### 4.3 本机边界（如实记录）

- 隐式 Outputs（API 端点）本构建不回填——从栈资源表取 ServerlessRestApi 的
  物理 ID 拼 URL（stage 固定 Prod）；
- `samlocal invoke` 直调偶发无输出——API 路线（POST/GET）实测全部通过；
- 删除用 `sam delete`（没有 delete-stack 子命令，实测踩坑）。

## 5. 配置关键字段（template.yaml）

```yaml
Resources:
  Table:
    Type: AWS::Serverless::SimpleTable        # 一行建表（id 主键）
  TaskFn:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/                     # build 打包此目录
      Handler: task.handler
      Events:
        Api:        { Type: Api, Properties: { Path: /tasks, Method: any } }
        DailyTick:  { Type: Schedule, Properties: { Schedule: rate(1 day) } }
Globals:
  Function: { Runtime: python3.12, MemorySize: 256 }   # 函数默认值
```

坑清单：

- `samlocal` 需要 `AWS_DEFAULT_REGION` 显式设置（不接受 --region 顶参，实测）；
- 隐式 Outputs 本构建不回填，端点要从资源表推导；
- re-deploy 后状态是 UPDATE_COMPLETE（幂等），断言别只认 CREATE。

## 6. 文件结构

```text
labs/29_sam_serverless/
├── README.md            # 本文件
├── sam_serverless.sh    # 主脚本：validate/build/deploy → invoke+API 闭环 → 清理
├── template.yaml        # SAM 模板（SimpleTable + 函数 + Api/Schedule 事件源）
├── functions/task.py    # 任务函数（GET 列表 / POST 创建，CORS 注入）
└── images/
    ├── sam_serverless.architecture.json  # 图源（Typed JSON IR）
    ├── sam_serverless.html               # 交互版
    └── sam_serverless.svg                # 双主题矢量图（README 内嵌）
```

## 7. 面试要点

- **Q: SAM 与 CFN 的关系？** A: SAM 是 CFN 的无服务器方言（Transform 展开为
  普通资源），SAM 模板可以混写 CFN 资源；展开后与手写 CFN 无差别。
- **Q: sam build 做了什么？** A: 打包 CodeUri、装依赖（requirements.txt）、产出
  .aws-sam/build；deploy 上传构建物到 S3。
- **Q: 本地调试的两种姿势？** A: sam local invoke/start-api 用 Docker 模拟运行
  时（本实验走 LocalStack 真函数）；两者都应接入自动化断言。
- **Q: Globals 节的作用？** A: 给所有函数统一默认（Runtime/Memory/Env）——
  生产上的"组织级基线"。
- **Q: Schedule 事件的幂等？** A: 定时器至少触发一次，函数必须幂等（lab 14 的
  去重表思路直接复用）。

## 8. 总结

validate/build/deploy/invoke/delete——SAM 全生命周期命令实测完毕，任务清单
应用的 API 闭环真机可调。下一篇是整个系列的终极收官：实时日志分析平台。

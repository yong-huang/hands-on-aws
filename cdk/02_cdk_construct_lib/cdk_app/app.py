"""ho02 CDK 应用：两个 Stack 各实例化一份构造库，验证复用与命名隔离。

用法：
  cdklocal synth                # 正常合成 alpha/beta 两栈
  cdklocal synth -c invalid=1   # 故意传非法入参 → 合成期报错，退出码非零
"""
import sys

import aws_cdk as cdk

from order_pipeline import AlphaStack, BetaStack, OrderPipelineConstruct, OrderPipelineProps

REGION = "us-east-1"
ACCOUNT = "000000000000"

app = cdk.App()

invalid = app.node.try_get_context("invalid")
if invalid:
    # 合成期校验演示：传一个带下划线的非法名
    class InvalidStack(cdk.Stack):
        def __init__(self, scope, cid, **kw):
            super().__init__(scope, cid, **kw)
            OrderPipelineConstruct(self, "P", OrderPipelineProps(pipeline_name="Bad_Name"))

    InvalidStack(app, "ho02-invalid-stack",
                 env=cdk.Environment(account=ACCOUNT, region=REGION))
else:
    AlphaStack(app, "ho02-alpha-stack", env=cdk.Environment(account=ACCOUNT, region=REGION))
    BetaStack(app, "ho02-beta-stack", env=cdk.Environment(account=ACCOUNT, region=REGION))

app.synth()

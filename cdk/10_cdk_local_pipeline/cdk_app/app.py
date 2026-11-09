"""ho10 CDK 应用：流水线交付的"产品"——cdk/02 构造库的 alpha 管道。

HO40_INJECT 环境变量注入错误配置（验收用）：
  unset   → 正常产品
  no_encryption → 桶不带加密（test 阶段应拦截，deploy 不应发生）
"""
import os

import aws_cdk as cdk
from aws_cdk import Environment

from lib.order_pipeline import AlphaStack, OrderPipelineConstruct, OrderPipelineProps

REGION = "us-east-1"
ACCOUNT = "000000000000"

app = cdk.App()
inject = os.environ.get("HO40_INJECT") or None
inject = inject if inject in (None, "no_encryption", "bad_runtime") else None


class Ho40Stack(cdk.Stack):
    def __init__(self, scope: cdk.App, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        self.pipeline = OrderPipelineConstruct(
            self, "Pipeline",
            OrderPipelineProps(pipeline_name="alpha", inject=inject))
        cdk.CfnOutput(self, "QueueName", value=self.pipeline.queue.queue_name)


Ho40Stack(app, "ho10-stack", env=Environment(account=ACCOUNT, region=REGION))
app.synth()

"""ho08 CDK 应用：快照测试与 diff 守门的靶栈。

VISIBILITY_SECONDS 是可被脚本单行改动的资源属性（验收用：改一行 →
快照测试红 + diff 非空；显式更新快照 → 恢复绿；部署后 diff 归零）。
"""
import aws_cdk as cdk
from aws_cdk import (
    Duration,
    Environment,
    RemovalPolicy,
    Stack,
    aws_dynamodb as ddb,
    aws_sqs as sqs,
)
from constructs import Construct

REGION = "us-east-1"
ACCOUNT = "000000000000"

VISIBILITY_SECONDS = 30    # ← 快照/diff 验收的单行改动点（30 ↔ 60）


class Ho38Stack(Stack):
    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        self.queue = sqs.Queue(
            self, "Jobs", queue_name="ho08-jobs",
            visibility_timeout=Duration.seconds(VISIBILITY_SECONDS),
            removal_policy=RemovalPolicy.DESTROY)
        self.table = ddb.Table(
            self, "Items", table_name="ho08-items",
            partition_key=ddb.Attribute(name="sk", type=ddb.AttributeType.STRING),
            removal_policy=RemovalPolicy.DESTROY)
        cdk.CfnOutput(self, "Visibility", value=str(VISIBILITY_SECONDS))


app = cdk.App()
Ho38Stack(app, "ho08-stack",
          env=Environment(account=ACCOUNT, region=REGION))
app.synth()

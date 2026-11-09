"""ho09 CDK 应用：一个带"真资产"的栈 + 供手工变更集部署的同一份合成模板。

Code.from_asset 的小 zip（cdk/01 曾因无 bootstrap 禁用资产，bootstrap 后解锁）——
deploy 时 CLI 把资产上传 staging 桶（对象名 = 资产内容散列），CFN 从桶拉取。
"""
import aws_cdk as cdk
from aws_cdk import (
    Environment,
    RemovalPolicy,
    Stack,
    aws_lambda as _lambda,
    aws_s3 as s3,
)
from constructs import Construct

REGION = "us-east-1"
ACCOUNT = "000000000000"


class Ho39Stack(Stack):
    """variant=cdk | manual：同一份代码两种部署通道，资源名互不冲突。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        variant = self.node.try_get_context("variant") or "cdk"
        bucket = s3.Bucket(
            self, "Bucket", bucket_name=f"ho09-anatomy-{variant}",
            encryption=s3.BucketEncryption.S3_MANAGED,
            removal_policy=RemovalPolicy.DESTROY)
        fn = _lambda.Function(
            self, "AssetFn", function_name=f"ho09-asset-fn-{variant}",
            runtime=_lambda.Runtime.PYTHON_3_12,
            handler="handler.handler",
            code=_lambda.Code.from_asset("asset_src"),   # 真资产：zip 进 staging 桶
            memory_size=256)
        cdk.CfnOutput(self, "BucketName", value=bucket.bucket_name)


app = cdk.App()
Ho39Stack(app, "ho09-stack",
          env=Environment(account=ACCOUNT, region=REGION))
app.synth()

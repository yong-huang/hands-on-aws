"""ho28 CDK 应用：S3 + SQS + Lambda + DynamoDB 一键栈（Python）。"""
import os

import aws_cdk as cdk
from aws_cdk import (
    aws_s3 as s3,
    aws_sqs as sqs,
    aws_lambda as _lambda,
    aws_dynamodb as ddb,
    Stack,
)
from constructs import Construct


class Ho28Stack(Stack):
    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)

        bucket = s3.Bucket(self, "Data", bucket_name="ho28-cdk-data",
                           removal_policy=cdk.RemovalPolicy.DESTROY)
        queue = sqs.Queue(self, "Jobs", queue_name="ho28-cdk-jobs",
                          removal_policy=cdk.RemovalPolicy.DESTROY)
        table = ddb.Table(self, "Items", table_name="ho28-cdk-items",
                          partition_key=ddb.Attribute(name="id", type=ddb.AttributeType.STRING),
                          removal_policy=cdk.RemovalPolicy.DESTROY)
        fn = _lambda.Function(self, "Fn", function_name="ho28-cdk-fn",
                              runtime=_lambda.Runtime.PYTHON_3_12,
                              handler="index.handler",
                              code=_lambda.InlineCode(
                                  "import json\n"
                                  "def handler(event, context):\n"
                                  "    return {'ok': True}\n"),
                              memory_size=256)
        env_name = self.node.try_get_context("env_name") or "dev"
        cdk.CfnOutput(self, "EnvName", value=env_name)
        cdk.CfnOutput(self, "Bucket", value=bucket.bucket_name)
        cdk.CfnOutput(self, "Table", value=table.table_name)


app = cdk.App()
Ho28Stack(app, "ho28-stack",
          env=cdk.Environment(account="000000000000", region="us-east-1"))
app.synth()

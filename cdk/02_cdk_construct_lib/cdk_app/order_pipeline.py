"""ho02 可复用构造库：OrderPipelineConstruct——S3 + SQS(+DLQ) + Lambda + DynamoDB。

设计要点（对应"构造库设计"知识点）：
- Props 集中校验：非法入参在 synth 期就抛出带原因的错误，而不是等部署炸
- 默认值可覆盖：加密、DLQ、可见性超时全部有合理默认，又允许调用方定制
- 命名空间隔离：所有物理名带 pipeline_name 前缀，同一 App 多实例不冲突
- 内部挂接不外泄：队列→Lambda→表的事件源映射封装在构造内部
- 属性只读暴露：调用方拿 bucket/queue/table/function 引用，不碰内部细节
"""
import re
from dataclasses import dataclass, field
from typing import Optional

import aws_cdk as cdk
from aws_cdk import (
    Duration,
    RemovalPolicy,
    Stack,
    aws_dynamodb as ddb,
    aws_lambda as _lambda,
    aws_s3 as s3,
    aws_sqs as sqs,
)
from aws_cdk.aws_lambda_event_sources import SqsEventSource
from constructs import Construct

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{2,19}$")

LAMBDA_CODE = """import json, os, uuid
import boto3

ddb = boto3.resource(
    "dynamodb",
    endpoint_url=f"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566",
    region_name=os.environ["AWS_REGION"],
)
table = ddb.Table(os.environ["TABLE_NAME"])


def handler(event, context):
    n = 0
    for rec in event.get("Records", []):
        body = json.loads(rec["body"])
        table.put_item(Item={
            "order_id": body["order_id"],
            "amount": str(body.get("amount", 0)),
            "request_id": context.aws_request_id,
        })
        n += 1
    return {"ok": True, "processed": n}
"""


@dataclass
class OrderPipelineProps:
    """构造入参：必填项少、默认值合理、越界在合成期报错。"""

    pipeline_name: str                      # 必填：命名空间前缀，如 alpha/beta
    table_name: Optional[str] = None        # 缺省 → ho02-<name>-orders
    visibility_timeout: Duration = field(default_factory=lambda: Duration.seconds(30))
    max_receive_count: int = 3              # DLQ 阈值
    removal_policy: RemovalPolicy = RemovalPolicy.DESTROY

    def validate(self) -> None:
        if not NAME_RE.fullmatch(self.pipeline_name):
            raise ValueError(
                f"pipeline_name={self.pipeline_name!r} 不合法：需匹配 {NAME_RE.pattern}"
                "（小写字母开头，3-20 位小写字母/数字/连字符）——物理名将以其为前缀"
            )
        if self.max_receive_count < 1 or self.max_receive_count > 50:
            raise ValueError(f"max_receive_count={self.max_receive_count} 需在 1-50")


class OrderPipelineConstruct(Construct):
    """一条订单处理管道：订单桶 + 队列(+DLQ) → 落表 Lambda → DynamoDB 明细表。"""

    def __init__(self, scope: Construct, cid: str, props: OrderPipelineProps) -> None:
        super().__init__(scope, cid)
        props.validate()
        name = props.pipeline_name

        # ---- 资源：物理名全部带前缀，多实例互不冲突
        self.bucket = s3.Bucket(
            self, "OrdersBucket",
            bucket_name=f"ho02-{name}-orders",
            encryption=s3.BucketEncryption.S3_MANAGED,
            removal_policy=props.removal_policy,
        )
        self.table = ddb.Table(
            self, "OrdersTable",
            table_name=props.table_name or f"ho02-{name}-orders",
            partition_key=ddb.Attribute(name="order_id", type=ddb.AttributeType.STRING),
            removal_policy=props.removal_policy,
        )
        self.dlq = sqs.Queue(
            self, "OrdersDLQ",
            queue_name=f"ho02-{name}-dlq",
            retention_period=Duration.days(7),
            removal_policy=props.removal_policy,
        )
        self.queue = sqs.Queue(
            self, "OrdersQueue",
            queue_name=f"ho02-{name}-orders-queue",
            visibility_timeout=props.visibility_timeout,
            dead_letter_queue=sqs.DeadLetterQueue(
                queue=self.dlq, max_receive_count=props.max_receive_count),
            removal_policy=props.removal_policy,
        )
        self.function = _lambda.Function(
            self, "OrdersFn",
            function_name=f"ho02-{name}-fn",
            runtime=_lambda.Runtime.PYTHON_3_12,
            handler="orders.handler",
            code=_lambda.InlineCode(LAMBDA_CODE),
            memory_size=256,
            timeout=Duration.seconds(30),
            environment={"TABLE_NAME": self.table.table_name},
        )
        # ---- 内部挂接：队列驱动 Lambda，落表权限按需授予
        self.function.add_event_source(SqsEventSource(self.queue))
        self.table.grant_read_write_data(self.function)

        Stack.of(self).export_value(self.queue.queue_arn)


class AlphaStack(Stack):
    """调用方一：alpha 管道，全默认值。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        self.pipeline = OrderPipelineConstruct(
            self, "Pipeline", OrderPipelineProps(pipeline_name="alpha"))
        cdk.CfnOutput(self, "AlphaQueue", value=self.pipeline.queue.queue_name)
        cdk.CfnOutput(self, "AlphaTable", value=self.pipeline.table.table_name)


class BetaStack(Stack):
    """调用方二：beta 管道，覆盖两个默认值（可见性超时、DLQ 阈值）——验证可定制。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        self.pipeline = OrderPipelineConstruct(
            self, "Pipeline",
            OrderPipelineProps(
                pipeline_name="beta",
                visibility_timeout=Duration.seconds(60),
                max_receive_count=5,
            ))
        cdk.CfnOutput(self, "BetaQueue", value=self.pipeline.queue.queue_name)
        cdk.CfnOutput(self, "BetaTable", value=self.pipeline.table.table_name)

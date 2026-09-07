"""ho30 日志分析平台 CDK 栈。"""
import aws_cdk as cdk
from aws_cdk import (
    aws_kinesis as kinesis,
    aws_dynamodb as ddb,
    aws_s3 as s3,
    aws_lambda as _lambda,
    aws_sqs as sqs,
    aws_lambda_event_sources as sources,
    Duration, RemovalPolicy, Stack,
)
from constructs import Construct


class LogPlatformStack(Stack):
    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)

        stream = kinesis.Stream(self, "LogStream", stream_name="ho30-logs",
                                shard_count=1, removal_policy=RemovalPolicy.DESTROY)
        table = ddb.Table(self, "Events", table_name="ho30-events",
                          partition_key=ddb.Attribute(name="id", type=ddb.AttributeType.STRING),
                          removal_policy=RemovalPolicy.DESTROY)
        bucket = s3.Bucket(self, "Archive", bucket_name="ho30-archive",
                           removal_policy=RemovalPolicy.DESTROY, auto_delete_objects=True)
        alerts = sqs.Queue(self, "Alerts", queue_name="ho30-alerts",
                           removal_policy=RemovalPolicy.DESTROY)

        fn = _lambda.Function(self, "Cleaner", function_name="ho30-cleaner",
                              runtime=_lambda.Runtime.PYTHON_3_12,
                              handler="cleaner.handler",
                              code=_lambda.Code.from_asset("../functions"),
                              memory_size=512, timeout=Duration.seconds(60),
                              environment={
                                  "DETAIL_TABLE": table.table_name,
                                  "ARCHIVE_BUCKET": bucket.bucket_name,
                                  "ALERT_Q_URL": alerts.queue_url,
                              })
        fn.add_event_source(sources.KinesisEventSource(stream,
                              starting_position=_lambda.StartingPosition.LATEST,
                              batch_size=100))


app = cdk.App()
LogPlatformStack(app, "ho30-platform",
                 env=cdk.Environment(account="000000000000", region="us-east-1"))
app.synth()

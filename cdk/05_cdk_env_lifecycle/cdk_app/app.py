"""ho05 CDK 应用：context 驱动 dev/prod 双环境 + RemovalPolicy 生命周期策略。

context（合成期分支，模板形状随环境变）：
  cdklocal deploy -c env=dev   → 单副本、PAY_PER_REQUEST、全 DESTROY、无版本化
  cdklocal deploy -c env=prod  → 三副本（队列复制）、PROVISIONED(5,5)、
                                 表+桶 RETAIN、版本化开启

CfnParameter（部署期参数，同一模板不同值）：
  -c batch_size=N → 模板 Parameters.BatchSize，部署时不改模板形状，
  用于"CfnParameter vs Context 取舍"教学：形状差异用 context，纯取值差异
  用 CfnParameter。

命名约定：物理名带环境前缀 ho05-dev-* / ho05-prob-*，双环境可并存。
"""
import aws_cdk as cdk
from aws_cdk import (
    CfnParameter,
    Duration,
    Environment,
    RemovalPolicy,
    Stack,
    aws_dynamodb as ddb,
    aws_s3 as s3,
    aws_sqs as sqs,
)
from constructs import Construct

REGION = "us-east-1"
ACCOUNT = "000000000000"


class Ho35Stack(Stack):
    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        env = self.node.try_get_context("env") or "dev"
        is_prod = env == "prod"
        # 生命周期策略：prod 保留数据资产，dev 全部随栈走
        asset_policy = RemovalPolicy.RETAIN if is_prod else RemovalPolicy.DESTROY

        # 部署期参数：同一模板、部署时给值（不改变模板形状）
        batch = CfnParameter(self, "BatchSize", type="Number", default=10,
                             min_value=1, max_value=100,
                             description="队列批处理大小（部署期可调）")
        batch_size = batch.value_as_number

        # 存储：环境分支决定计费模式 / 版本化 / 删除策略
        self.table = ddb.Table(
            self, "Items",
            table_name=f"ho05-{env}-items",
            partition_key=ddb.Attribute(name="order_id", type=ddb.AttributeType.STRING),
            billing_mode=(ddb.BillingMode.PROVISIONED if is_prod
                          else ddb.BillingMode.PAY_PER_REQUEST),
            read_capacity=5 if is_prod else None,
            write_capacity=5 if is_prod else None,
            removal_policy=asset_policy,
        )
        self.bucket = s3.Bucket(
            self, "Archive",
            bucket_name=f"ho05-{env}-archive",
            encryption=s3.BucketEncryption.S3_MANAGED,
            versioned=is_prod,                      # 版本化只进 prod
            removal_policy=asset_policy,
        )

        # 队列：prod 三副本扇出（形状差异的典型），dev 单队列
        dlq = sqs.Queue(self, "DLQ", queue_name=f"ho05-{env}-dlq",
                        removal_policy=RemovalPolicy.DESTROY)
        self.queues = [
            sqs.Queue(
                self, f"Jobs{i}" if i else "Jobs",
                queue_name=f"ho05-{env}-jobs-{i}" if is_prod else f"ho05-{env}-jobs",
                visibility_timeout=Duration.seconds(60 if is_prod else 15),
                dead_letter_queue=sqs.DeadLetterQueue(queue=dlq, max_receive_count=3),
                removal_policy=RemovalPolicy.DESTROY,
            )
            for i in range(3 if is_prod else 1)
        ]
        cdk.CfnOutput(self, "Env", value=env)
        cdk.CfnOutput(self, "BatchSizeOut", value=str(batch_size))
        cdk.CfnOutput(self, "QueueCount", value=str(len(self.queues)))
        cdk.CfnOutput(self, "Table", value=self.table.table_name)


app = cdk.App()
env = app.node.try_get_context("env") or "dev"
Ho35Stack(app, f"ho05-{env}-stack",
          env=Environment(account=ACCOUNT, region=REGION))
app.synth()

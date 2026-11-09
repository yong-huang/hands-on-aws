"""ho04 CDK 应用：同一个队列 URL 的三种跨栈共享通道。

通道一（Stack 属性引用）：ConsumerRefStack 持有 producer 实例，直接读
  producer.queue.queue_url → CDK 自动生成 Export + Fn::ImportValue。
通道二（NestedStack）：父栈内的嵌套栈建队列，兄弟/父级引用 → Fn::GetAtt
  [NestedStack资源, Outputs.Xxx]，子模板独立成文件。
通道三（SSM Parameter Store）：producer 把队列 URL 写进 SSM 参数（部署期
  CFN 解析 GetAtt 后落值），消费方 Lambda 运行时 boto3 get_parameter 读取
  ——IaC 通道之外的运行时通道。

各消费方都是一个 Lambda，把拿到的队列 URL 原样返回，供断言逐一比对。
"""
import aws_cdk as cdk
from aws_cdk import (
    Duration,
    NestedStack,
    Stack,
    aws_lambda as _lambda,
    aws_sqs as sqs,
    aws_ssm as ssm,
)
from constructs import Construct

REGION = "us-east-1"
ACCOUNT = "000000000000"

def make_fn(scope: Construct, cid: str, name: str, **env) -> _lambda.Function:
    return _lambda.Function(
        scope, cid, function_name=name,
        runtime=_lambda.Runtime.PYTHON_3_12,
        handler="index.handler",
        code=_lambda.InlineCode(
            "import json, os, boto3\n"
            "ssm = boto3.client('ssm', endpoint_url=f\"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566\",\n"
            "                   region_name=os.environ['AWS_REGION'])\n"
            "def handler(event, context):\n"
            "    param = os.environ.get('SSM_PARAM')\n"
            "    if param:\n"
            "        url = ssm.get_parameter(Name=param)['Parameter']['Value']\n"
            "        return {'channel': 'ssm-runtime', 'queue_url': url}\n"
            "    return {'channel': 'iac-ref', 'queue_url': os.environ['QUEUE_URL']}\n"),
        memory_size=256, timeout=Duration.seconds(30),
        environment={k: v for k, v in env.items() if v is not None})


class ProducerStack(Stack):
    """源栈：队列。SSM 参数由部署脚本写入（见 README 坑实录）。

    真实 AWS 上的 CDK 写法（本机 LocalStack 的 SSM CFN provider 不可用，
    部署期解析后落入 SSM 的写法保留在此供迁移参考）：
        ssm.StringParameter(self, "QueueUrlParam",
                            parameter_name="ho04-queue-url",
                            string_value=self.queue.queue_url)
    """

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        self.queue = sqs.Queue(
            self, "Source", queue_name="ho04-src-queue",
            removal_policy=cdk.RemovalPolicy.DESTROY)
        cdk.CfnOutput(self, "SrcQueueUrl", value=self.queue.queue_url)


class ConsumerRefStack(Stack):
    """通道一：Stack 属性引用 → Export + Fn::ImportValue。"""

    def __init__(self, scope: Construct, cid: str, producer: ProducerStack, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        make_fn(self, "Fn", "ho04-ref-fn",
                QUEUE_URL=producer.queue.queue_url)     # 跨栈引用在此发生
        cdk.CfnOutput(self, "Channel", value="stack-attr-importvalue")


class NsProducer(NestedStack):
    """嵌套子栈：建队列。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        self.queue = sqs.Queue(
            self, "NestedQueue", queue_name="ho04-nested-queue",
            removal_policy=cdk.RemovalPolicy.DESTROY)


class ParentNestedStack(Stack):
    """通道二：父栈引用嵌套栈内资源 → Fn::GetAtt [资源, Outputs.Xxx]。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        ns = NsProducer(self, "NsProducer")
        make_fn(self, "Fn", "ho04-nested-fn",
                QUEUE_URL=ns.queue.queue_url)           # 穿透嵌套栈的引用
        cdk.CfnOutput(self, "Channel", value="nestedstack-getatt")


class ConsumerSsmStack(Stack):
    """通道三：运行时从 SSM 取值（IaC 只传参数名，不传值）。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        make_fn(self, "Fn", "ho04-ssm-fn",
                SSM_PARAM="ho04-queue-url")
        cdk.CfnOutput(self, "Channel", value="ssm-runtime-fetch")


app = cdk.App()
producer = ProducerStack(app, "ho04-producer-stack",
                         env=cdk.Environment(account=ACCOUNT, region=REGION))
ConsumerRefStack(app, "ho04-consumer-ref-stack", producer,
                 env=cdk.Environment(account=ACCOUNT, region=REGION))
ParentNestedStack(app, "ho04-parent-stack",
                  env=cdk.Environment(account=ACCOUNT, region=REGION))
ConsumerSsmStack(app, "ho04-consumer-ssm-stack",
                 env=cdk.Environment(account=ACCOUNT, region=REGION))
app.synth()

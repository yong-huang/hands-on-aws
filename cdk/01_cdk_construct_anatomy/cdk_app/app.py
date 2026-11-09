"""ho01 CDK 应用：同一个 S3 桶的三种构造层级写法 + escape hatch 改默认值。

三个 Stack 各自 synth 成独立模板，供对比脚本抽取归档：
  ho01-l1-stack  —— L1：s3.CfnBucket，你写什么模板里就是什么
  ho01-l2-stack  —— L2：s3.Bucket，默认值注入 + 逻辑 ID 散列
  ho01-l2x-stack —— L2 + escape hatch（defaultChild/addOverride）改写默认属性
  ho01-l3-stack  —— L3：cloudtrail.Trail 一个 Construct 合成桶+桶策略+Trail（仅 synth 对比）

只部署某几个栈？CLI 自带栈选择：cdklocal deploy ho01-l2x-stack
"""
import aws_cdk as cdk
from aws_cdk import (
    Stack,
    aws_s3 as s3,
    aws_cloudtrail as cloudtrail,
)
from constructs import Construct

REGION = "us-east-1"
ACCOUNT = "000000000000"


# ---------------------------------------------------------------- L1
class L1Stack(Stack):
    """L1（CfnBucket）：属性名与 CFN 模板一一对应，没有任何默认值。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        s3.CfnBucket(
            self, "RawBucket",
            bucket_name="ho01-l1-raw",
            # 想要版本化/加密？自己把模板字段写全，写漏了就没有
        )
        cdk.CfnOutput(self, "L1Bucket", value="ho01-l1-raw")


# ---------------------------------------------------------------- L2
class L2Stack(Stack):
    """L2（s3.Bucket）：安全默认值自动注入，逻辑 ID 带散列。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        s3.Bucket(
            self, "Data",
            bucket_name="ho01-l2-data",
            encryption=s3.BucketEncryption.S3_MANAGED,
            removal_policy=cdk.RemovalPolicy.DESTROY,
        )
        cdk.CfnOutput(self, "L2Bucket", value="ho01-l2-data")


# ------------------------------------------------- L2 + escape hatch
class L2EscapeStack(Stack):
    """L2 + escape hatch：用 defaultChild/addOverride 改写 L2 没暴露的模板字段。

    三个 override 各有教学点：版本化打开（线上断言 Enabled）；默认加密算法
    AES256 改成 aws:kms——注意路径必须用 CFN 规范属性名 ServerSideEncryptionByDefault
    （SDK 名 ApplyServerSideEncryptionByDefault 是无效路径，会合成出假键，见踩坑）；
    PAB 单字段改 False——模板里确实变 False，但 CFN 引擎部署时把部分字段归一化成
    全 True（线上实测），是 escape hatch 双刃剑的活教材。
    """

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        bucket = s3.Bucket(
            self, "Data",
            bucket_name="ho01-l2x-data",
            encryption=s3.BucketEncryption.S3_MANAGED,
            removal_policy=cdk.RemovalPolicy.DESTROY,
        )
        cfn = bucket.node.default_child          # → s3.CfnBucket
        assert isinstance(cfn, s3.CfnBucket)
        cfn.add_override("Properties.VersioningConfiguration.Status", "Enabled")
        cfn.add_override(
            "Properties.BucketEncryption.ServerSideEncryptionConfiguration."
            "0.ServerSideEncryptionByDefault.SSEAlgorithm", "aws:kms")
        # 危险动作示范：只改 PAB 一个字段为 False——见 README"模板归一化"坑
        cfn.add_override("Properties.PublicAccessBlockConfiguration.BlockPublicPolicy", False)
        cdk.CfnOutput(self, "L2xBucket", value="ho01-l2x-data")


# ---------------------------------------------------------------- L3
class L3Stack(Stack):
    """L3 示例：Trail 一个 Construct 合成出一组资源（审计桶+桶策略+Trail）。

    "开一条 CloudTrail 审计"这个动作被官方封装成一个 Construct，模板里自动
    多出桶、桶策略、Trail 三个资源——这正是高层构造的复用威力。注：官方对
    L2/L3 界线并不严格，Trail 常被归为 L2，但它是"一个声明、一组资源"最干净
    的官方范例；仅 synth 对比，不部署（L3 部署形态见 cdk/02 的自定义构造库）。
    """

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        cloudtrail.Trail(self, "Audit")
        # 不给名字时：桶、策略、Trail 全部自动生成并互相挂接
        cdk.CfnOutput(self, "L3Note", value="one construct -> bucket+policy+trail")


app = cdk.App()
for name, cls in [
    ("ho01-l1-stack", L1Stack),
    ("ho01-l2-stack", L2Stack),
    ("ho01-l2x-stack", L2EscapeStack),
    ("ho01-l3-stack", L3Stack),
]:
    cls(app, name, env=cdk.Environment(account=ACCOUNT, region=REGION))

app.synth()
# 只部署某几个栈？CLI 自带栈选择：cdklocal deploy ho01-l2x-stack

"""ho06 CDK 应用：Lambda-backed Custom Resource 把种子数据接进部署生命周期。

机制：CR Lambda 响应 CFN 的 Create/Update/Delete 三种事件——
  Create/Update：按 Properties.seeds 全量重写 DDB 种子数据
  Delete：清空全部种子（防孤儿数据）
physicalResourceId 稳定为 "ho06-seeds-v1"：不变 ID → 属性变化走 Update
（换 ID 会触发 Replace：先删后建，数据全损）。

context 开关：
  -c extra=1   → 种子多 1 条（3→4），触发 Update 事件（验收用）
响应 CFN 必须签名回 POST ResponseURL（labs/26 已验证的回调协议）。
"""
import json
import urllib.request

import aws_cdk as cdk
from aws_cdk import (
    CustomResource,
    Duration,
    Environment,
    RemovalPolicy,
    Stack,
    aws_dynamodb as ddb,
    aws_lambda as _lambda,
)
from constructs import Construct

REGION = "us-east-1"
ACCOUNT = "000000000000"

CR_HANDLER = """import json, os, urllib.request


def seeds_of(props):
    raw = props.get("Seeds") or "[]"
    return json.loads(raw)


def rewrite(table, seeds):
    # 全量重写：先清旧种子再写新种子，保证 CR 属性与表状态强一致。
    # 注意 delete+put 同一键不能进同一个 batch_writer 缓冲——BatchWriteItem
    # 会拒 "Provided list of item keys contains duplicates"（真实 AWS 同规），
    # 这里直接用单条调用。
    for item in table.scan(ProjectionExpression="sk")["Items"]:
        table.delete_item(Key={"sk": item["sk"]})
    for s in seeds:
        table.put_item(Item={"sk": s["id"], "amount": str(s.get("amount", 0)),
                             "note": s.get("note", "")})


def handler(event, context):
    request_type = event["RequestType"]
    props = event.get("ResourceProperties", {})
    import boto3
    ddb = boto3.resource(
        "dynamodb",
        endpoint_url=f"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566",
        region_name=os.environ["AWS_REGION"])
    table = ddb.Table(os.environ["TABLE_NAME"])

    if request_type in ("Create", "Update"):
        rewrite(table, seeds_of(props))
    elif request_type == "Delete":
        rewrite(table, [])          # 清空种子，防孤儿数据

    resp = {
        "Status": "SUCCESS",
        "PhysicalResourceId": "ho06-seeds-v1",   # 稳定：属性变化走 Update
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": {"seed_count": str(len(seeds_of(props)) if request_type != "Delete" else 0)},
    }
    body = json.dumps(resp).encode()
    req = urllib.request.Request(
        event["ResponseURL"], data=body,
        headers={"Content-Type": "", "Content-Length": str(len(body))})
    req.get_method = lambda: "PUT"
    urllib.request.urlopen(req, timeout=10)
"""


class Ho36Stack(Stack):
    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        table = ddb.Table(
            self, "Seeds",
            table_name="ho06-seeds",
            partition_key=ddb.Attribute(name="sk", type=ddb.AttributeType.STRING),
            removal_policy=RemovalPolicy.DESTROY)

        cr_fn = _lambda.Function(
            self, "CrFn",
            function_name="ho06-cr-fn",
            runtime=_lambda.Runtime.PYTHON_3_12,
            handler="index.handler",
            code=_lambda.InlineCode(CR_HANDLER),
            memory_size=256,
            timeout=Duration.seconds(60),
            environment={"TABLE_NAME": table.table_name},
        )
        table.grant_read_write_data(cr_fn)

        # 种子数据：context 决定 3 条还是 4 条 → 属性变化触发 Update
        extra = bool(self.node.try_get_context("extra"))
        seeds = [
            {"id": "A-001", "amount": 10, "note": "alpha"},
            {"id": "A-002", "amount": 20, "note": "beta"},
            {"id": "A-003", "amount": 30, "note": "gamma"},
        ]
        if extra:
            seeds.append({"id": "A-004", "amount": 40, "note": "delta"})

        CustomResource(
            self, "SeedCr",
            service_token=cr_fn.function_arn,
            properties={"Seeds": json.dumps(seeds)},
            resource_type="Custom::Ho36Seeder",
        )
        cdk.CfnOutput(self, "SeedTable", value=table.table_name)


app = cdk.App()
Ho36Stack(app, "ho06-cr-stack",
          env=Environment(account=ACCOUNT, region=REGION))
app.synth()

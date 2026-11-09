"""ho11 终极综合：订单平台全栈工程化交付（整合 cdk/01-10 全部能力）。

能力清单（每项一个可追溯的来源实验）：
  构造库思维（cdk/02）    —— OrderPlatformStack 内聚组装
  Aspect 治理（cdk/03）   —— TaggingAspect + ComplianceAspect（find_all visit）
  双环境分支（cdk/05）    —— -c env=dev|prod：计费/版本化/RETAIN 全分支
  CR 种子（cdk/06）       —— CustomResource 播种菜单数据，物理 ID 恒定
  断言测试（cdk/07）      —— tests/test_platform.py 对双环境模板断言
  流水线交付（cdk/10）    —— make test/deploy/smoke/destroy/pipeline
  escape hatch/L1（cdk/01/39）—— API GW v2 用 L1 裸资源（L2 集成类撞
                              jsii+typeguard 协议 bug 的本机实测兜底）

架构：HTTP API（POST /orders → 入队；GET /orders/{id} → 查表）
      → 订单队列(+DLQ) → 处理器 Lambda → 明细表（CR 播种）
      + 归档桶（prod 版本化 + RETAIN）
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
    aws_s3 as s3,
    aws_sqs as sqs,
)
from aws_cdk.aws_lambda_event_sources import SqsEventSource
from constructs import Construct, IConstruct

REGION = "us-east-1"
ACCOUNT = "000000000000"

ORDER_FN_CODE = """import json, os, uuid
import boto3

ddb = boto3.resource(
    "dynamodb",
    endpoint_url=f"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566",
    region_name=os.environ["AWS_REGION"])
table = ddb.Table(os.environ["TABLE_NAME"])
sqs = boto3.client(
    "sqs", endpoint_url=f"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566",
    region_name=os.environ["AWS_REGION"])


def handler(event, context):
    if event["httpMethod"] == "POST":
        body = json.loads(event.get("body") or "{}")
        order_id = body.get("order_id")
        amount = body.get("amount")
        if not order_id or amount is None:
            return _resp(400, {"error": "order_id 与 amount 必填"})
        if not str(order_id).startswith("ORD-"):
            return _resp(400, {"error": "order_id 须以 ORD- 开头"})
        sqs.send_message(
            QueueUrl=os.environ["QUEUE_URL"],
            MessageBody=json.dumps({"order_id": order_id, "amount": amount}))
        return _resp(201, {"order_id": order_id, "status": "accepted"})
    if event["httpMethod"] == "GET":
        oid = event["pathParameters"]["order_id"]
        item = table.get_item(Key={"sk": oid}).get("Item")
        if not item:
            return _resp(404, {"error": f"{oid} 不存在"})
        return _resp(200, {"order_id": item["sk"], "amount": item["amount"],
                           "status": item["status"]})
    return _resp(400, {"error": "未知路由"})


def _resp(code, body):
    return {"statusCode": code,
            "headers": {"content-type": "application/json"},
            "body": json.dumps(body)}
"""

PROCESSOR_FN_CODE = """import json, os
import boto3

ddb = boto3.resource(
    "dynamodb",
    endpoint_url=f"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566",
    region_name=os.environ["AWS_REGION"])
table = ddb.Table(os.environ["TABLE_NAME"])


def handler(event, context):
    for rec in event.get("Records", []):
        body = json.loads(rec["body"])
        table.put_item(Item={
            "sk": body["order_id"],
            "amount": str(body.get("amount", 0)),
            "status": "PROCESSED",
            "request_id": context.aws_request_id,
        })
    return {"ok": True}
"""

CR_HANDLER_CODE = """import json, os, urllib.request


def handler(event, context):
    import boto3
    ddb = boto3.resource(
        "dynamodb",
        endpoint_url=f"http://{os.environ['LOCALSTACK_HOSTNAME']}:4566",
        region_name=os.environ["AWS_REGION"])
    table = ddb.Table(os.environ["TABLE_NAME"])
    seeds = json.loads(event["ResourceProperties"].get("Seeds") or "[]")
    if event["RequestType"] in ("Create", "Update"):
        for item in table.scan(ProjectionExpression="sk")["Items"]:
            if str(item["sk"]).startswith("seed-"):
                table.delete_item(Key={"sk": item["sk"]})
        for s in seeds:
            table.put_item(Item={"sk": s["id"], "amount": str(s.get("amount", 0)),
                                 "status": "SEED", "note": s.get("note", "")})
    else:
        for item in table.scan(ProjectionExpression="sk")["Items"]:
            if str(item["sk"]).startswith("seed-"):
                table.delete_item(Key={"sk": item["sk"]})
    body = json.dumps({"Status": "SUCCESS", "PhysicalResourceId": "ho11-seeds-v1",
                       "StackId": event["StackId"], "RequestId": event["RequestId"],
                       "LogicalResourceId": event["LogicalResourceId"]}).encode()
    req = urllib.request.Request(event["ResponseURL"], data=body,
                                 headers={"Content-Type": "",
                                          "Content-Length": str(len(body))})
    req.get_method = lambda: "PUT"
    urllib.request.urlopen(req, timeout=10)
"""


# ------------------------------------------------- Aspect（cdk/03 机制）
class TaggingAspect:
    def __init__(self, env: str) -> None:
        self.env = env

    def visit(self, node: IConstruct) -> None:
        if hasattr(node, "tags") and callable(getattr(node.tags, "set_tag", None)):
            node.tags.set_tag("platform", "ho11")
            node.tags.set_tag("env", self.env)


class ComplianceAspect:
    def __init__(self) -> None:
        self.violations: list[str] = []

    def visit(self, node: IConstruct) -> None:
        from aws_cdk import aws_s3 as s3
        if isinstance(node, s3.CfnBucket) and node.bucket_encryption is None:
            kind = "L2" if isinstance(node.node.scope, s3.Bucket) else "L1-绕过"
            self.violations.append(f"[{kind}] 桶无加密配置: {node.node.path}")

    def report_or_none(self) -> None:
        if self.violations:
            for v in self.violations:
                print(f"❌ 合规拦截: {v}")
            raise SystemExit(1)


class OrderPlatformStack(Stack):
    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        env = self.node.try_get_context("env") or "dev"
        is_prod = env == "prod"
        asset_policy = RemovalPolicy.RETAIN if is_prod else RemovalPolicy.DESTROY

        table = ddb.Table(
            self, "Orders", table_name=f"ho11-{env}-orders",
            partition_key=ddb.Attribute(name="sk", type=ddb.AttributeType.STRING),
            billing_mode=(ddb.BillingMode.PROVISIONED if is_prod
                          else ddb.BillingMode.PAY_PER_REQUEST),
            read_capacity=5 if is_prod else None,
            write_capacity=5 if is_prod else None,
            removal_policy=asset_policy)
        bucket = s3.Bucket(
            self, "Archive", bucket_name=f"ho11-{env}-archive",
            encryption=s3.BucketEncryption.S3_MANAGED,
            versioned=is_prod,
            removal_policy=asset_policy)
        dlq = sqs.Queue(self, "DLQ", queue_name=f"ho11-{env}-dlq",
                        retention_period=Duration.days(7),
                        removal_policy=RemovalPolicy.DESTROY)
        queue = sqs.Queue(
            self, "OrderQueue", queue_name=f"ho11-{env}-orders-queue",
            visibility_timeout=Duration.seconds(60 if is_prod else 15),
            dead_letter_queue=sqs.DeadLetterQueue(queue=dlq, max_receive_count=3),
            removal_policy=RemovalPolicy.DESTROY)
        processor = _lambda.Function(
            self, "Processor", function_name=f"ho11-{env}-processor",
            runtime=_lambda.Runtime.PYTHON_3_12, handler="index.handler",
            code=_lambda.InlineCode(PROCESSOR_FN_CODE), memory_size=256,
            timeout=Duration.seconds(30), environment={"TABLE_NAME": table.table_name})
        processor.add_event_source(SqsEventSource(queue))
        table.grant_read_write_data(processor)

        order_fn = _lambda.Function(
            self, "OrderApi", function_name=f"ho11-{env}-order-api",
            runtime=_lambda.Runtime.PYTHON_3_12, handler="index.handler",
            code=_lambda.InlineCode(ORDER_FN_CODE), memory_size=256,
            timeout=Duration.seconds(30),
            environment={"TABLE_NAME": table.table_name,
                         "QUEUE_URL": queue.queue_url})
        table.grant_read_write_data(order_fn)
        queue.grant_send_messages(order_fn)

        cr_fn = _lambda.Function(
            self, "CrFn", function_name=f"ho11-{env}-cr-fn",
            runtime=_lambda.Runtime.PYTHON_3_12, handler="index.handler",
            code=_lambda.InlineCode(CR_HANDLER_CODE), memory_size=256,
            timeout=Duration.seconds(60), environment={"TABLE_NAME": table.table_name})
        table.grant_read_write_data(cr_fn)
        CustomResource(
            self, "SeedCr", service_token=cr_fn.function_arn,
            properties={"Seeds": json.dumps([
                {"id": "seed-A-001", "amount": 10, "note": "菜单样例"},
                {"id": "seed-A-002", "amount": 20, "note": "菜单样例"},
                {"id": "seed-A-003", "amount": 30, "note": "菜单样例"},
            ])},
            resource_type="Custom::Ho41Seeder")

        # ---- REST API v1（L1 兜底：apigatewayv2 服务不在本机授权内；
        #      v1/v2 的 L2 集成类均撞 jsii+typeguard 协议 bug——L1 全裸资源）
        from aws_cdk import aws_apigateway as apigw
        rest = apigw.CfnRestApi(self, "RestApi", name=f"ho11-{env}-api")
        orders_res = apigw.CfnResource(
            self, "OrdersRes", rest_api_id=rest.ref,
            parent_id=rest.attr_root_resource_id, path_part="orders")
        one_res = apigw.CfnResource(
            self, "OrderRes", rest_api_id=rest.ref,
            parent_id=orders_res.ref, path_part="{order_id}")
        # ⚠️ Fn::Sub 带变量映射在本版 LocalStack 上解析不可靠（输出 "unknown"），
        # 一律 Fn::Join + GetAtt 显式拼接
        invoke_uri = cdk.Fn.join("", [
            "arn:aws:apigateway:", self.region,
            ":lambda:path/2015-03-31/functions/",
            order_fn.function_arn, "/invocations"])
        # L1 嵌套 dict 走 CFN 规范 PascalCase（snake 键会被静默丢弃）
        proxy = {"type": "AWS_PROXY", "integrationHttpMethod": "POST",
                 "uri": invoke_uri}
        post_method = apigw.CfnMethod(
            self, "PostMethod", rest_api_id=rest.ref,
            resource_id=orders_res.ref, http_method="POST",
            authorization_type="NONE", integration=proxy)
        get_method = apigw.CfnMethod(
            self, "GetMethod", rest_api_id=rest.ref,
            resource_id=one_res.ref, http_method="GET",
            authorization_type="NONE", integration=proxy)
        deployment = apigw.CfnDeployment(
            self, "Deployment", rest_api_id=rest.ref)
        deployment.add_depends_on(post_method)   # 部署须等 Method 就位
        deployment.add_depends_on(get_method)
        apigw.CfnStage(
            self, "Stage", rest_api_id=rest.ref,
            deployment_id=deployment.ref, stage_name="v1")
        _lambda.CfnPermission(
            self, "ApiInvokePerm", function_name=order_fn.function_name,
            action="lambda:InvokeFunction", principal="apigateway.amazonaws.com",
            source_arn=cdk.Fn.join("", [
                "arn:aws:execute-api:", self.region, ":",
                self.account, ":", rest.ref, "/*/*"]))

        cdk.CfnOutput(self, "EnvOut", value=env)
        cdk.CfnOutput(self, "ApiEndpoint", value=cdk.Fn.join("", [
            "http://", rest.ref, ".execute-api.", self.region,   # self.region 是显式具体值；Fn::Join+Ref(Region) 本版 LocalStack 解析有 bug
            ".localhost.localstack.cloud:4566/v1"]))
        cdk.CfnOutput(self, "QueueName", value=queue.queue_name)
        cdk.CfnOutput(self, "TableName", value=table.table_name)
        cdk.CfnOutput(self, "BucketName", value=bucket.bucket_name)


app = cdk.App()
env = app.node.try_get_context("env") or "dev"
stack = OrderPlatformStack(app, f"ho11-{env}-stack",
                           env=Environment(account=ACCOUNT, region=REGION))

# Aspect 治理：全资源打标 + 合规检查（find_all visit 等价形式，cdk/03 实测）
tagger, compliance = TaggingAspect(env), ComplianceAspect()
for node in stack.node.find_all():
    tagger.visit(node)
    compliance.visit(node)
compliance.report_or_none()

app.synth()

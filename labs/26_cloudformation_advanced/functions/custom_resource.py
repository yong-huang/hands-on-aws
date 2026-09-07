"""ho26 Lambda-backed Custom Resource：响应 CFN 的 Create/Delete，动态建删 DynamoDB 表。"""
import json
import os
import time
import urllib.request


def resolve():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


import boto3  # noqa: E402
ddb = boto3.client("dynamodb", endpoint_url=resolve(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
ssm = boto3.client("ssm", endpoint_url=resolve(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))


def respond(event, status, data=None, reason=""):
    body = json.dumps({
        "Status": status,
        "Reason": reason or (json.dumps(data) if data else ""),
        "PhysicalResourceId": f"ho26-cr-{int(time.time())}",
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": data or {},
    }).encode()
    try:   # 合成事件（无真实 ResponseURL）时容忍网络失败
        req = urllib.request.Request(event["ResponseURL"], data=body,
                                     headers={"Content-Type": "", "Content-Length": str(len(body))})
        req.get_method = lambda: "PUT"
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"[ho26] respond skipped: {e}")


def handler(event, context):
    ssm.put_parameter(Name="/ho26/cr-ran", Value=f"{event['RequestType']}@{time.time()}",
                      Type="String", Overwrite=True)
    props = event.get("ResourceProperties", {})
    table = props.get("TableName", "ho26-cr-table")
    try:
        if event["RequestType"] in ("Create", "Update"):
            try:
                ddb.create_table(TableName=table,
                                 AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
                                 KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
                                 BillingMode="PAY_PER_REQUEST")
                for _ in range(40):
                    if ddb.describe_table(TableName=table)["Table"]["TableStatus"] == "ACTIVE":
                        break
                    time.sleep(0.5)
            except ddb.exceptions.ResourceInUseException:
                pass
            respond(event, "SUCCESS", {"Table": table})
            print(f"[ho26] CR created {table}")
        else:  # Delete
            try:
                ddb.delete_table(TableName=table)
            except ddb.exceptions.ResourceNotFoundException:
                pass
            respond(event, "SUCCESS")
            print(f"[ho26] CR deleted {table}")
    except Exception as e:
        print(f"[ho26] CR error: {e}")
        respond(event, "FAILED", reason=str(e))

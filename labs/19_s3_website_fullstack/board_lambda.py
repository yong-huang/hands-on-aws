"""ho19 留言板后端：POST 写入 / GET 列出（CORS 全放开，供静态页 fetch）。"""
import json
import os
import time
import uuid


def resolve_endpoint():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


import boto3  # noqa: E402
ddb = boto3.client("dynamodb", endpoint_url=resolve_endpoint(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
TABLE = os.environ.get("BOARD_TABLE", "ho19-board")
CORS = {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"}


def handler(event, context):
    if event.get("httpMethod") == "POST":
        body = json.loads(event.get("body") or "{}")
        msg = (body.get("message") or "").strip()
        if not msg:
            return {"statusCode": 400, "headers": CORS, "body": json.dumps({"error": "empty"})}
        item = {"id": {"S": uuid.uuid4().hex[:8]}, "message": {"S": msg[:200]},
                "ts": {"N": str(int(time.time() * 1000))}}
        ddb.put_item(TableName=TABLE, Item=item)
        return {"statusCode": 201, "headers": CORS, "body": json.dumps({"created": item["id"]["S"]})}

    rows = ddb.scan(TableName=TABLE).get("Items", [])
    msgs = sorted(({"id": r["id"]["S"], "message": r["message"]["S"],
                    "ts": int(r["ts"]["N"])} for r in rows), key=lambda x: x["ts"])
    return {"statusCode": 200, "headers": CORS, "body": json.dumps({"messages": msgs})}

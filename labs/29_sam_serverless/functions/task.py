"""ho29 任务函数：GET 列表 / POST 创建（SimpleTable 存储）。"""
import json
import os
import time
import uuid


def resolve():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


import boto3  # noqa: E402
ddb = boto3.client("dynamodb", endpoint_url=resolve(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
TABLE = os.environ.get("TABLE_NAME", "ho29-tasks")
CORS = {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"}


def handler(event, context):
    if event.get("httpMethod") == "POST":
        body = json.loads(event.get("body") or "{}")
        title = (body.get("title") or "").strip()
        if not title:
            return {"statusCode": 400, "headers": CORS, "body": json.dumps({"error": "empty"})}
        ddb.put_item(TableName=TABLE, Item={
            "id": {"S": uuid.uuid4().hex[:8]},
            "title": {"S": title[:120]},
            "ts": {"N": str(int(time.time() * 1000))},
        })
        return {"statusCode": 201, "headers": CORS, "body": json.dumps({"created": True})}

    rows = ddb.scan(TableName=TABLE).get("Items", [])
    tasks = sorted(({"id": r["id"]["S"], "title": r["title"]["S"],
                     "ts": int(r["ts"]["N"])} for r in rows), key=lambda x: x["ts"])
    return {"statusCode": 200, "headers": CORS, "body": json.dumps({"tasks": tasks})}

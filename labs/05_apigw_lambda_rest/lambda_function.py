"""ho05 Lambda：API Gateway AWS_PROXY 后端 —— items 资源的完整 CRUD。

代理集成下 API Gateway 把整个 HTTP 请求包成 event 传进来：
httpMethod / path / pathParameters / body；返回值必须是
{statusCode, headers, body} 三件套，否则网关报 502。
"""
import json
import os

import boto3


def resolve_endpoint():
    # Lambda 运行时容器里 localhost≠LocalStack，用注入的 LOCALSTACK_HOSTNAME
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


dynamodb = boto3.client("dynamodb", endpoint_url=resolve_endpoint(),
                        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
TABLE = os.environ.get("ITEMS_TABLE", "ho05-items")

CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",  # 教学环境全放开；生产应限定来源
}


def resp(code, payload):
    return {"statusCode": code, "headers": CORS, "body": json.dumps(payload, ensure_ascii=False)}


def handler(event, context):
    method = event.get("httpMethod", "GET")
    path = event.get("path", "")
    item_id = (event.get("pathParameters") or {}).get("id")

    if method == "OPTIONS":  # 预检请求（正式配置还需在网关建 MOCK 集成）
        return resp(200, {})

    if method == "POST" and path == "/items":
        body = json.loads(event.get("body") or "{}")
        if "id" not in body:
            return resp(400, {"error": "id is required"})
        dynamodb.put_item(TableName=TABLE, Item={
            "id": {"S": body["id"]},
            "name": {"S": body.get("name", "")},
            "price": {"N": str(body.get("price", 0))},
        })
        return resp(201, {"created": body["id"]})

    if method == "GET" and path == "/items":
        out = dynamodb.scan(TableName=TABLE)
        items = [{k: list(v.values())[0] for k, v in it.items()} for it in out.get("Items", [])]
        return resp(200, {"items": items, "count": len(items)})

    if method == "GET" and item_id:
        out = dynamodb.get_item(TableName=TABLE, Key={"id": {"S": item_id}})
        if "Item" not in out:
            return resp(404, {"error": f"item {item_id} not found"})
        return resp(200, {k: list(v.values())[0] for k, v in out["Item"].items()})

    if method == "DELETE" and item_id:
        dynamodb.delete_item(TableName=TABLE, Key={"id": {"S": item_id}})
        return resp(200, {"deleted": item_id})

    return resp(400, {"error": f"unsupported {method} {path}"})

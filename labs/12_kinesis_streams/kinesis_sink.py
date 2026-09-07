"""ho12 Kinesis→Lambda 事件源消费者：把流记录落进 DynamoDB sink 表。"""
import json
import os
import base64

import boto3


def resolve_endpoint():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


ddb = boto3.client("dynamodb", endpoint_url=resolve_endpoint(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
TABLE = os.environ.get("SINK_TABLE", "ho12-sink")


def handler(event, context):
    for r in event.get("Records", []):
        payload = base64.b64decode(r["kinesis"]["data"]).decode()
        ddb.put_item(TableName=TABLE, Item={
            "pk": {"S": r["eventID"]},                 # 唯一：shard+seq
            "partition_key": {"S": r["kinesis"]["partitionKey"]},
            "data": {"S": payload},
        })
    print(f"[ho12] persisted {len(event.get('Records', []))} records")
    return {"ok": True}

"""ho04 Lambda：一个函数路由三种输入 —— S3 事件 / DynamoDB Streams / 手动调用。

教学点：
- 事件路由：Records 里 S3 事件带 s3 字段，Streams 事件 eventSource=aws:dynamodb；
- 事件驱动落库：把"发生了什么"写进 ho04-events 审计表（不是源表，避免 Stream 回环）；
- 结构化日志：print 输出进 CloudWatch Logs（LocalStack 模拟），可用 API 查回。
"""
import json
import os
import urllib.parse

import boto3

def resolve_endpoint():
    """Lambda 运行时是独立容器，localhost 不是 LocalStack。
    LocalStack 向运行时注入 LOCALSTACK_HOSTNAME（本机实测 192.168.215.2）指向可达地址；
    本地直接跑单测时退回 AWS_ENDPOINT_URL / localhost。"""
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


ENDPOINT = resolve_endpoint()
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
TABLE = os.environ.get("EVENTS_TABLE", "ho04-events")

dynamodb = boto3.client("dynamodb", endpoint_url=ENDPOINT, region_name=REGION)
s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name=REGION)


def record_event(source, detail):
    dynamodb.put_item(TableName=TABLE, Item={
        "id": {"S": detail["id"]},
        "source": {"S": source},
        "detail": {"S": json.dumps(detail, ensure_ascii=False)},
    })


def handler(event, context):
    for r in event.get("Records", []):
        if "s3" in r:  # S3 通知事件
            bucket = r["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(r["s3"]["object"]["key"])
            size = s3.head_object(Bucket=bucket, Key=key)["ContentLength"]
            record_event("s3", {"id": f"s3/{key}", "bucket": bucket, "size": size})
            print(f"[ho04] S3 event processed: {bucket}/{key} ({size}B)")
        elif r.get("eventSource", "").startswith("aws:dynamodb"):  # Streams 事件
            keys = r["dynamodb"].get("Keys", {})
            record_event("stream", {"id": "ddb/" + json.dumps(keys, sort_keys=True),
                                    "op": r.get("eventName")})
            print(f"[ho04] stream record: {r.get('eventName')} keys={keys}")

    if "echo" in event:  # 手动调用：回显
        return {"message": f"echo: {event['echo']}"}
    if event.get("boom"):  # 错误演示：主动抛异常，响应里出现 FunctionError
        raise RuntimeError("boom as requested")
    return {"ok": True, "saw_records": len(event.get("Records", []))}

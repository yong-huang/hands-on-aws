"""ho13 CSV 解析器：被 data/ 前缀的 S3 上传事件触发，把 CSV 内容解析进 DynamoDB。"""
import csv
import io
import json
import os
import urllib.parse

import boto3


def resolve_endpoint():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


s3 = boto3.client("s3", endpoint_url=resolve_endpoint(),
                  region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
ddb = boto3.client("dynamodb", endpoint_url=resolve_endpoint(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
TABLE = os.environ.get("ITEMS_TABLE", "ho13-items")


def handler(event, context):
    for r in event.get("Records", []):
        bucket = r["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(r["s3"]["object"]["key"])
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode()
        rows = list(csv.DictReader(io.StringIO(body)))
        for row in rows:
            ddb.put_item(TableName=TABLE, Item={
                "id": {"S": row["id"]},
                "name": {"S": row.get("name", "")},
                "source": {"S": key},
            })
        print(f"[ho13] parsed {key}: {len(rows)} rows -> {TABLE}")
    return {"ok": True}

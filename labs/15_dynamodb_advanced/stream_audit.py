"""ho15 流审计 Lambda：把源表的流记录（NEW_AND_OLD_IMAGES）写进审计表。"""
import json
import os


def resolve_endpoint():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


import boto3  # noqa: E402

ddb = boto3.client("dynamodb", endpoint_url=resolve_endpoint(),
                   region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
TABLE = os.environ.get("AUDIT_TABLE", "ho15-audit")


def handler(event, context):
    for r in event.get("Records", []):
        ev = r["eventName"]
        keys = r["dynamodb"].get("Keys", {})
        old = r["dynamodb"].get("OldImage")
        new = r["dynamodb"].get("NewImage")
        ddb.put_item(TableName=TABLE, Item={
            "id": {"S": f"{ev}:{json.dumps(keys, sort_keys=True)}"},
            "event": {"S": ev},
            "keys": {"S": json.dumps(keys)},
            "old_image": {"S": json.dumps(old) if old else ""},
            "new_image": {"S": json.dumps(new) if new else ""},
        })
        print(f"[ho15] audited {ev}")
    return {"ok": True}

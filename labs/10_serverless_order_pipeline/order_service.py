"""ho10 订单服务：一条 Lambda 走完整条链路。

下单请求 → 校验 → Secrets Manager 取库凭据 → KMS 加密卡号（敏感字段不落明文）
→ S3 归档 → SNS 按金额扇出（通知/审计两队列）。支持 API GW 代理与直调两种入口。
"""
import base64
import json
import os

import boto3


def resolve_endpoint():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


ENDPOINT = resolve_endpoint()
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
BUCKET = os.environ["BUCKET"]
TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
KMS_ALIAS = os.environ.get("KMS_ALIAS", "alias/ho10")

s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name=REGION)
kms = boto3.client("kms", endpoint_url=ENDPOINT, region_name=REGION)
sns = boto3.client("sns", endpoint_url=ENDPOINT, region_name=REGION)
secrets = boto3.client("secretsmanager", endpoint_url=ENDPOINT, region_name=REGION)

_db_cred = None


def db_credential():
    """Secrets Manager 取库凭据（进程内缓存一次）。"""
    global _db_cred
    if _db_cred is None:
        raw = secrets.get_secret_value(SecretId="ho10/db")["SecretString"]
        _db_cred = json.loads(raw)
        print(f"[ho10] db credential loaded for user={_db_cred['username']}")
    return _db_cred


def place_order(order):
    if not order.get("order_id") or "card" not in order or "amount" not in order:
        return 400, {"error": "order_id / card / amount are required"}
    cred = db_credential()
    blob = kms.encrypt(KeyId=KMS_ALIAS, Plaintext=order["card"].encode())["CiphertextBlob"]
    record = {
        "order_id": order["order_id"],
        "user": order.get("user", "anonymous"),
        "amount": order["amount"],
        "card_encrypted": base64.b64encode(blob).decode(),  # 卡号只以密文落盘
        "db_user": cred["username"],                        # 证明 Secret 读取成功
    }
    s3.put_object(Bucket=BUCKET, Key=f"orders/{order['order_id']}.json",
                  Body=json.dumps(record).encode())
    sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(record), MessageAttributes={
        "amount": {"DataType": "Number", "StringValue": str(order["amount"])},
    })
    print(f"[ho10] order {order['order_id']} archived and published")
    return 201, {"created": order["order_id"]}


def handler(event, context):
    if isinstance(event.get("body"), str):          # API Gateway 代理事件
        code, payload = place_order(json.loads(event["body"] or "{}"))
    else:                                           # 直调
        code, payload = place_order(event)
    return {"statusCode": code, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(payload)}

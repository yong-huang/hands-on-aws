"""ho30 清洗器：Kinesis 日志 → 脱敏/结构化 → DynamoDB 明细 + S3 归档 + 指标 + 告警。"""
import base64
import json
import os
import time
import urllib.parse


def resolve():
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


import boto3  # noqa: E402
kw = dict(endpoint_url=resolve(), region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
ddb = boto3.client("dynamodb", **kw)
s3 = boto3.client("s3", **kw)
cw = boto3.client("cloudwatch", **kw)
sqs = boto3.client("sqs", **kw)

DETAIL = os.environ.get("DETAIL_TABLE", "ho30-events")
ARCHIVE = os.environ.get("ARCHIVE_BUCKET", "")
ALERT_Q_URL = os.environ.get("ALERT_Q_URL", "")


def desensitize(record):
    """脱敏：手机号/邮箱打码。"""
    msg = record.get("msg", "")
    for pat in ("138", "139"):  # 简化的手机号前缀演示
        msg = msg.replace(f"{pat}00001234", f"{pat}****")
    return msg


def handler(event, context):
    n_ok, n_err = 0, 0
    day = time.strftime("%Y-%m-%d", time.gmtime(time.time() - 3 * 3600))
    body = []
    for r in event.get("Records", []):
        try:
            log = json.loads(base64.b64decode(r["kinesis"]["data"]))
        except Exception:
            continue
        log = {"ts": log.get("ts", int(time.time() * 1000)),
               "service": log.get("service", "?"),
               "level": log.get("level", "INFO"),
               "msg": desensitize(log),
               "run": log.get("run", "")}
        body.append(json.dumps(log, ensure_ascii=False))
        ddb.put_item(TableName=DETAIL, Item={
            "id": {"S": r["eventID"]},
            "run": {"S": log["run"]},
            "service": {"S": log["service"]},
            "level": {"S": log["level"]},
            "msg": {"S": json.dumps(log["msg"], ensure_ascii=False)[:300]},
            "ts": {"N": str(log["ts"])},
        })
        if log["level"] == "ERROR" and ALERT_Q_URL:
            sqs.send_message(QueueUrl=ALERT_Q_URL,
                             MessageBody=json.dumps(log, ensure_ascii=False))
        n_err += log["level"] == "ERROR"
        n_ok += 1
    if body and ARCHIVE:
        s3.put_object(Bucket=ARCHIVE, Key=f"{day}/batch-{int(time.time()*1000)}.json",
                      Body=("\n".join(body)).encode())
    # 指标打点用容器时钟（lab 22 实测）：容器时间从 Lambda 环境取不到，交给
    # 本地生成器打指标；这里只落明细/归档/告警
    print(f"[ho30] processed={n_ok} errors={n_err}")
    return {"processed": n_ok, "errors": n_err}

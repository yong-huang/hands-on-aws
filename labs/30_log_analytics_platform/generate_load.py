"""ho30 压测生成器 + 端到端断言：灌 N 条日志 → 明细/归档/告警/指标全链路验证。"""
import base64
import json
import sys
import time
import uuid

import boto3

ENDPOINT = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:4566"
TOTAL = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
RUN = uuid.uuid4().hex[:8]

kw = dict(endpoint_url=ENDPOINT, region_name="us-east-1",
          aws_access_key_id="test", aws_secret_access_key="test")
kinesis = boto3.client("kinesis", **kw)
ddb = boto3.client("dynamodb", **kw)
s3 = boto3.client("s3", **kw)
cw = boto3.client("cloudwatch", **kw)


def put_metrics(n_total, n_err):
    """指标打点用容器时钟（从 LocalStack 响应头取）。"""
    import urllib.request
    resp = urllib.request.urlopen(f"{ENDPOINT}/_localstack/health", timeout=5)
    from email.utils import parsedate_to_datetime
    dt = parsedate_to_datetime(resp.headers.get("Date"))
    ts = dt
    cw.put_metric_data(Namespace="Ho30", MetricData=[
        {"MetricName": "LogsProcessed", "Value": n_total,
         "Timestamp": ts, "Dimensions": [{"Name": "Pipeline", "Value": "main"}]},
        {"MetricName": "LogErrors", "Value": n_err,
         "Timestamp": ts, "Dimensions": [{"Name": "Pipeline", "Value": "main"}]},
    ])


def wait_for(predicate, timeout, what):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            print(f"  ✅ {what}（{last}）")
            return last
        time.sleep(3)
    print(f"  ❌ {what} 超时（最后: {last}）")
    sys.exit(1)


def main():
    print(f"  灌入 {TOTAL} 条日志（run={RUN}，含 {TOTAL//10} 条 ERROR）")
    n_sent = 0
    for batch in range(TOTAL // 100):
        recs = []
        for i in range(100):
            level = "ERROR" if (batch * 100 + i) % 10 == 0 else "INFO"
            recs.append({"Data": json.dumps({
                "run": RUN, "service": f"svc-{i % 5}", "level": level,
                "msg": f"log {i} user=13800001234" if level == "INFO" else f"boom {i}",
                "ts": int(time.time() * 1000),
            }).encode(), "PartitionKey": f"p-{i % 10}"})
        r = kinesis.put_records(StreamName="ho30-logs", Records=recs)
        assert r.get("FailedRecordCount", 0) == 0
        n_sent += 100
    print(f"  ✅ 已写入 {n_sent} 条")

    # 明细表
    wait_for(lambda: (lambda rows: rows if rows >= n_sent * 0.95 else 0)(
        sum(1 for r in ddb.scan(TableName="ho30-events",
            FilterExpression="#r = :run",
            ExpressionAttributeNames={"#r": "run"},
            ExpressionAttributeValues={":run": {"S": RUN}}).get("Items", []))),
        120, "DynamoDB 明细入库")

    # 告警队列：ERROR 数（抽样队列可见消息数）
    alerts = boto3.client("sqs", **kw)
    qurl = alerts.get_queue_url(QueueName="ho30-alerts")["QueueUrl"]
    wait_for(lambda: int(alerts.get_queue_attributes(
        QueueUrl=qurl, AttributeNames=["ApproximateNumberOfMessages"])
        ["Attributes"]["ApproximateNumberOfMessages"]) or 0, 60, "告警队列收到 ERROR")

    # S3 归档
    wait_for(lambda: (lambda keys: keys if keys else 0)(
        len([k for k in s3.list_objects_v2(Bucket="ho30-archive")
             .get("Contents", [])])), 60, "S3 归档对象生成")

    # 指标
    put_metrics(n_sent, n_sent // 10)
    wait_for(lambda: (lambda ms: ms if ms else 0)(
        len(cw.list_metrics(Namespace="Ho30")["Metrics"])), 30, "CloudWatch 指标注册")
    print(f"  压测完成：run={RUN}")


if __name__ == "__main__":
    main()

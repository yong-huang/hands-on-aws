"""ho14 消息可靠性演示：幂等消费 / 毒丸入 DLQ / DLQ 重驱 / FIFO 组内有序。

用法: python3 reliability_demo.py <endpoint> <main_queue> <dlq> <fifo_queue> <dedup_table>
"""
import json
import sys
import time
import uuid

import boto3

ENDPOINT, MAIN, DLQ, FIFO, TABLE = sys.argv[1:6]
REGION = "us-east-1"
kw = dict(endpoint_url=ENDPOINT, region_name=REGION,
          aws_access_key_id="test", aws_secret_access_key="test")
sqs = boto3.client("sqs", **kw)
ddb = boto3.client("dynamodb", **kw)


def ok(m): print(f"  ✅ {m}")
def die(m): print(f"  ❌ {m}"); sys.exit(1)


def url(name):
    return sqs.get_queue_url(QueueName=name)["QueueUrl"]


def receive_one(qurl, vt=1):
    r = sqs.receive_message(QueueUrl=qurl, MaxNumberOfMessages=1, VisibilityTimeout=vt,
                            WaitTimeSeconds=0)
    msgs = r.get("Messages", [])
    return msgs[0] if msgs else None


def handle(msg, *, broken=False):
    """业务处理：毒丸在 broken 消费者手里必然失败（不删除，等重试）；
    幂等键 = SQS messageId（重复投递天然同 id）。返回 processed / duplicate / failed。"""
    mid = msg["MessageId"]
    body = msg["Body"]
    if broken and "poison" in body:
        return "failed"
    seen = ddb.get_item(TableName=TABLE, Key={"message_id": {"S": mid}}).get("Item")
    if seen:
        return "duplicate"
    try:
        ddb.put_item(TableName=TABLE, Item={"message_id": {"S": mid},
                                            "body": {"S": body},
                                            "processed_at": {"S": str(time.time())}})
        return "processed"
    except ddb.exceptions.ConditionalCheckFailedException:
        return "duplicate"


def depth(qurl):
    a = sqs.get_queue_attributes(QueueUrl=qurl,
                                 AttributeNames=["ApproximateNumberOfMessages"])
    return int(a["Attributes"]["ApproximateNumberOfMessages"])


def main():
    u_main, u_dlq, u_fifo = url(MAIN), url(DLQ), url(FIFO)

    # ── 1) 幂等消费：同一消息投递两次，业务只处理一次 ──
    sent = sqs.send_message(QueueUrl=u_main, MessageBody="order-1")["MessageId"]
    m1 = receive_one(u_main, vt=3)
    r1 = handle(m1)                       # 处理成功（写去重表），但不 delete —— 模拟处理后崩溃
    assert r1 == "processed", r1
    time.sleep(4)                         # 可见性超时 → 消息重现（第二次投递）
    m2 = receive_one(u_main, vt=3)
    assert m2 and m2["MessageId"] == sent, "消息应重新可见"
    r2 = handle(m2)                       # 去重表命中 → 跳过
    sqs.delete_message(QueueUrl=u_main, ReceiptHandle=m2["ReceiptHandle"])
    assert r2 == "duplicate", r2
    ok("幂等消费：投递两次、业务只处理一次（第二次识别为 duplicate 并安全跳过）")

    # ── 2) 毒丸 → DLQ：坏消费者连续失败，maxReceiveCount=3 后入死信 ──
    sqs.send_message(QueueUrl=u_main, MessageBody="poison-pill")
    moved = False
    for _ in range(60):
        m = receive_one(u_main, vt=1)     # broken 消费者：收到即失败、不删除
        if m:
            assert handle(m, broken=True) == "failed"
        if depth(u_dlq) >= 1:
            moved = True
            break
        time.sleep(1)
    assert moved, "毒丸未入 DLQ"
    assert depth(u_main) == 0
    ok("毒丸连续失败 3 次 → 自动转入 DLQ（主队列清零）")

    # ── 3) DLQ 重驱：假设 bug 已修复，把死信搬回主队列由健康消费者处理 ──
    while True:
        m = receive_one(u_dlq, vt=2)
        if not m:
            break
        sqs.send_message(QueueUrl=u_main, MessageBody=m["Body"])   # 重驱 = 原样搬回
        sqs.delete_message(QueueUrl=u_dlq, ReceiptHandle=m["ReceiptHandle"])
    m = receive_one(u_main, vt=2)
    assert m and m["Body"] == "poison-pill"
    assert handle(m) == "processed"       # 修复后的消费者处理成功
    sqs.delete_message(QueueUrl=u_main, ReceiptHandle=m["ReceiptHandle"])
    assert depth(u_dlq) == 0 and depth(u_main) == 0
    ok("DLQ 重驱：死信搬回主队列，修复后消费者处理成功，两队列清零")

    # ── 4) FIFO：同组严格有序 ──
    for i, g in [(1, "g1"), (2, "g1"), (3, "g1"), (9, "g2")]:
        sqs.send_message(QueueUrl=u_fifo, MessageBody=f"job-{i}",
                         MessageGroupId=g, MessageDeduplicationId=f"d-{i}")
    seq = []
    while True:
        m = receive_one(u_fifo, vt=2)
        if not m:
            break
        seq.append(int(m["Body"].split("-")[1]))
        sqs.delete_message(QueueUrl=u_fifo, ReceiptHandle=m["ReceiptHandle"])
    g1_in_seq = [x for x in seq if x in (1, 2, 3)]
    assert g1_in_seq == [1, 2, 3], f"g1 顺序破坏: {g1_in_seq}"
    ok("FIFO 组内严格有序: job-1→2→3（跨组并行由 mock 顺序化，真实 AWS 并行）")


if __name__ == "__main__":
    main()

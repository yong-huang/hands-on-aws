"""ho12 Kinesis 核心演示（单进程单遍版）。

实测本机 kinesis-mock 在"反复读同一分片 / 空轮询重试"下会返回空页甚至乱码，
而"建流→写→各迭代器各读一遍"的一次性流程稳定。故整个演示收进一个进程、
每条路径只读一遍，不与其它消费者并发（事件源映射在手动消费完成后才创建）。

用法: python3 kinesis_demo.py <endpoint> <sink_table> <function_name>
"""
import base64
import json
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3

ENDPOINT, SINK_TABLE, FN = sys.argv[1], sys.argv[2], sys.argv[3]
REGION = "us-east-1"
RUN = uuid.uuid4().hex[:8]

kw = dict(endpoint_url=ENDPOINT, region_name=REGION,
          aws_access_key_id="test", aws_secret_access_key="test")
kinesis = boto3.client("kinesis", **kw)
dynamodb = boto3.client("dynamodb", **kw)


def ok(msg):
    print(f"  ✅ {msg}")


def decode_data(data):
    """kinesis-mock 的 Data 字段实测可能是明文 JSON，也可能是（缺填充的）base64，
    按形状自适应解码。"""
    if isinstance(data, str):
        data = data.encode()
    if data.lstrip().startswith(b"{"):
        return data.decode(errors="replace")
    try:
        return base64.b64decode(data + b"=" * (-len(data) % 4)).decode(errors="replace")
    except Exception:
        return data.decode(errors="replace")


def read_once(stream, shard_id, iterator_type, timestamp=None, attempts=8):
    """创建迭代器读完；读到的记录可能要等 mock 内部刷新（实测），
    用"无 sleep 快速重试新迭代器"吸收可见性延迟。"""
    params = dict(StreamName=stream, ShardId=shard_id, ShardIteratorType=iterator_type)
    if timestamp:
        params["Timestamp"] = timestamp
    payloads = []
    for _a in range(attempts):
        it = kinesis.get_shard_iterator(**params)["ShardIterator"]
        payloads = []
        for _page in range(5):   # mock 的 NextShardIterator 可能永不终止：页数设上限
            resp = kinesis.get_records(ShardIterator=it, Limit=1000)
            recs = resp.get("Records", [])
            print(f"  [dbg] RUN={RUN} attempt={_a} page={_page} n={len(recs)} raw={[r['Data'][:24] for r in recs[:2]]}",
                  file=sys.stderr)
            payloads += [decode_data(r["Data"]) for r in recs]
            if not recs:
                break
            it = resp.get("NextShardIterator")
        if payloads:
            return payloads
    return payloads


def main():
    stream = f"ho12-kds-{uuid.uuid4().hex[:8]}"   # 全新名字：删建复用同名会读到脏数据（实测）
    kinesis.create_stream(StreamName=stream, ShardCount=1)
    for _ in range(60):
        st = kinesis.describe_stream_summary(StreamName=stream)["StreamDescriptionSummary"]["StreamStatus"]
        if st == "ACTIVE":
            break
        time.sleep(1)
    ok(f"建流 {stream}（1 分片）")

    # 1) 批量写：两条分区键交错 10 条
    entries = []
    for i in range(5):
        entries.append({"Data": json.dumps({"run": RUN, "sensor": "s1", "seq": i}).encode(),
                        "PartitionKey": "sensor-1"})
        entries.append({"Data": json.dumps({"run": RUN, "sensor": "s2", "seq": i}).encode(),
                        "PartitionKey": "sensor-2"})
    resp = kinesis.put_records(StreamName=stream, Records=entries)
    assert resp.get("FailedRecordCount", 0) == 0, "put_records 有失败记录"
    ok("PutRecords 批量写入 10 条（FailedRecordCount=0）")

    shard = kinesis.list_shards(StreamName=stream)["Shards"][0]["ShardId"]

    def ours(txt):
        try:
            return json.loads(txt).get("run") == RUN
        except Exception:
            return False

    # 2) TRIM_HORIZON：从头读一遍
    payloads = read_once(stream, shard, "TRIM_HORIZON")
    print(f"  [dbg2] payloads={len(payloads)} first={payloads[:1]}", file=sys.stderr)
    mine = [json.loads(p) for p in payloads if ours(p)]
    assert len(mine) == 10, f"TRIM_HORIZON 读到本次 {len(mine)}/10"
    ok("TRIM_HORIZON 消费到全部 10 条（迭代器从头开始）")

    # 3) 分区键顺序
    s1 = [d["seq"] for d in mine if d["sensor"] == "s1"]
    assert s1 == sorted(s1) == [0, 1, 2, 3, 4], f"顺序破坏: {s1}"
    ok("同分区键 sensor-1 严格按序: 0→1→2→3→4（跨分区键交错）")

    # 4) AT_TIMESTAMP 重放
    # 容器时钟可能落后宿主机数小时（实测 OrbStack 漂移），用固定旧时间戳保证"早于所有记录"
    t0 = datetime(2020, 1, 1, tzinfo=timezone.utc)
    replay = read_once(stream, shard, "AT_TIMESTAMP", timestamp=t0)
    mine_replay = [p for p in replay if ours(p)]
    assert len(mine_replay) == 10, f"重放读到 {len(mine_replay)}/10"
    ok("AT_TIMESTAMP 重放历史数据：再次读到 10 条（流可回放，队列做不到）")

    # 5) 事件源映射（手动消费完成后才创建，避免并发消费者触发 mock 缺陷）
    stream_arn = kinesis.describe_stream(StreamName=stream)["StreamDescription"]["StreamARN"]
    lam = boto3.client("lambda", **kw)
    lam.create_event_source_mapping(FunctionName=FN, EventSourceArn=stream_arn,
                                    StartingPosition="LATEST", BatchSize=10)
    time.sleep(2)
    run2 = uuid.uuid4().hex[:8]
    kinesis.put_records(StreamName=stream, Records=[
        {"Data": json.dumps({"run": run2, "auto": i}).encode(), "PartitionKey": "auto"}
        for i in range(3)])
    ok("事件源映射已建立（LATEST），再写 3 条等自动消费落库")
    deadline = time.time() + 90
    n = 0
    while time.time() < deadline:
        rows = dynamodb.scan(TableName=SINK_TABLE).get("Items", [])
        n = sum(1 for r in rows if run2 in r.get("data", {}).get("S", ""))
        if n >= 3:
            break
        time.sleep(2)
    assert n >= 3, f"sink 表本次记录只有 {n} 条"
    ok(f"Lambda 事件源映射自动消费并落库 DynamoDB（本次 {n} 条）")


if __name__ == "__main__":
    main()

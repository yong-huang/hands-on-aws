#!/usr/bin/env python3
"""ho01 对比器：抽取四个栈的 synth 模板，产出 L1/L2/L3 逐项差异对照表。

用法: python3 compare.py <cdk.out 目录> <输出 markdown 路径>
作为 cdk_stack.sh 的 apply 阶段被调用；断言在 shell 脚本里做。
"""
import json
import sys
from pathlib import Path

STACKS = ["ho01-l1-stack", "ho01-l2-stack", "ho01-l2x-stack", "ho01-l3-stack"]


def bucket_like_resources(tpl: dict) -> list[tuple[str, dict]]:
    """返回 (逻辑 ID, 资源定义)，保留模板中原始顺序。"""
    out = []
    for rid, res in tpl.get("Resources", {}).items():
        t = res.get("Type", "")
        if t.startswith("AWS::S3::") or t == "Custom::CDKBucketDeployment":
            out.append((rid, res))
    return out


def prop_count(res: dict) -> int:
    return len(res.get("Properties", {}))


def main() -> None:
    outdir = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    rows = []
    for sid in STACKS:
        tpl_file = outdir / f"{sid}.template.json"
        tpl = json.loads(tpl_file.read_text())
        res = tpl.get("Resources", {})
        # 逻辑 ID 是否带散列：L1 用 CfnBucket 时 ID = 构造路径直译
        hashed = any(rid.endswith("Data") and len(rid) > 4 for rid in res)
        bucket_res = [r for r in bucket_like_resources(tpl)]
        # 桶本体是否带加密配置
        enc = any(
            "ServerSideEncryptionConfiguration" in r.get("Properties", {})
            or "BucketEncryption" in r.get("Properties", {})
            for _, r in bucket_res
            if r.get("Type") == "AWS::S3::Bucket"
        )
        rows.append({
            "stack": sid,
            "resources": len(res),
            "bucket_like": len(bucket_res),
            "max_props": max((prop_count(r) for _, r in bucket_res), default=0),
            "enc_by_default": "✅" if enc else "—",
            "outputs": len(tpl.get("Outputs", {})),
        })

    lines = [
        "| 栈 | 资源总数 | 桶相关资源 | 桶属性注入数 | 默认加密 | 输出 |",
        "|:---|---:|---:|---:|:---:|---:|",
    ]
    for r in rows:
        lines.append(
            f"| {r['stack']} | {r['resources']} | {r['bucket_like']} "
            f"| {r['max_props']} | {r['enc_by_default']} | {r['outputs']} |"
        )
    out_path.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()

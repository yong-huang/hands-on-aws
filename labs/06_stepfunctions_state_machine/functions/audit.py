"""ho06-audit：并行分支 B —— 记审计。"""
def handler(event, context):
    return {"audited": True, "seed": event.get("seed")}

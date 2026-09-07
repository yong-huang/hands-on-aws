"""ho06-notify：并行分支 A —— 发通知。"""
def handler(event, context):
    return {"notified": True, "seed": event.get("seed")}

"""ho18-reserve：扣库存；seed=bad 时失败（触发 Retry 与 Catch）。"""
def handler(event, context):
    if event.get("seed") == "bad":
        raise RuntimeError("inventory conflict")
    return {"reserved": True, "seed": event.get("seed")}

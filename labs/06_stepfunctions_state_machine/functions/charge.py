"""ho06-charge：模拟收款；seed==3 时银行卡被拒（触发状态机 Retry/Catch）。"""
def handler(event, context):
    seed = event.get("seed", 0)
    if seed == 3:
        raise RuntimeError("card declined for seed=3")
    return {"charged": True, "amount": seed * 10}

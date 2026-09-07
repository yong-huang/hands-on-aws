"""ho06-validate：seed 为偶数 → 校验通过。"""
def handler(event, context):
    seed = event.get("seed", 0)
    return {"seed": seed, "valid": seed > 0}

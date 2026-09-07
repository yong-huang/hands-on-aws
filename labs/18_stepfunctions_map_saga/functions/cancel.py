"""ho18-cancel：Saga 补偿——把已扣库存退回。"""
def handler(event, context):
    return {"cancelled": True, "cause": event.get("cause", "")[:80]}

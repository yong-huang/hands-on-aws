"""ho18-ship：Map 的单件任务——发货一件商品。"""
def handler(event, context):
    return {"shipped": event.get("sku"), "qty": event.get("qty", 1)}

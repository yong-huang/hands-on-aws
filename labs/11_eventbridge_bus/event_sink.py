"""ho11 事件接收器：被规则路由到的事件都打印在这里（CloudWatch Logs 可查证）。"""
def handler(event, context):
    src = event.get("source", "?")
    detail = event.get("detail", {})
    print(f"[ho11] event received: source={src} detail={detail}")
    return {"handled": True, "source": src}

"""ho16 app 函数：使用共享层；boom 时抛错（演示异步 OnFailure Destination）。"""
import ho16_lib

def handler(event, context):
    if event.get("boom"):
        raise RuntimeError("boom requested")
    return {"greeting": ho16_lib.greet(event.get("name", "world"))}

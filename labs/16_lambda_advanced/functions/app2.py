"""ho16 app2：第二个函数，共享同一层。"""
import ho16_lib

def handler(event, context):
    return {"greeting2": ho16_lib.greet(event.get("name", "world"))}

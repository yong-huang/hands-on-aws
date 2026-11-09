import json


def handler(event, context):
    # 来自资产包的函数：证明 zip 资产上传 → staging 桶 → Lambda 可用
    return {"from": "ho09 asset", "ok": True}

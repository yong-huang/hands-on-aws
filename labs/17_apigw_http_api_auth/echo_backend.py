"""ho17 后端：回显请求关键信息（authorizer 上下文会出现在 event.requestContext.authorizer）。"""
def resolve():
    import os
    lsh = os.environ.get("LOCALSTACK_HOSTNAME") or os.environ.get("LOCALSTACK_HOST")
    if lsh:
        return f"http://{lsh}" if ":" in lsh else f"http://{lsh}:4566"
    return os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")

def handler(event, context):
    rc = event.get("requestContext", {})
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": __import__("json").dumps({
            "ok": True,
            "path": event.get("path"),
            "authorizer": rc.get("authorizer", {}),
            "identity": (rc.get("identity") or {}).get("apiKey", ""),
        }),
    }

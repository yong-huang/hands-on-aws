"""ho17 Token Authorizer：Authorization 头为 allow-me 时放行，否则拒绝。"""
import json

def handler(event, context):
    token = event.get("authorizationToken", "")
    if token == "allow-me":
        return {
            "principalId": "user-bob",
            "policyDocument": {
                "Version": "2012-10-17",
                "Statement": [{
                    "Action": "execute-api:Invoke",
                    "Effect": "Allow",
                    "Resource": event.get("methodArn", "*"),
                }],
            },
            "context": {"team": "platform"},
        }
    raise Exception("Unauthorized")   # 网关约定：抛 Unauthorized => 401

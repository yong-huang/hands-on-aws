#!/usr/bin/env bash
# 清理 RETAIN 资产（prod destroy 后表/桶脱离栈管理，须显式收尾——cdk/05 机制）
set -euo pipefail
ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
export AWS_PAGER="" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
ENV_NAME="${1:-prod}"

aws --endpoint-url "$ENDPOINT" dynamodb delete-table \
    --table-name "ho11-${ENV_NAME}-orders" >/dev/null 2>&1 || true

python3 - "$ENV_NAME" <<'PYEOF' >/dev/null 2>&1 || true
import boto3, os, sys
env_name = sys.argv[1]
s3 = boto3.client("s3", endpoint_url=os.environ.get("AWS_ENDPOINT", "http://localhost:4566"),
                  region_name="us-east-1")
bucket = f"ho11-{env_name}-archive"
try:
    resp = s3.list_object_versions(Bucket=bucket)
except Exception:
    resp = None
if resp:
    for v in resp.get("Versions", []) + resp.get("DeleteMarkers", []):
        try:
            s3.delete_object(Bucket=bucket, Key=v["Key"], VersionId=v["VersionId"])
        except Exception:
            pass
    try:
        s3.delete_bucket(Bucket=bucket)
    except Exception:
        pass
PYEOF

echo "✅ RETAIN 资产已显式清理（ho11-${ENV_NAME}-orders / ho11-${ENV_NAME}-archive）"

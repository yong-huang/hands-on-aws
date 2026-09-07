# 构建进度（内部跟踪，收稿时可删）

图管线命令备忘：
- `ARCHIFY=~/.agents/skills/archify`
- validate: `node $ARCHIFY/bin/archify.mjs validate <type> <json> --quality showcase --json`
- deliver:  `node $ARCHIFY/bin/archify.mjs deliver <type> <json> <html> --quality showcase --json`
- visual:   `node $ARCHIFY/bin/archify.mjs visual-check <html> --json`
- 批量导 SVG: `node ~/.agents/skills/hands-on-series/scripts/export-batch.mjs '[["abs.html","abs.svg"],...]'`
- 居中: `node ~/.agents/skills/hands-on-series/scripts/pixel-center.mjs <svg>`（有 c-bg-rect 必须用它）
- python3 = anaconda（已装 boto3/requests/cryptography）

环境事实（2026-09-06 实测）：
- LocalStack 容器名 `localstack-main`（OrbStack docker context），4566 健康
- Lambda 运行时镜像 public.ecr.aws/lambda/python:3.12 已预载；容器挂了 docker.sock
- aws CLI 2.34.11；terraform 有；cdklocal/samlocal 未装（lab 28/29 前再装）
- awslocal 只是 shell alias（无二进制），脚本一律用 aws --endpoint-url

| Lab | 脚本跑通 | README | 图 |
|-----|---------|--------|----|
| 01 s3_object_storage        | ✅ | ✅ | ✅ |
| 02 dynamodb_keyvalue        | ✅ | ✅ | ✅ |
| 03 sqs_sns_messaging        | ✅ | ✅ | ✅ |
| 04 lambda_events            | ✅ | ✅ | ✅ |
| 05 apigw_lambda_rest        | ✅ | ✅ | ✅ |
| 06 stepfunctions_state_machine | ✅ | ✅ | ✅ |
| 07 kms_secrets_manager      | ✅ | ✅ | ✅ |
| 08 iam_sts                  | ✅ | ✅ | ✅ |
| 09 terraform_cloudformation | ✅ | ✅ | ✅ |
| 10 serverless_order_pipeline| ✅ | ✅ | ✅ |
| 11 eventbridge_bus          | ✅ | ✅ | ✅ |
| 12 kinesis_streams          | ✅ | ✅ | ✅ |
| 13 s3_event_notifications   | ✅ | ✅ | ✅ |
| 14 message_reliability      | ✅ | ✅ | ✅ |
| 15 dynamodb_advanced        | ✅ | ✅ | ✅ |
| 16 lambda_advanced          | ✅ | ✅ | ✅ |
| 17 apigw_http_api_auth      | ✅ | ✅ | ✅ |
| 18 stepfunctions_map_saga   | ✅ | ✅ | ✅ |
| 19 s3_website_fullstack     | ✅ | ✅ | ✅ |
| 20 ssm_parameter_store      | ✅ | ✅ | ✅ |
| 21 cloudwatch_logs          | ✅ | ✅ | ✅ |
| 22 cloudwatch_alarms        | ✅ | ✅ | ✅ |
| 23 secrets_rotation         | ✅ | ✅ | ✅ |
| 24 encryption_pipeline      | ✅ | ✅ | ✅ |
| 25 cloudtrail_audit         | ✅ | ✅ | ✅ |
| 26 cloudformation_advanced  | ✅ | ✅ | ✅ |
| 27 terraform_engineering    | ✅ | ✅ | ✅ |
| 28 cdk_stack                | ✅ | ✅ | ✅ |
| 29 sam_serverless           | ✅ | ✅ | ✅ |
| 30 log_analytics_platform   | ✅ | ✅ | ✅ |

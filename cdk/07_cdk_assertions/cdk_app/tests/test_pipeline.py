"""ho07 green 套件：对 cdk/02 构造库的 fine-grained 合成期断言（不触云）。"""
import sys
from pathlib import Path

import pytest
from aws_cdk import App, Stack, assertions as asserts
from aws_cdk.assertions import Match, Template

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.order_pipeline import AlphaStack  # noqa: E402


@pytest.fixture(scope="module")
def tpl() -> Template:
    app = App()
    AlphaStack(app, "ho07-alpha-stack")
    return Template.from_stack(app.node.children[0])


# ------------------------------------------------- 资源形态
def test_bucket_encrypted_by_default(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::S3::Bucket",
        {"BucketEncryption": {"ServerSideEncryptionConfiguration": Match.any_value()}})


def test_bucket_encryption_algorithm_aes256(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::S3::Bucket",
        {"BucketEncryption": {"ServerSideEncryptionConfiguration": [
            {"ServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}})


def test_queue_has_dlq_and_visibility(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::SQS::Queue",
        Match.object_like({
            "VisibilityTimeout": 30,
            "RedrivePolicy": Match.object_like({"maxReceiveCount": 3}),
        }))


def test_dlq_exists(tpl: Template) -> None:
    tpl.has_resource_properties("AWS::SQS::Queue", {"QueueName": "ho02-alpha-dlq"})


def test_table_partition_key(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::DynamoDB::Table",
        {"KeySchema": [{"AttributeName": "order_id", "KeyType": "HASH"}]})


def test_lambda_runtime_python312(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::Lambda::Function",
        {"Runtime": "python3.12", "Handler": "orders.handler"})


def test_lambda_env_table_name_ref(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::Lambda::Function",
        {"Environment": {"Variables": {"TABLE_NAME": Match.any_value()}}})


def test_event_source_mapping_wired(tpl: Template) -> None:
    # BatchSize 默认 10 时 CDK 省略该字段——默认值不进模板也是一条知识
    tpl.has_resource_properties(
        "AWS::Lambda::EventSourceMapping",
        {"EventSourceArn": Match.any_value()})


# ------------------------------------------------- 数量与反面
def test_resource_counts(tpl: Template) -> None:
    tpl.resource_count_is("AWS::S3::Bucket", 1)
    tpl.resource_count_is("AWS::SQS::Queue", 2)          # 主队列 + DLQ
    tpl.resource_count_is("AWS::DynamoDB::Table", 1)
    tpl.resource_count_is("AWS::Lambda::Function", 1)
    tpl.resource_count_is("AWS::Lambda::EventSourceMapping", 1)


def test_no_unencrypted_bucket(tpl: Template) -> None:
    # 反面断言：不存在不带 BucketEncryption 的桶
    tpl.resource_properties_count_is("AWS::S3::Bucket", {"BucketEncryption": Match.absent()}, 0)


def test_export_present(tpl: Template) -> None:
    outs = tpl.to_json().get("Outputs", {})
    assert any(k.startswith("ExportsOutput") for k in outs), \
        f"应有跨栈导出输出，实际: {list(outs)}"


def test_all_queues_removal_destroy(tpl: Template) -> None:
    queues = tpl.find_resources("AWS::SQS::Queue")
    for rid, res in queues.items():
        assert res.get("DeletionPolicy") == "Delete", f"{rid} 应随栈删除"

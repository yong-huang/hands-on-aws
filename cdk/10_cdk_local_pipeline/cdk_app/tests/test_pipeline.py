"""ho10 test 阶段：对"与部署完全同一份 App"跑断言套件。

HO40_INJECT=no_encryption 时，本套件合成出的就是坏产品——
test_no_unencrypted_bucket 必须抓红，流水线在 test 阶段中止。
"""
import sys
from pathlib import Path

import pytest
from aws_cdk import App
from aws_cdk.assertions import Match, Template

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as app_mod  # noqa: E402


@pytest.fixture(scope="module")
def tpl() -> Template:
    app = App()
    stack = app_mod.Ho40Stack(app, "ho10-test-stack")
    return Template.from_stack(stack)


# ------------------------------------------------- 资源形态
def test_bucket_encrypted_by_default(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::S3::Bucket",
        {"BucketEncryption": {"ServerSideEncryptionConfiguration": Match.any_value()}})


def test_queue_has_dlq_and_visibility(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::SQS::Queue",
        Match.object_like({
            "VisibilityTimeout": 30,
            "RedrivePolicy": Match.object_like({"maxReceiveCount": 3}),
        }))


def test_table_partition_key(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::DynamoDB::Table",
        {"KeySchema": [{"AttributeName": "order_id", "KeyType": "HASH"}]})


def test_lambda_runtime_python312(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::Lambda::Function",
        {"Runtime": "python3.12", "Handler": "orders.handler"})


def test_event_source_mapping_wired(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::Lambda::EventSourceMapping",
        {"EventSourceArn": Match.any_value()})


# ------------------------------------------------- 数量与反面
def test_resource_counts(tpl: Template) -> None:
    tpl.resource_count_is("AWS::S3::Bucket", 1)
    tpl.resource_count_is("AWS::SQS::Queue", 2)
    tpl.resource_count_is("AWS::DynamoDB::Table", 1)
    tpl.resource_count_is("AWS::Lambda::Function", 1)


def test_no_unencrypted_bucket(tpl: Template) -> None:
    tpl.resource_properties_count_is(
        "AWS::S3::Bucket", {"BucketEncryption": Match.absent()}, 0)


def test_no_wildcard_iam(tpl: Template) -> None:
    for res in tpl.to_json()["Resources"].values():
        doc = res.get("Properties", {}).get("PolicyDocument")
        if doc:
            sts = doc.get("Statement", [])
            sts = sts if isinstance(sts, list) else [sts]
            for st in sts:
                acts = st.get("Action", [])
                acts = acts if isinstance(acts, list) else [acts]
                assert "*" not in acts, "不应出现通配 Action"

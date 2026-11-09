"""ho11 平台断言套件：dev/prod 双环境模板的关键性质（cdk/07 机制）。

CDK_CONTEXT 控制环境：默认合成 dev；pytest 通过 env 设 CDK_CONTEXT 分别断言。
"""
import json
import os
import sys
from pathlib import Path

import pytest
from aws_cdk import App
from aws_cdk.assertions import Match, Template

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

ENV = os.environ.get("HO41_ENV", "dev")


@pytest.fixture(scope="module")
def tpl() -> Template:
    app = App(context={"env": ENV})
    import app as app_mod
    stack = app_mod.OrderPlatformStack(app, f"ho11-{ENV}-test")
    # Aspect 在 app.py 模块级只对它自己的栈跑过；测试栈需手动跑合规
    compliance = app_mod.ComplianceAspect()
    tagger = app_mod.TaggingAspect(ENV)
    for node in stack.node.find_all():
        tagger.visit(node)
        compliance.visit(node)
    assert not compliance.violations, compliance.violations
    return Template.from_stack(stack)


def test_bucket_encrypted(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::S3::Bucket",
        {"BucketEncryption": {"ServerSideEncryptionConfiguration": Match.any_value()}})


def test_queue_dlq_wired(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::SQS::Queue",
        Match.object_like({"RedrivePolicy": Match.object_like({"maxReceiveCount": 3})}))


def test_processor_event_source(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::Lambda::EventSourceMapping",
        {"EventSourceArn": Match.any_value()})


def test_api_routes_count(tpl: Template) -> None:
    tpl.resource_count_is("AWS::ApiGateway::Method", 2)   # POST /orders + GET /orders/{id}


def test_api_proxy_integrations(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::ApiGateway::Method",
        Match.object_like({"Integration": Match.object_like(
            {"Type": "AWS_PROXY", "IntegrationHttpMethod": "POST"})}))


def test_stage_v1(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::ApiGateway::Stage", {"StageName": "v1"})


def test_cr_seeder_present(tpl: Template) -> None:
    tpl.resource_count_is("Custom::Ho41Seeder", 1)


def test_lambda_invoke_permission(tpl: Template) -> None:
    tpl.has_resource_properties(
        "AWS::Lambda::Permission",
        {"Principal": "apigateway.amazonaws.com", "Action": "lambda:InvokeFunction"})


def test_all_resources_tagged(tpl: Template) -> None:
    # Aspect 治理：每个可打标资源都带 platform=ho11
    def has_tag(props: dict) -> bool:
        tags = props.get("Tags")
        if not tags:
            return False
        tags = tags if isinstance(tags, list) else [tags]
        for t in tags:
            t = t if isinstance(t, dict) else {}
            if t.get("Key") == "platform" and t.get("Value") == "ho11":
                return True
        return False
    taggable_types = {"AWS::S3::Bucket", "AWS::SQS::Queue", "AWS::DynamoDB::Table",
                      "AWS::Lambda::Function"}
    for rid, res in tpl.to_json()["Resources"].items():
        if res.get("Type") in taggable_types:
            assert has_tag(res.get("Properties", {})), f"{rid} 缺 platform 标签"


if ENV == "prod":
    def test_prod_retain_and_versioning(tpl: Template) -> None:
        data = tpl.to_json()
        table = [r for r in data["Resources"].values()
                 if r["Type"] == "AWS::DynamoDB::Table"][0]
        bucket = [r for r in data["Resources"].values()
                  if r["Type"] == "AWS::S3::Bucket"][0]
        assert table.get("DeletionPolicy") == "Retain"
        assert bucket.get("DeletionPolicy") == "Retain"
        assert "VersioningConfiguration" in bucket["Properties"]

    def test_prod_provisioned_billing(tpl: Template) -> None:
        tpl.has_resource_properties(
            "AWS::DynamoDB::Table",
            {"ProvisionedThroughput": {"ReadCapacityUnits": 5,
                                       "WriteCapacityUnits": 5}})
else:
    def test_dev_no_retain(tpl: Template) -> None:
        data = tpl.to_json()
        table = [r for r in data["Resources"].values()
                 if r["Type"] == "AWS::DynamoDB::Table"][0]
        assert table.get("DeletionPolicy", "Delete") != "Retain"

"""ho07 red 套件：对注入错误配置的构造跑正确断言——应当抓红（pytest 退出码非零）。

HO37_BREAK=no_encryption → 桶不带加密 → test_bucket_encrypted_by_default 抓红
HO37_BREAK=bad_runtime   → runtime 变 nodejs20 → test_lambda_runtime_python312 抓红
两种模式各跑一轮，证明断言不是"永远绿"的摆设：错误配置真的会被抓住。
"""
import os
import sys
from pathlib import Path

import pytest
from aws_cdk import App, Stack
from aws_cdk.assertions import Match, Template

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.order_pipeline import OrderPipelineConstruct, OrderPipelineProps  # noqa: E402

BREAK = os.environ.get("HO37_BREAK", "no_encryption")


@pytest.fixture(scope="module")
def broken_tpl() -> Template:
    class BrokenStack(Stack):
        def __init__(self, scope, cid, **kw):
            super().__init__(scope, cid, **kw)
            OrderPipelineConstruct(
                self, "Pipeline",
                OrderPipelineProps(pipeline_name="alpha", inject=BREAK))

    app = App()
    BrokenStack(app, "ho07-broken-stack")
    return Template.from_stack(app.node.children[0])


@pytest.mark.skipif(BREAK != "no_encryption", reason="本模式只验加密抓红")
def test_bucket_encrypted_by_default(broken_tpl: Template) -> None:
    broken_tpl.has_resource_properties(
        "AWS::S3::Bucket",
        {"BucketEncryption": {"ServerSideEncryptionConfiguration": Match.any_value()}})


@pytest.mark.skipif(BREAK != "bad_runtime", reason="本模式只验 runtime 抓红")
def test_lambda_runtime_python312(broken_tpl: Template) -> None:
    broken_tpl.has_resource_properties(
        "AWS::Lambda::Function", {"Runtime": "python3.12"})

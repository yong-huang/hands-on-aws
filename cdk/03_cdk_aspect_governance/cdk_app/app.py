"""ho03 Aspect 治理：标签强制 + 合规拦截（未加密桶 / 通配 IAM / L1 绕过）。

用法（cdklocal）：
  synth -c mode=good           → 合规栈，通过；deploy 后逐资源断言标签
  synth -c mode=bad            → 违规栈，合成期拦截：一次性列出全部违规、退出码非零
  synth -c mode=bad -c fix=1   → "修复后"：同一套栈代码改走合规分支，通过并可部署
"""
import sys

import aws_cdk as cdk
from aws_cdk import (
    IAspect,
    ITaggable,
    Stack,
    aws_iam as iam,
    aws_s3 as s3,
)
from constructs import Construct, IConstruct

REGION = "us-east-1"
ACCOUNT = "000000000000"


# ------------------------------------------------------------------ Aspect
class TaggingAspect(IAspect):
    """访问者：给每个可打标资源盖上团队标签（手写 IAspect，等价 Tags.of 的底层）。"""

    def __init__(self, owner: str) -> None:
        self.owner = owner
        self.tagged = 0

    def visit(self, node: IConstruct) -> None:
        # ITaggable 是非 runtime_checkable 的 Protocol，isinstance 会炸——
        # 用鸭子类型判定（有 tags.set_tag 能力即可打标，Stack/CfnBucket 亦真）
        if hasattr(node, "tags") and callable(getattr(node.tags, "set_tag", None)):
            node.tags.set_tag("owner", self.owner)
            node.tags.set_tag("lab", "ho03")
            self.tagged += 1


class ComplianceAspect(IAspect):
    """访问者：累积违规，一次抛出——L2 未加密、通配 IAM、L1 绕过加密。"""

    def __init__(self) -> None:
        self.violations: list[str] = []

    def visit(self, node) -> None:
        # 1) 桶加密检查：统一看 L1 子资源的 SSE 配置——L2 未加密与 L1 绕过
        #    都是"CfnBucket 无 server_side_encryption_configuration"这一终态
        if isinstance(node, s3.CfnBucket) and node.bucket_encryption is None:
            kind = "L2" if isinstance(node.node.scope, s3.Bucket) else "L1-绕过"
            self.violations.append(f"[{kind}] 桶无加密配置: {node.node.path}")
        # 3) 通配 IAM 策略语句（PolicyDocument 不暴露语句列表，用 to_json 扫描）
        if isinstance(node, iam.Policy):
            doc = node.document.to_json()
            for st in doc.get("Statement", []):
                acts = st.get("Action", [])
                res = st.get("Resource", [])
                acts = acts if isinstance(acts, list) else [acts]
                res = res if isinstance(res, list) else [res]
                if "*" in acts or "*" in res:
                    self.violations.append(
                        f"[IAM] 通配授权: {node.node.path} (actions={acts}, resources={res})")

    def report_or_none(self) -> None:
        if not self.violations:
            return
        print(f"❌ 合规拦截：{len(self.violations)} 条违规，一次性列出：",
              file=sys.stderr)
        for v in self.violations:
            print(f"   - {v}", file=sys.stderr)
        sys.exit(1)


# ------------------------------------------------------------------ Stacks
class GoodStack(Stack):
    """合规样板：L2 桶加密 + 精确授权。"""

    def __init__(self, scope: Construct, cid: str, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        bucket = s3.Bucket(
            self, "GoodBucket", bucket_name="ho03-good-bucket",
            encryption=s3.BucketEncryption.S3_MANAGED,
            removal_policy=cdk.RemovalPolicy.DESTROY)
        user = iam.User(self, "Reader")
        iam.Policy(
            self, "ScopedPolicy",
            users=[user],
            statements=[iam.PolicyStatement(
                actions=["s3:GetObject"],
                resources=[bucket.bucket_arn + "/*"])])
        cdk.CfnOutput(self, "BucketName", value=bucket.bucket_name)


class BadStack(Stack):
    """违规样例：L2 未加密 + 通配授权 + L1 裸桶绕过。fix=1 时同构修复。"""

    def __init__(self, scope: Construct, cid: str, *, fix: bool, **kwargs) -> None:
        super().__init__(scope, cid, **kwargs)
        bucket = s3.Bucket(
            self, "BadBucket", bucket_name="ho03-bad-bucket",
            encryption=(s3.BucketEncryption.S3_MANAGED if fix
                        else s3.BucketEncryption.UNENCRYPTED),
            removal_policy=cdk.RemovalPolicy.DESTROY)
        # L1 裸桶：fix 时显式声明加密（L1 的"修复"就是把模板字段写全）
        raw_args = dict(bucket_name="ho03-bad-raw")
        if fix:
            # 注意：L1 的 python kwarg 走 jsii struct（camelCase），不是模板 PascalCase
            raw_args["bucket_encryption"] = {
                "serverSideEncryptionConfiguration": [
                    {"serverSideEncryptionByDefault": {"sseAlgorithm": "AES256"}}]}
        raw = s3.CfnBucket(self, "RawBucket", **raw_args)
        user = iam.User(self, "Operator")
        actions = ["s3:GetObject"] if fix else ["s3:*"]
        resources = [bucket.bucket_arn + "/*"] if fix else ["*"]
        iam.Policy(
            self, "WildcardPolicy",
            users=[user],
            statements=[iam.PolicyStatement(actions=actions, resources=resources)])
        cdk.CfnOutput(self, "BucketName", value=bucket.bucket_name)


# ------------------------------------------------------------------ App
app = cdk.App()
mode = app.node.try_get_context("mode") or "good"
fix = bool(app.node.try_get_context("fix"))

if mode == "good":
    app_stack = GoodStack(app, "ho03-good-stack",
                          env=cdk.Environment(account=ACCOUNT, region=REGION))
elif mode == "bad":
    app_stack = BadStack(app, "ho03-bad-stack", fix=fix,
                         env=cdk.Environment(account=ACCOUNT, region=REGION))
else:
    sys.exit(f"未知 mode={mode}（可选 good|bad）")

# Aspect 应用：官方形式是 Aspects.of(stack).add(aspect)，但本环境（Python 3.13 +
# jsii 1.14x + aws-cdk-lib 2.26x）实测触发 jsii 序列化 bug——python 实现的 aspect
# 对象进不了内核 JSON（连 @jsii.implements 也无效，见 aws/jsii#576）。改用等价的
# findAll + visit 手动应用——这正是 Aspects.of 的内部实现，visit 语义完全一致。
def apply_aspects(stack: Stack, *aspects: IAspect) -> None:
    for node in stack.node.find_all():
        for a in aspects:
            a.visit(node)

tagger = TaggingAspect(owner="platform-team")
compliance = ComplianceAspect()
apply_aspects(app_stack, tagger, compliance)

app.synth()
compliance.report_or_none()   # 有违规在此一次性列出并 exit(1)
print(f"合成通过：打标 {tagger.tagged} 个资源，合规 0 违规")

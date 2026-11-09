# =============================================================================
# 10 · 本地 CI 流水线 —— CDK Pipelines 阶段语义的 make 实现
#
# make pipeline = synth → test → diff-review → deploy → smoke → destroy
#   （任一阶段失败即中止，退出码非零；KEEP=1 跳过 destroy 留栈观察）
#
# 阶段语义对照（CDK Pipelines → 本流水线）：
#   Source/Build          → synth（合成 + 资产检查）
#   （额外质量门）        → test（cdk/07 断言套件，合成期拦截错误配置）
#   （人工审批关卡）      → diff-review（已部署时 diff 非空即拦，APPROVED=1 显式放行）
#   Stages(deploy)        → deploy
#   （发布后验证）        → smoke（SQS→Lambda→DDB 端到端）
#   （清理）              → destroy（KEEP=1 可跳过）
#
# 注入验收：HO40_INJECT=no_encryption make pipeline → 应死在 test，不见 deploy
# =============================================================================
ENDPOINT ?= http://localhost:4566
STACK := ho10-stack
QUEUE_URL := $(ENDPOINT)/000000000000/ho02-alpha-orders-queue
TABLE := ho02-alpha-orders
CDK := cd cdk_app && cdklocal
export AWS_PAGER :=
export AWS_ACCESS_KEY_ID := test
export AWS_SECRET_ACCESS_KEY := test
export AWS_DEFAULT_REGION := us-east-1
export NO_PROXY := localhost,127.0.0.1
export no_proxy := localhost,127.0.0.1

.PHONY: pipeline synth test diff-review deploy smoke destroy

pipeline: synth test diff-review deploy smoke
ifeq ($(KEEP),1)
	@echo "=====> [destroy] KEEP=1 跳过（栈保留供观察）"
else
	$(MAKE) destroy
endif
	@echo "🎉 ho10 流水线完成"

synth:
	@echo "=====> [synth] 合成 + 产物存在性检查"
	@cd cdk_app && cdklocal synth > /dev/null
	@test -f cdk_app/cdk.out/ho10-stack.template.json || (echo "❌ 模板缺失" && exit 1)
	@echo "  ✅ 模板已合成（$$(wc -c < cdk_app/cdk.out/ho10-stack.template.json | tr -d ' ') bytes）"

test:
	@echo "=====> [test] cdk/07 断言套件（合成期质量门）"
	@cd cdk_app && python3 -m pytest tests/test_pipeline.py -q 2>&1 | tail -1
	@cd cdk_app && python3 -m pytest tests/test_pipeline.py -q > /dev/null 2>&1 || \
		(echo "  ❌ test 阶段拦截：断言未全绿——流水线在此中止，deploy 不会发生" && exit 1)
	@echo "  ✅ 12 条断言全绿"

diff-review:
	@echo "=====> [diff-review] 变更审查门"
	@if ! aws --endpoint-url $(ENDPOINT) cloudformation describe-stacks --stack-name $(STACK) >/dev/null 2>&1; then \
		echo "  ⚠️  栈未部署：diff 为全量创建清单（首部署自动放行，无人工关卡可用）"; \
		echo "  ✅ diff 审查通过（首次部署）"; \
	else \
		changes=$$($(CDK) diff $(STACK) 2>&1 | grep -cE '^\[[-+~]\]' || true); \
		if [ "$$changes" != "0" ] && [ "$(APPROVED)" != "1" ]; then \
			echo "  ❌ diff 非空（$$changes 处变更）且未获批准（APPROVED=1 放行）"; \
			$(CDK) diff $(STACK) 2>&1 | grep -E '^\[[-+~]\]' | head -5; \
			exit 1; \
		fi; \
		echo "  ✅ diff 审查通过（$$changes 处变更）"; \
	fi

deploy:
	@echo "=====> [deploy] cdklocal deploy"
	@$(CDK) deploy $(STACK) --require-approval never 2>&1 | grep -E '✅' | tail -1
	@echo "  ✅ 部署完成"

smoke:
	@echo "=====> [smoke] 发布后验证：SQS → Lambda → DDB 端到端"
	@aws --endpoint-url $(ENDPOINT) sqs send-message --queue-url "$(QUEUE_URL)" \
		--message-body '{"order_id":"SMOKE-1","amount":99}' > /dev/null
	@n=0; \
	for i in $$(seq 1 15); do \
		n=$$(aws --endpoint-url $(ENDPOINT) dynamodb scan --table-name $(TABLE) \
			--filter-expression 'order_id = :o' \
			--expression-attribute-values '{":o":{"S":"SMOKE-1"}}' \
			--query 'Count' --output text 2>/dev/null || echo 0); \
		[ "$$n" = "1" ] && break; sleep 2; \
	done; \
	[ "$$n" = "1" ] || (echo "  ❌ smoke 失败：SMOKE-1 未落表" && exit 1)
	@echo "  ✅ SMOKE-1 端到端落表"

destroy:
	@echo "=====> [destroy] 清栈"
	@$(CDK) destroy $(STACK) --force > /dev/null 2>&1 || true
	@aws --endpoint-url $(ENDPOINT) sqs get-queue-url --queue-name ho02-alpha-orders-queue >/dev/null 2>&1 \
		&& (echo "  ❌ 队列残留" && exit 1) || echo "  ✅ 无残留"

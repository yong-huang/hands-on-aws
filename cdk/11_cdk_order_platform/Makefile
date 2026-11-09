# =============================================================================
# 11 · 🏁 综合实战 —— 订单平台全栈工程化交付
#
# make deploy APP_ENV=prod    → test（双环境断言）→ deploy → smoke（API 端到端）
# make destroy APP_ENV=prod   → 清栈 + RETAIN 资产显式收尾 + 零残留探查
# make pipeline APP_ENV=prod  → deploy + smoke（不 destroy，平台保持在线）
#
# 整合：构造库组装 · Aspect 治理 · 双环境 · CR 种子 · 断言测试 · 流水线交付
# =============================================================================
APP_ENV ?= dev
ENDPOINT ?= http://localhost:4566
STACK := ho11-$(APP_ENV)-stack
API_URL := $(shell aws --endpoint-url $(ENDPOINT) cloudformation describe-stacks \
	--stack-name $(STACK) --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' \
	--output text 2>/dev/null)
export AWS_PAGER :=
export AWS_ACCESS_KEY_ID := test
export AWS_SECRET_ACCESS_KEY := test
export AWS_DEFAULT_REGION := us-east-1
export NO_PROXY := localhost,127.0.0.1,.localhost.localstack.cloud
export no_proxy := localhost,127.0.0.1,.localhost.localstack.cloud
export AWS_ENDPOINT := $(ENDPOINT)

.PHONY: test deploy smoke destroy pipeline

test:
	@echo "=====> [test] 双环境断言（dev + prod 共 21 条）"
	@cd cdk_app && python3 -m pytest test_platform.py -q > /dev/null 2>&1 || \
		(cd cdk_app && python3 -m pytest test_platform.py -q 2>&1 | tail -5; exit 1)
	@cd cdk_app && HO41_ENV=prod python3 -m pytest test_platform.py -q > /dev/null 2>&1 || \
		(cd cdk_app && HO41_ENV=prod python3 -m pytest test_platform.py -q 2>&1 | tail -5; exit 1)
	@echo "  ✅ dev 10 条 + prod 11 条全绿"

deploy: test
	@echo "=====> [deploy] APP_ENV=$(APP_ENV)（先清栈重建：本版 LocalStack 对 Output 级变更的 diff 有盲区）"
	@aws --endpoint-url $(ENDPOINT) cloudformation delete-stack --stack-name $(STACK) >/dev/null 2>&1 || true
	@aws --endpoint-url $(ENDPOINT) cloudformation wait stack-delete-complete --stack-name $(STACK) >/dev/null 2>&1 || true
	@bash scripts/purge_retained.sh $(APP_ENV)   # RETAIN 资产随栈保留，重建前必须显式收尾
	@cd cdk_app && cdklocal deploy "ho11-$(APP_ENV)-stack" -c env=$(APP_ENV) \
		--require-approval never 2>&1 | grep -E '✅' | tail -1
	@echo "  ✅ 平台已部署"

smoke: deploy
	@echo "=====> [smoke] API 端到端（POST → 队列 → 处理 → GET）"
	@api_id=$$(aws --endpoint-url $(ENDPOINT) apigateway get-rest-apis \
		--query 'items[?name==`ho11-$(APP_ENV)-api`].id' --output text | awk '{print $$NF}'); \
	api_url="http://$${api_id}.execute-api.us-east-1.localhost.localstack.cloud:4566/v1"; \
	code=$$(curl -s -o /tmp/ho11_post.json -w '%{http_code}' -X POST \
		"$$api_url/orders" -H 'content-type: application/json' \
		-d '{"order_id":"ORD-SMOKE-1","amount":99}'); \
	[ "$$code" = "201" ] || { echo "  ❌ POST 返回 $$code: $$(cat /tmp/ho11_post.json)"; exit 1; }; \
	echo "  ✅ POST /orders → 201"; \
	n=0; \
	for i in $$(seq 1 15); do \
		n=$$(aws --endpoint-url $(ENDPOINT) dynamodb get-item --table-name "ho11-$(APP_ENV)-orders" \
			--key '{"sk":{"S":"ORD-SMOKE-1"}}' --query 'Item.status.S' --output text 2>/dev/null); \
		[ "$$n" = "PROCESSED" ] && break; sleep 2; \
	done; \
	[ "$$n" = "PROCESSED" ] || { echo "  ❌ 订单未处理（status=$$n）"; exit 1; }; \
	echo "  ✅ 队列消费落表（status=PROCESSED）"; \
	code=$$(curl -s -o /tmp/ho11_get.json -w '%{http_code}' \
		"$$api_url/orders/ORD-SMOKE-1"); \
	[ "$$code" = "200" ] || { echo "  ❌ GET 返回 $$code"; exit 1; }; \
	grep -q 'PROCESSED' /tmp/ho11_get.json && echo "  ✅ GET /orders/ORD-SMOKE-1 → 200 PROCESSED"

destroy:
	@echo "=====> [destroy] APP_ENV=$(APP_ENV) 清栈 + RETAIN 收尾"
	@cd cdk_app && cdklocal destroy "ho11-$(APP_ENV)-stack" -c env=$(APP_ENV) \
		--force > /dev/null 2>&1 || true
	@bash scripts/purge_retained.sh $(APP_ENV)
	@aws --endpoint-url $(ENDPOINT) cloudformation describe-stacks --stack-name $(STACK) >/dev/null 2>&1 \
		&& (echo "  ❌ 栈残留" && exit 1) || echo "  ✅ 栈已删除"
	@aws --endpoint-url $(ENDPOINT) dynamodb describe-table --table-name "ho11-$(APP_ENV)-orders" >/dev/null 2>&1 \
		&& (echo "  ❌ 表残留" && exit 1) || echo "  ✅ 表已清理"
	@aws --endpoint-url $(ENDPOINT) s3api head-bucket --bucket "ho11-$(APP_ENV)-archive" >/dev/null 2>&1 \
		&& (echo "  ❌ 桶残留" && exit 1) || echo "  ✅ 桶已清理"
	@aws --endpoint-url $(ENDPOINT) lambda get-function --function-name "ho11-$(APP_ENV)-order-api" >/dev/null 2>&1 \
		&& (echo "  ❌ Lambda 残留" && exit 1) || echo "  ✅ Lambda 已清理"
	@echo "  ✅ 零残留"

pipeline:
	$(MAKE) deploy APP_ENV=$(APP_ENV)
	$(MAKE) smoke APP_ENV=$(APP_ENV)
	@echo "🎉 ho11 平台在线（make destroy APP_ENV=$(APP_ENV) 收尾）"

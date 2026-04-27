.PHONY: help install diagrams slides pdf html watch clean check \
        demo-trust-preflight demo-trust-provision demo-trust-run \
        demo-trust-all demo-trust-cleanup demo-trust-status demo-trust-show \
        demo-trust-tf-init demo-trust-tf-plan demo-trust-tf-apply \
        demo-trust-tf-destroy demo-trust-tf-capture

ROOT := $(shell pwd)
SLIDES := presentation/slides.md
PDF := presentation/slides.pdf
HTML := presentation/slides.html
DIAGRAM_DIR := presentation/assets/diagrams
DIAGRAM_HTML := $(wildcard $(DIAGRAM_DIR)/*.html)
DIAGRAM_WEBP := $(DIAGRAM_HTML:.html=.webp)

# IRSA trust policy size limit demo
TRUST_DEMO_SCRIPT := ./scripts/irsa-trust-limit-demo.sh
TRUST_DEMO_RESULTS := presentation/assets/demos/trust-limit/results.tsv
TRUST_DEMO_DIR := presentation/assets/demos/trust-limit
TF_DEMO_DIR := scripts/terraform-trust-limit-demo
ROLE_NAME ?= role-trust-limit-demo
REGION ?= ap-northeast-2
TARGET_COUNT ?= 12
TRUST_COUNT ?= 5

help:
	@echo "Build targets:"
	@echo "  install              - 의존성 설치 (marp-cli, playwright, sharp)"
	@echo "  diagrams             - HTML 다이어그램을 webp로 렌더 (변경된 것만)"
	@echo "  slides               - PDF 빌드 (diagrams 의존)"
	@echo "  pdf                  - slides의 alias"
	@echo "  html                 - HTML로 슬라이드 빌드"
	@echo "  watch                - Marp 라이브 미리보기"
	@echo "  clean                - 빌드 산출물 제거"
	@echo "  check                - 도구 가용성 확인"
	@echo ""
	@echo "IRSA trust-policy size-limit demo (개인 AWS 계정 사용):"
	@echo "  demo-trust-preflight - 계정/리전 확인 + 진행 컨펌"
	@echo "  demo-trust-provision - fake OIDC provider \$$TARGET_COUNT 개 등록"
	@echo "  demo-trust-run       - Role 생성 + trust entry 1..N 점진 추가, 한도 측정"
	@echo "  demo-trust-all       - preflight -> provision -> run 한 번에"
	@echo "  demo-trust-status    - 현재 Role + OIDC provider 상태 출력"
	@echo "  demo-trust-show      - 마지막 run 결과(results.tsv)를 표로 출력"
	@echo "  demo-trust-cleanup   - Role 및 fake OIDC provider 모두 삭제"
	@echo ""
	@echo "Terraform 버전 (provision 으로 등록한 OIDC provider 재사용):"
	@echo "  demo-trust-tf-init     - terraform init"
	@echo "  demo-trust-tf-plan     - TRUST_COUNT 개 trust 로 plan (변경 미반영)"
	@echo "  demo-trust-tf-apply    - apply (TRUST_COUNT >=5 면 ACLSizePerRole 한도로 실패)"
	@echo "  demo-trust-tf-capture  - apply 출력을 errors/tf-N\$$TRUST_COUNT.err 로 저장"
	@echo "  demo-trust-tf-destroy  - Terraform Role 삭제"
	@echo ""
	@echo "  override env: ROLE_NAME=$(ROLE_NAME) REGION=$(REGION) TARGET_COUNT=$(TARGET_COUNT) TRUST_COUNT=$(TRUST_COUNT)"

install:
	@echo "==> Installing build dependencies"
	npm init -y >/dev/null 2>&1 || true
	npm install --save-dev @marp-team/marp-cli playwright sharp
	npx playwright install chromium

check:
	@command -v node >/dev/null && echo "node: $$(node -v)" || echo "MISSING: node"
	@command -v npx >/dev/null && echo "npx: OK" || echo "MISSING: npx"
	@test -d node_modules/@marp-team/marp-cli && echo "marp-cli: installed" || echo "MISSING: marp-cli (run 'make install')"
	@test -d node_modules/playwright && echo "playwright: installed" || echo "MISSING: playwright (run 'make install')"
	@test -d node_modules/sharp && echo "sharp: installed" || echo "MISSING: sharp (run 'make install')"

diagrams: $(DIAGRAM_WEBP)

$(DIAGRAM_DIR)/%.webp: $(DIAGRAM_DIR)/%.html scripts/render-diagrams.js
	@./scripts/render-diagrams.sh $<

slides: diagrams $(PDF)
pdf: slides

$(PDF): $(SLIDES) $(DIAGRAM_WEBP) presentation/theme.css
	@./scripts/build-slides.sh

html: diagrams
	@npx @marp-team/marp-cli $(SLIDES) -o $(HTML) --allow-local-files --theme presentation/theme.css

watch:
	@npx @marp-team/marp-cli -s presentation --allow-local-files --theme presentation/theme.css

clean:
	rm -f $(DIAGRAM_DIR)/*.webp $(DIAGRAM_DIR)/*.png $(PDF) $(HTML)

# ---- IRSA trust-policy size-limit demo ----

demo-trust-preflight:
	@REGION=$(REGION) ROLE_NAME=$(ROLE_NAME) TARGET_COUNT=$(TARGET_COUNT) $(TRUST_DEMO_SCRIPT) preflight

demo-trust-provision:
	@REGION=$(REGION) ROLE_NAME=$(ROLE_NAME) TARGET_COUNT=$(TARGET_COUNT) $(TRUST_DEMO_SCRIPT) provision

demo-trust-run:
	@REGION=$(REGION) ROLE_NAME=$(ROLE_NAME) TARGET_COUNT=$(TARGET_COUNT) $(TRUST_DEMO_SCRIPT) run

demo-trust-all:
	@REGION=$(REGION) ROLE_NAME=$(ROLE_NAME) TARGET_COUNT=$(TARGET_COUNT) $(TRUST_DEMO_SCRIPT) all

demo-trust-cleanup:
	@REGION=$(REGION) ROLE_NAME=$(ROLE_NAME) $(TRUST_DEMO_SCRIPT) cleanup

demo-trust-status:
	@echo "==> Role: $(ROLE_NAME)"
	@aws iam get-role --role-name $(ROLE_NAME) \
		--query 'Role.{Name:RoleName,Arn:Arn,Created:CreateDate}' --output table 2>/dev/null \
		|| echo "    (role not found)"
	@echo ""
	@echo "==> Trust policy length:"
	@aws iam get-role --role-name $(ROLE_NAME) \
		--query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null \
		| jq -c . | wc -c | awk '{print "    "$$1" chars (URL-decoded compact)"}' \
		|| echo "    (n/a)"
	@echo ""
	@echo "==> OIDC providers (DEMO prefix only):"
	@aws iam list-open-id-connect-providers --output json \
		| jq -r '.OpenIDConnectProviderList[].Arn' \
		| grep -F 'DEMO0000000000000000000000000' || echo "    (none)"

demo-trust-show:
	@test -f $(TRUST_DEMO_RESULTS) || { echo "no results yet — run 'make demo-trust-run' first"; exit 1; }
	@echo "==> $(TRUST_DEMO_RESULTS)"
	@column -t -s "$$(printf '\t')" $(TRUST_DEMO_RESULTS)

# ---- Terraform 버전 ----

demo-trust-tf-init:
	cd $(TF_DEMO_DIR) && terraform init

demo-trust-tf-plan:
	cd $(TF_DEMO_DIR) && terraform plan \
		-var region=$(REGION) \
		-var role_name=$(ROLE_NAME)-tf \
		-var trust_count=$(TRUST_COUNT)

demo-trust-tf-apply:
	cd $(TF_DEMO_DIR) && terraform apply -auto-approve \
		-var region=$(REGION) \
		-var role_name=$(ROLE_NAME)-tf \
		-var trust_count=$(TRUST_COUNT)

# 실패 메시지를 그대로 캡처 + account ID 자동 마스킹 (123456789012 로 치환)
# 원본은 *.raw 사이드카(gitignore) 로 보존
demo-trust-tf-capture:
	@mkdir -p $(TRUST_DEMO_DIR)/errors
	@LOG=$(TRUST_DEMO_DIR)/errors/tf-N$(TRUST_COUNT).log; \
	echo "[demo] capturing -> $$LOG"; \
	cd $(TF_DEMO_DIR) && terraform apply -auto-approve -no-color \
		-var region=$(REGION) \
		-var role_name=$(ROLE_NAME)-tf \
		-var trust_count=$(TRUST_COUNT) 2>&1 | tee ../../$(TRUST_DEMO_DIR)/errors/tf-N$(TRUST_COUNT).log
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \
	if [ -n "$$ACCOUNT_ID" ] && [ "$$ACCOUNT_ID" != "123456789012" ]; then \
	  sed -i.raw "s/$$ACCOUNT_ID/123456789012/g" $(TRUST_DEMO_DIR)/errors/tf-N$(TRUST_COUNT).log; \
	  echo "[demo] sanitized account $$ACCOUNT_ID -> 123456789012"; \
	  echo "[demo] raw kept -> $(TRUST_DEMO_DIR)/errors/tf-N$(TRUST_COUNT).log.raw (gitignored)"; \
	fi

demo-trust-tf-destroy:
	cd $(TF_DEMO_DIR) && terraform destroy -auto-approve \
		-var region=$(REGION) \
		-var role_name=$(ROLE_NAME)-tf \
		-var trust_count=$(TRUST_COUNT)

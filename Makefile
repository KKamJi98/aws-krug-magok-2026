.PHONY: help install diagrams slides pdf html watch clean check

ROOT := $(shell pwd)
SLIDES := presentation/slides.md
PDF := presentation/slides.pdf
HTML := presentation/slides.html
DIAGRAM_DIR := presentation/assets/diagrams
DIAGRAM_HTML := $(wildcard $(DIAGRAM_DIR)/*.html)
DIAGRAM_WEBP := $(DIAGRAM_HTML:.html=.webp)

help:
	@echo "Targets:"
	@echo "  install   - 의존성 설치 (marp-cli, playwright, sharp)"
	@echo "  diagrams  - HTML 다이어그램을 webp로 렌더 (변경된 것만)"
	@echo "  slides    - PDF 빌드 (diagrams 의존)"
	@echo "  pdf       - slides의 alias"
	@echo "  html      - HTML로 슬라이드 빌드"
	@echo "  watch     - Marp 라이브 미리보기"
	@echo "  clean     - 빌드 산출물 제거"
	@echo "  check     - 도구 가용성 확인"

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

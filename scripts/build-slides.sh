#!/usr/bin/env bash
# Build Marp slides to PDF.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d node_modules/@marp-team/marp-cli ]; then
  echo "ERROR: marp-cli not installed. run 'make install' first." >&2
  exit 1
fi

npx @marp-team/marp-cli \
  presentation/slides.md \
  -o presentation/slides.pdf \
  --allow-local-files \
  --theme presentation/theme.css

echo "OK  presentation/slides.pdf"

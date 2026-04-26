#!/usr/bin/env bash
# Render HTML diagram(s) to webp via playwright + sharp.
# Usage:
#   ./scripts/render-diagrams.sh                  # render all diagrams
#   ./scripts/render-diagrams.sh path/to/foo.html # render one

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d node_modules/playwright ] || [ ! -d node_modules/sharp ]; then
  echo "ERROR: missing node deps. run 'make install' first." >&2
  exit 1
fi

if [ $# -eq 0 ]; then
  shopt -s nullglob
  files=(presentation/assets/diagrams/*.html)
  if [ ${#files[@]} -eq 0 ]; then
    echo "no diagrams found"
    exit 0
  fi
  for f in "${files[@]}"; do
    node scripts/render-diagrams.js "$f"
  done
else
  node scripts/render-diagrams.js "$1"
fi

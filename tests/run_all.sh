#!/usr/bin/env bash
# Run the full Python DSP-validator suite (pre-compile validation discipline).
# Usage: ./tests/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for t in tests/test_*.py; do
  echo "== $t =="
  if command -v uv >/dev/null 2>&1; then
    uv run --with numpy python3 "$t" || status=1
  else
    python3 "$t" || status=1
  fi
done
exit $status

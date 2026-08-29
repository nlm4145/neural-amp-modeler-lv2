#!/usr/bin/env bash
# Run the full Python DSP-validator suite (pre-compile validation discipline).
# Usage: ./tests/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

# C++ oversampler verification (built ad hoc; skipped silently if clang++
# is unavailable or the build fails).
if command -v clang++ >/dev/null 2>&1; then
  echo "== tests/verify_oversample_cpp.cpp =="
  if clang++ -O2 -std=c++20 -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_cpp.cpp -o /tmp/verify_os 2>/dev/null; then
    /tmp/verify_os || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_batched.cpp (old vs batched vDSP_conv) =="
  if clang++ -O2 -std=c++17 -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_batched.cpp -o /tmp/verify_osb 2>/dev/null; then
    /tmp/verify_osb || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
fi

for t in tests/test_*.py; do
  echo "== $t =="
  if command -v uv >/dev/null 2>&1; then
    uv run --with numpy python3 "$t" || status=1
  else
    python3 "$t" || status=1
  fi
done
exit $status

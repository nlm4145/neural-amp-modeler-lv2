#!/usr/bin/env bash
# Run the full Python DSP-validator suite (pre-compile validation discipline).
# Usage: ./tests/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

# Honor the caller's CXXFLAGS (e.g. the -nostdinc++ + SDK -isystem workaround
# for broken Command Line Tools libc++ headers).
CXX_EXTRA="${CXXFLAGS:-}"

# C++ oversampler verification (built ad hoc; skipped silently if clang++
# is unavailable or the build fails).
if command -v clang++ >/dev/null 2>&1; then
  echo "== tests/verify_compressor.cpp =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -Isrc tests/verify_compressor.cpp \
      -o /tmp/verify_compressor 2>/dev/null; then
    /tmp/verify_compressor || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_modes.cpp =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -Isrc tests/verify_oversample_modes.cpp \
      -o /tmp/verify_os_modes 2>/dev/null; then
    /tmp/verify_os_modes || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_shared.cpp =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_shared.cpp -o /tmp/verify_os_shared 2>/dev/null; then
    /tmp/verify_os_shared || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_cpp.cpp =="
  if clang++ -O2 -std=c++20 $CXX_EXTRA -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_cpp.cpp -o /tmp/verify_os 2>/dev/null; then
    /tmp/verify_os || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_transition_fade.cpp =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA tests/verify_transition_fade.cpp \
      -o /tmp/verify_transition_fade 2>/dev/null; then
    /tmp/verify_transition_fade || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_batched.cpp (old vs batched vDSP_conv) =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_batched.cpp -o /tmp/verify_osb 2>/dev/null; then
    /tmp/verify_osb || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_cascade.cpp (True 4x/8x per-level chains) =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_cascade.cpp -o /tmp/verify_voc 2>/dev/null; then
    /tmp/verify_voc || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_oversample_latency.cpp (True cascade pipeline delay) =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -framework Accelerate -Isrc src/oversample.cpp \
      tests/verify_oversample_latency.cpp -o /tmp/verify_os_latency 2>/dev/null; then
    /tmp/verify_os_latency || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_wav_ir.cpp (partitioned-FFT cab IR vs direct conv) =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -framework Accelerate -Isrc src/wav_ir.cpp \
      tests/verify_wav_ir.cpp -o /tmp/verify_wav_ir 2>/dev/null; then
    /tmp/verify_wav_ir /tmp || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
  echo "== tests/verify_nsdf.cpp (vectorized tuner NSDF vs scalar) =="
  if clang++ -O2 -std=c++17 $CXX_EXTRA -framework Accelerate \
      tests/verify_nsdf.cpp -o /tmp/verify_nsdf 2>/dev/null; then
    /tmp/verify_nsdf || status=1
  else
    echo "  (skipped: harness build failed)"
  fi
fi

# End-to-end smoke test against the INSTALLED rig plugin. Plain C, so it
# builds with clang even where the C++ toolchain headers are broken.
RIG_SO="$HOME/Library/Audio/Plug-Ins/LV2/neural_amp_modeler.lv2/neural_amp_modeler_rig.so"
echo "== tests/verify_host_smoke.c (installed rig plugin) =="
if [ -f "$RIG_SO" ] && clang -O2 -Ideps/lv2/include tests/verify_host_smoke.c \
    -o /tmp/verify_host_smoke 2>/dev/null; then
  /tmp/verify_host_smoke "$RIG_SO" || status=1
else
  echo "  (skipped: plugin not installed or harness build failed)"
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

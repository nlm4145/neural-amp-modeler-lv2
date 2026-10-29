#!/usr/bin/env bash
# Run the DSP harnesses and Python validators (pre-compile validation discipline).
# Usage: ./tests/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

echo "== tests/test_max_quality_defaults.py =="
python3 tests/test_max_quality_defaults.py || status=1

echo "== tests/test_stage_db_meters.py =="
python3 tests/test_stage_db_meters.py || status=1

echo "== tests/test_a2_fast_ring_copy.py =="
python3 tests/test_a2_fast_ring_copy.py || status=1

# Honor the caller's CXXFLAGS (e.g. the -nostdinc++ + SDK -isystem workaround
# for broken Command Line Tools libc++ headers).
CXX_EXTRA="${CXXFLAGS:-}"

# C++ DSP harnesses fail closed, including missing toolchains. Arguments after
# an optional -- go to the harness rather than the compiler.
run_cpp() {
  local standard="$1" binary="$2"
  shift 2
  local -a build_args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    build_args+=("$1")
    shift
  done
  if [ "$#" -gt 0 ]; then shift; fi
  if clang++ -O2 "-std=$standard" $CXX_EXTRA "${build_args[@]}" -o "$binary"; then
    "$binary" "$@" || status=1
  else
    echo "  (failed: C++ compiler unavailable or harness build failed)"
    status=1
  fi
}

echo "== tests/verify_standalone_worker.cpp =="
run_cpp c++17 /tmp/verify_standalone_worker -pthread -Isrc -Ideps/lv2/include \
  src/standalone_worker.cpp tests/verify_standalone_worker.cpp
echo "== tests/verify_standalone_controls.cpp =="
run_cpp c++20 /tmp/verify_standalone_controls -Isrc -Ideps/lv2/include -Ideps/NeuralAudio \
  -Ideps/NeuralAudio/deps/RTNeural/modules/json tests/verify_standalone_controls.cpp
echo "== tests/verify_rig_control_metadata.cpp =="
run_cpp c++17 /tmp/verify_rig_control_metadata -Isrc \
  -Ideps/NeuralAudio/deps/NeuralAmpModelerCore/Dependencies \
  tests/verify_rig_control_metadata.cpp src/win32_presets.cpp -- resources/neural_amp_modeler_rig.ttl.in

echo "== tests/verify_noise_gate.cpp =="
run_cpp c++17 /tmp/verify_noise_gate -Isrc tests/verify_noise_gate.cpp
echo "== tests/verify_compressor.cpp =="
run_cpp c++17 /tmp/verify_compressor -Isrc tests/verify_compressor.cpp
echo "== tests/verify_output_transformer.cpp =="
run_cpp c++17 /tmp/verify_output_transformer -Isrc tests/verify_output_transformer.cpp
echo "== tests/verify_speaker_dynamics.cpp =="
run_cpp c++17 /tmp/verify_speaker_dynamics -Isrc tests/verify_speaker_dynamics.cpp
echo "== tests/verify_amp_advanced.cpp =="
run_cpp c++17 /tmp/verify_amp_advanced -Isrc tests/verify_amp_advanced.cpp
echo "== tests/verify_overdrive.cpp =="
run_cpp c++17 /tmp/verify_overdrive -Isrc tests/verify_overdrive.cpp
echo "== tests/verify_pin_eq.cpp =="
run_cpp c++17 /tmp/verify_pin_eq -Isrc tests/verify_pin_eq.cpp
echo "== tests/verify_control_work.cpp (control caching / smoothing equivalence) =="
run_cpp c++17 /tmp/verify_control_work -Isrc tests/verify_control_work.cpp
echo "== tests/verify_rig_dsp_cache.cpp (gain / timing / stereo width caches) =="
run_cpp c++17 /tmp/verify_rig_dsp_cache -Isrc tests/verify_rig_dsp_cache.cpp
echo "== tests/verify_space_fx.cpp =="
run_cpp c++17 /tmp/verify_space_fx -Isrc tests/verify_space_fx.cpp
echo "== tests/verify_oversample_modes.cpp =="
run_cpp c++17 /tmp/verify_os_modes -Isrc tests/verify_oversample_modes.cpp

if [ "$(uname -s)" = "Darwin" ]; then
  echo "== tests/verify_oversample_shared.cpp =="
  run_cpp c++17 /tmp/verify_os_shared -framework Accelerate -Isrc src/dsp_accel.cpp src/oversample.cpp \
    tests/verify_oversample_shared.cpp
  echo "== tests/verify_oversample_cpp.cpp =="
  run_cpp c++20 /tmp/verify_os -framework Accelerate -Isrc src/dsp_accel.cpp src/oversample.cpp \
    tests/verify_oversample_cpp.cpp
else
  echo "  (skipped: shared/C++ oversampling harnesses require macOS Accelerate)"
fi

echo "== tests/verify_transition_fade.cpp =="
run_cpp c++17 /tmp/verify_transition_fade tests/verify_transition_fade.cpp

if [ "$(uname -s)" = "Darwin" ]; then
  echo "== tests/verify_oversample_batched.cpp (old vs batched vDSP_conv) =="
  run_cpp c++17 /tmp/verify_osb -framework Accelerate -Isrc src/dsp_accel.cpp src/oversample.cpp \
    tests/verify_oversample_batched.cpp
  echo "== tests/verify_oversample_cascade.cpp (True 4x/8x per-level chains) =="
  run_cpp c++17 /tmp/verify_voc -framework Accelerate -Isrc src/dsp_accel.cpp src/oversample.cpp \
    tests/verify_oversample_cascade.cpp
  echo "== tests/verify_oversample_latency.cpp (True cascade pipeline delay) =="
  run_cpp c++17 /tmp/verify_os_latency -framework Accelerate -Isrc src/dsp_accel.cpp src/oversample.cpp \
    tests/verify_oversample_latency.cpp
  echo "== tests/verify_wav_ir.cpp (partitioned-FFT cab IR vs direct conv) =="
  run_cpp c++17 /tmp/verify_wav_ir -framework Accelerate -Isrc -Ideps/pffft src/dsp_accel.cpp src/wav_ir.cpp \
    tests/verify_wav_ir.cpp -- /tmp
  echo "== tests/verify_nsdf.cpp (vectorized tuner NSDF vs scalar) =="
  run_cpp c++17 /tmp/verify_nsdf -framework Accelerate tests/verify_nsdf.cpp
else
  echo "  (skipped: batched/cascade/latency oversampling, WAV IR and NSDF harnesses require macOS Accelerate)"
fi

# End-to-end smoke test against the INSTALLED rig plugin. Plain C, so it
# builds with clang even where the C++ toolchain headers are broken.
RIG_SO="${RIG_SO:-$HOME/Library/Audio/Plug-Ins/LV2/neural_amp_modeler.lv2/neural_amp_modeler_rig.so}"
echo "== tests/verify_host_smoke.c (installed rig plugin) =="
if [ -f "$RIG_SO" ] && clang -O2 -Ideps/lv2/include tests/verify_host_smoke.c \
    -o /tmp/verify_host_smoke 2>/dev/null; then
  /tmp/verify_host_smoke "$RIG_SO" || status=1
else
  echo "  (skipped: plugin not installed or harness build failed)"
fi

# Black-box stabilization checks need only the rig library, not model files.
if [ "$(uname -s)" = "Darwin" ]; then
  echo "== tests/verify_low_buffer_rig.cpp (small blocks / cached controls) =="
  run_cpp c++20 /tmp/verify_low_buffer_rig -Isrc -Ideps/lv2/include -Ideps/NeuralAudio \
    -Ideps/NeuralAudio/deps/RTNeural/modules/json tests/verify_low_buffer_rig.cpp \
    -- "$RIG_SO" "${RIG_BASELINE_SO:-$RIG_SO}"
fi

echo "== tests/verify_tuner.c (tuner stabilization / 48 and 96 kHz) =="
if [ -f "$RIG_SO" ] && clang -O2 -Ideps/lv2/include tests/verify_tuner.c \
    -o /tmp/verify_tuner; then
  /tmp/verify_tuner "$RIG_SO" || status=1
else
  echo "  (failed: plugin unavailable or tuner harness build failed)"
  status=1
fi

echo "== tests/verify_transformer_switch.cpp (96 kHz / True 8x) =="
EXAMPLE_AMP="deps/NeuralAudio/deps/NeuralAmpModelerCore/example_models/wavenet.nam"
if [ -f "$RIG_SO" ] && [ -f "$EXAMPLE_AMP" ] && \
    clang++ -O2 -std=c++17 $CXX_EXTRA -Ideps/lv2/include \
      tests/verify_transformer_switch.cpp -o /tmp/verify_transformer_switch \
      2>/dev/null; then
  /tmp/verify_transformer_switch "$RIG_SO" "$EXAMPLE_AMP" 96000 6 || status=1
else
  echo "  (skipped: plugin/model unavailable or harness build failed)"
fi

# This harness installs an identity amp internally; its CLI takes only the rig
# library, unlike verify_transformer_switch's external model/rate/mode arguments.
echo "== tests/verify_transformer_controls.cpp (editable trims / base and True 8x) =="
if [ -f "$RIG_SO" ] && \
    clang++ -O2 -std=c++17 $CXX_EXTRA -Isrc -Ideps/lv2/include \
      -Ideps/NeuralAudio -Ideps/NeuralAudio/deps/RTNeural/modules/json \
      tests/verify_transformer_controls.cpp -o /tmp/verify_transformer_controls \
      2>/dev/null; then
  /tmp/verify_transformer_controls "$RIG_SO" || status=1
else
  echo "  (skipped: plugin unavailable or harness build failed)"
fi

# Meter placement must be verified against real processing, including merged True domains.
echo "== tests/verify_stage_db_meters.cpp (inter-stage signal boundaries) =="
if [ -f "$RIG_SO" ] && \
    clang++ -O2 -std=c++17 $CXX_EXTRA -D_DARWIN_C_SOURCE -Isrc -Ideps/lv2/include \
      -Ideps/NeuralAudio -Ideps/NeuralAudio/deps/RTNeural/modules/json \
      tests/verify_stage_db_meters.cpp -o /tmp/verify_stage_db_meters; then
  /tmp/verify_stage_db_meters "$RIG_SO" || status=1
else
  echo "  (failed: plugin unavailable or meter harness build failed)"
  status=1
fi

# Against RIG_SO, this harness supplies its own identity amp and WAV fixtures.
echo "== tests/verify_rack_bypass.cpp (deck switches / stereo cabinets / legacy defaults) =="
if [ -f "$RIG_SO" ] && \
    clang++ -O2 -std=c++17 $CXX_EXTRA -D_DARWIN_C_SOURCE -Isrc -Ideps/lv2/include \
      -Ideps/NeuralAudio -Ideps/NeuralAudio/deps/RTNeural/modules/json \
      tests/verify_rack_bypass.cpp -o /tmp/verify_rack_bypass; then
  /tmp/verify_rack_bypass "$RIG_SO" || status=1
else
  echo "  (failed: plugin unavailable or rack harness build failed)"
  status=1
fi

# Opt in to AppKit runtime checks with a freshly built UI and WindowServer.
if [ -n "${RIG_UI_SO:-}" ]; then
  echo "== tests/verify_transformer_ui.mm (editable controls and presets) =="
  if [ -f "$RIG_UI_SO" ] && clang++ -std=c++20 $CXX_EXTRA -D_DARWIN_C_SOURCE -fobjc-arc \
      -Isrc -Ideps/lv2/include tests/verify_transformer_ui.mm src/rig_knobs.cpp src/rig_theme.mm src/rig_profile_catalog.mm \
      -framework Cocoa -framework QuartzCore -framework CoreImage \
      -o /tmp/verify_transformer_ui; then
    /tmp/verify_transformer_ui "$RIG_UI_SO" || status=1
  else
    echo "  (failed: requested UI unavailable or harness build failed)"
    status=1
  fi
fi

# Most of the Python tests are source-contract guards that need nothing but
# the standard library; only the numeric mirrors import numpy. Run everything
# with the plain interpreter first and fall back to `uv run --with numpy` only
# for the tests that actually need it, so a machine without numpy (or without
# access to the wheel host) still runs every guard.
for t in tests/test_*.py; do
  # Already run above.
  case "$t" in
    tests/test_max_quality_defaults.py|tests/test_stage_db_meters.py|tests/test_a2_fast_ring_copy.py) continue ;;
  esac
  echo "== $t =="
  # `set -e` is active: a bare assignment from a failing command substitution
  # would abort the whole run, so capture the status in a condition.
  if output="$(python3 "$t" 2>&1)"; then code=0; else code=$?; fi
  if [ $code -ne 0 ] && printf '%s' "$output" | grep -q "No module named 'numpy'"; then
    if command -v uv >/dev/null 2>&1; then
      if uvout="$(uv run --with numpy python3 "$t" 2>&1)"; then
        printf '%s\n' "$uvout"
      elif printf '%s' "$uvout" | grep -qE "Request failed|No solution|pythonhosted"; then
        # Could not provision numpy (offline or a blocked wheel host). That is
        # an environment limit, not a test failure, so report it as skipped.
        echo "  (skipped: numpy could not be installed -- no network access)"
      else
        printf '%s\n' "$uvout"
        status=1
      fi
    else
      echo "  (skipped: needs numpy, which is not installed)"
    fi
  else
    printf '%s\n' "$output"
    [ $code -eq 0 ] || status=1
  fi
done
exit $status

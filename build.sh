#!/usr/bin/env bash
# Build + install script for the NAM / NAM Oversampled Rig LV2 plugins.
#
# Builds OUT-OF-TREE so the git repo stays clean, then installs the finished
# bundle directly into ~/Library/Audio/Plug-Ins/LV2/ (where Element loads it).
#
# Usage:  ./build.sh          (build + install + codesign + dlopen check)
# Override the build dir with:  BUILD_DIR=/path/to/build ./build.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LV2_DIR="$HOME/Library/Audio/Plug-Ins/LV2"
# Build intermediates live next to the installed plugin (hidden so the DAW's
# bundle scanner ignores them), never inside the git repo.
BUILD_DIR="${BUILD_DIR:-$LV2_DIR/.build-neural-amp-modeler}"
BUNDLE="$BUILD_DIR/neural_amp_modeler.lv2"
INSTALL_BUNDLE="$LV2_DIR/neural_amp_modeler.lv2"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "== 1/4 Configuring: cmake -S $REPO_DIR -B $BUILD_DIR (Release)"
mkdir -p "$BUILD_DIR"
cmake -S "$REPO_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release

echo "== 2/4 Building (-j$JOBS)"
cmake --build "$BUILD_DIR" -j"$JOBS"

echo "== 3/4 Installing bundle -> $INSTALL_BUNDLE"
mkdir -p "$LV2_DIR"
rm -rf "$INSTALL_BUNDLE"
cp -R "$BUNDLE" "$INSTALL_BUNDLE"
codesign --force --deep -s - "$INSTALL_BUNDLE" >/dev/null 2>&1 || true

echo "== 4/4 dlopen check"
for so in "$INSTALL_BUNDLE"/*.so; do
  python3 - "$so" <<'PY'
import sys, ctypes
try:
    ctypes.CDLL(sys.argv[1])
    print("   OK   ", sys.argv[1])
except Exception as e:
    print("   FAIL ", sys.argv[1], "->", e)
    sys.exit(1)
PY
done

echo "== Done. Reload the plugin in Element to pick up the new build."
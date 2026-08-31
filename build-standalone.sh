#!/usr/bin/env bash
# Build and optionally launch the native macOS standalone application.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build-standalone}"
APP="$BUILD_DIR/src/NAM Oversampled Rig.app"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The standalone application currently requires macOS." >&2
  exit 1
fi

echo "== 1/3 Configuring standalone build"
cmake -S "$REPO_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_NAM_STANDALONE=ON

echo "== 2/3 Building NAM Oversampled Rig (-j$JOBS)"
cmake --build "$BUILD_DIR" --target nam_oversampled_rig_standalone -j"$JOBS"

if [[ ! -d "$APP" ]]; then
  APP="$(find "$BUILD_DIR" -type d -name 'NAM Oversampled Rig.app' -print -quit)"
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Build succeeded, but the application bundle was not found." >&2
  exit 1
fi

codesign --force --deep --sign - "$APP" >/dev/null
echo "== 3/3 Ready: $APP"

if [[ "${1:-}" != "--no-launch" ]]; then
  open "$APP"
fi

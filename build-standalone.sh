#!/usr/bin/env bash
# Build and optionally launch the native macOS standalone application.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build-standalone}"
BUILT_APP="$BUILD_DIR/src/Axe FX.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_APP="$INSTALL_DIR/Axe FX.app"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The standalone application currently requires macOS." >&2
  exit 1
fi

echo "== 1/3 Configuring standalone build"
cmake -S "$REPO_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_AXE_FX_STANDALONE=ON

echo "== 2/3 Building Axe FX (-j$JOBS)"
cmake --build "$BUILD_DIR" --target axe_fx_standalone -j"$JOBS"

if [[ ! -d "$BUILT_APP" ]]; then
  BUILT_APP="$(find "$BUILD_DIR" -type d -name 'Axe FX.app' -print -quit)"
fi
if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
  echo "Build succeeded, but the application bundle was not found." >&2
  exit 1
fi

codesign --force --deep --sign - "$BUILT_APP" >/dev/null

echo "== 3/3 Installing -> $INSTALL_APP"
mkdir -p "$INSTALL_DIR"
STAGING_APP="$INSTALL_DIR/.Axe FX.staging.$$.app"
cleanup() { rm -rf "$STAGING_APP"; }
trap cleanup EXIT
ditto "$BUILT_APP" "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"
rm -rf "$INSTALL_APP"
mv "$STAGING_APP" "$INSTALL_APP"
trap - EXIT
echo "== Ready: $INSTALL_APP"

if [[ "${1:-}" != "--no-launch" ]]; then
  open "$INSTALL_APP"
fi

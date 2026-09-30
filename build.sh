#!/usr/bin/env bash
# Build + install script for the NAM / Axe FX LV2 plugins and standalone application.
#
# Simultaneously builds both the LV2 plugin bundle and the native macOS standalone app
# out-of-tree in a single CMake invocation, then installs both to their system locations.
#
# Usage:
#   ./build.sh               (build + install + codesign + dlopen check + relaunch running apps)
#   ./build.sh --no-launch   (build + install without launching any applications)
#   ./build.sh --element     (specifically launch Element after build)
#   ./build.sh --standalone  (specifically launch Axe FX standalone after build)
#
# Override paths with environment variables:
#   BUILD_DIR=/path/to/build ./build.sh
#   LV2_DIR=/path/to/lv2 ./build.sh
#   INSTALL_DIR=/path/to/Applications ./build.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_MACOS=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  IS_MACOS=1
fi

NO_LAUNCH=0
FORCE_LAUNCH_ELEMENT=0
FORCE_LAUNCH_STANDALONE=0

for arg in "$@"; do
  case "$arg" in
    --no-launch)
      NO_LAUNCH=1
      ;;
    --element|--launch-element)
      FORCE_LAUNCH_ELEMENT=1
      ;;
    --standalone|--launch-standalone|--axefx|--axe-fx)
      FORCE_LAUNCH_STANDALONE=1
      ;;
    -h|--help)
      echo "Usage: $0 [--no-launch] [--element] [--standalone]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--no-launch] [--element] [--standalone]" >&2
      exit 1
      ;;
  esac
done

if (( IS_MACOS )); then
  LV2_DIR="${LV2_DIR:-$HOME/Library/Audio/Plug-Ins/LV2}"
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  INSTALL_APP="$INSTALL_DIR/Axe FX.app"
else
  LV2_DIR="${LV2_DIR:-$HOME/.lv2}"
fi

# Build intermediates live next to the installed plugin (hidden so the DAW's
# bundle scanner ignores them), never inside the git repo.
BUILD_DIR="${BUILD_DIR:-$LV2_DIR/.build-neural-amp-modeler}"
BUNDLE="$BUILD_DIR/neural_amp_modeler.lv2"
INSTALL_BUNDLE="$LV2_DIR/neural_amp_modeler.lv2"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

echo "== 1/5 Configuring: cmake -S $REPO_DIR -B $BUILD_DIR (Release)"
mkdir -p "$BUILD_DIR"

CMAKE_ARGS=(
  -S "$REPO_DIR"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
)

if (( IS_MACOS )); then
  CMAKE_ARGS+=(
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
    -DBUILD_AXE_FX_STANDALONE=ON
  )
fi

cmake "${CMAKE_ARGS[@]}"

echo "== 2/5 Building plugin and standalone simultaneously (-j$JOBS)"
cmake --build "$BUILD_DIR" -j"$JOBS"

ELEMENT_WAS_RUNNING=0
AXEFX_WAS_RUNNING=0

if (( IS_MACOS )); then
  # Close Element and/or Axe FX if currently running so files are not locked
  # and new binaries are picked up on relaunch.
  if pgrep -x "Element" >/dev/null 2>&1; then
    ELEMENT_WAS_RUNNING=1
    echo "   Closing Element..."
    osascript -e 'with timeout of 2 seconds' -e 'tell application "Element" to quit' -e 'end timeout' >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! pgrep -x "Element" >/dev/null 2>&1; then break; fi
      sleep 0.2
    done
    if pgrep -x "Element" >/dev/null 2>&1; then
      killall -9 "Element" >/dev/null 2>&1 || true
      sleep 0.5
    fi
  fi

  if pgrep -x "Axe FX" >/dev/null 2>&1; then
    AXEFX_WAS_RUNNING=1
    echo "   Closing Axe FX..."
    killall "Axe FX" 2>/dev/null || true
    for _ in {1..10}; do
      if ! pgrep -x "Axe FX" >/dev/null 2>&1; then break; fi
      sleep 0.2
    done
  fi
fi

echo "== 3/5 Installing LV2 bundle -> $INSTALL_BUNDLE"
mkdir -p "$LV2_DIR"
# Atomic swap: copy to a temp sibling first, then move into place. A failed
# copy mid-way must never leave the user without an installed plugin.
STAGING="$LV2_DIR/.staging-$$"
rm -rf "$STAGING"
cp -R "$BUNDLE" "$STAGING" || { rm -rf "$STAGING"; echo "install copy failed"; exit 1; }
rm -rf "$INSTALL_BUNDLE"
mv "$STAGING" "$INSTALL_BUNDLE" || { rm -rf "$STAGING"; echo "install move failed"; exit 1; }

if (( IS_MACOS )); then
  codesign --force --deep -s - "$INSTALL_BUNDLE" >/dev/null 2>&1 || true

  echo "== 4/5 dlopen check"
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

  BUILT_APP="$BUILD_DIR/src/Axe FX.app"
  if [[ ! -d "$BUILT_APP" ]]; then
    BUILT_APP="$(find "$BUILD_DIR" -type d -name 'Axe FX.app' -print -quit)"
  fi
  if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
    echo "Build succeeded, but the standalone application bundle was not found." >&2
    exit 1
  fi

  CODESIGN_DIR="$HOME/Library/Application Support/Axe FX"
  CODESIGN_KC="$CODESIGN_DIR/axefx-codesign.keychain-db"
  CODESIGN_PASS="axefx-local-codesign"
  CODESIGN_ID="Axe FX Local Signer"

  ensure_local_codesign_identity() {
    mkdir -p "$CODESIGN_DIR"
    if [[ ! -f "$CODESIGN_KC" ]]; then
      security create-keychain -p "$CODESIGN_PASS" "$CODESIGN_KC"
    fi
    security set-keychain-settings "$CODESIGN_KC"
    security unlock-keychain -p "$CODESIGN_PASS" "$CODESIGN_KC"

    if ! security find-identity -p codesigning "$CODESIGN_KC" 2>/dev/null | grep -q "$CODESIGN_ID"; then
      local tmpdir
      tmpdir="$(mktemp -d)"
      cat >"$tmpdir/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = Axe FX Local Signer
O = Axe FX
[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$tmpdir/key.pem" -out "$tmpdir/cert.pem" \
        -days 3650 -config "$tmpdir/openssl.cnf" >/dev/null 2>&1
      openssl pkcs12 -export -legacy \
        -out "$tmpdir/cert.p12" -inkey "$tmpdir/key.pem" -in "$tmpdir/cert.pem" \
        -passout "pass:$CODESIGN_PASS" -name "$CODESIGN_ID" >/dev/null 2>&1
      security import "$tmpdir/cert.p12" -k "$CODESIGN_KC" \
        -P "$CODESIGN_PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
      security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$CODESIGN_PASS" "$CODESIGN_KC" >/dev/null
      rm -rf "$tmpdir"
    fi
  }

  echo "== 5/5 Installing standalone -> $INSTALL_APP"
  ensure_local_codesign_identity
  codesign --force --deep --keychain "$CODESIGN_KC" --sign "$CODESIGN_ID" "$BUILT_APP" >/dev/null

  mkdir -p "$INSTALL_DIR"
  rsync -a --delete "$BUILT_APP/" "$INSTALL_APP/"
  codesign --force --deep --keychain "$CODESIGN_KC" --sign "$CODESIGN_ID" "$INSTALL_APP" >/dev/null
  codesign --verify --deep --strict "$INSTALL_APP"
  touch "$INSTALL_APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP" >/dev/null 2>&1 || true
  echo "   OK    $INSTALL_APP"
fi

if (( IS_MACOS && ! NO_LAUNCH )); then
  if (( FORCE_LAUNCH_STANDALONE )); then
    echo "== Launching Axe FX..."
    open "$INSTALL_APP"
  elif (( FORCE_LAUNCH_ELEMENT )); then
    echo "== Launching Element..."
    open -b "net.kushview.Element" >/dev/null 2>&1 || \
      open -a "/Applications/Element.app" >/dev/null 2>&1 || \
      open -a "Element" >/dev/null 2>&1 || true
  elif (( AXEFX_WAS_RUNNING || ELEMENT_WAS_RUNNING )); then
    if (( AXEFX_WAS_RUNNING )); then
      echo "== Reopening Axe FX..."
      open "$INSTALL_APP"
    fi
    if (( ELEMENT_WAS_RUNNING )); then
      echo "== Reopening Element..."
      open -b "net.kushview.Element" >/dev/null 2>&1 || \
        open -a "/Applications/Element.app" >/dev/null 2>&1 || \
        open -a "Element" >/dev/null 2>&1 || true
    fi
  else
    echo "== Launching Axe FX..."
    open "$INSTALL_APP"
  fi
fi

echo "== Done. Both LV2 plugin and standalone app are updated."

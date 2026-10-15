#!/usr/bin/env bash
# Build + install script for the NAM / Axe FX LV2 plugins and standalone application.
#
# Simultaneously builds both the LV2 plugin bundle and the native macOS standalone app
# out-of-tree in a single CMake invocation, then installs both to their system locations.
#
# Usage:
#   ./build.sh               (interactive settings, then build + install + relaunch)
#   ./build.sh --no-menu     (reuse processing settings without prompting)
#   ./build.sh --dry-run     (preview settings and configure command only)
#   ./build.sh --no-launch   (build + install without launching any applications)
#   ./build.sh --element     (specifically launch Element after build)
#   ./build.sh --standalone  (specifically launch Axe FX standalone after build)
#   ./build.sh --parallel    (build with parallel model processing)
#   ./build.sh --serial      (build with serial model processing)
#
# Override paths with environment variables:
#   BUILD_DIR=/path/to/build ./build.sh
#   LV2_DIR=/path/to/lv2 ./build.sh
#   INSTALL_DIR=/path/to/Applications ./build.sh
#   BUILD_PARALLEL_MODELS=ON BUILD_PARALLEL_CABS=OFF BUILD_SMART_BYPASS=OFF ./build.sh --no-menu
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_MACOS=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  IS_MACOS=1
fi

NO_LAUNCH=0
FORCE_LAUNCH_ELEMENT=0
FORCE_LAUNCH_STANDALONE=0
MENU=auto
DRY_RUN=0
PROCESSING_FLAG=""

usage() {
  echo "Usage: $0 [--menu|--no-menu] [--dry-run] [--parallel|--serial] [--no-launch|--element|--standalone]"
}

for arg in "$@"; do
  case "$arg" in
    --menu) MENU=on ;;
    --no-menu) MENU=off ;;
    --dry-run) DRY_RUN=1 ;;
    --parallel) PROCESSING_FLAG=ON ;;
    --serial) PROCESSING_FLAG=OFF ;;
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
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
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
# bundle scanner ignores them). Key the cache by checkout path so worktrees
# cannot reuse a CMake cache generated from a different source directory.
REPO_BUILD_ID="$(printf '%s' "$REPO_DIR" | cksum)"
BUILD_DIR="${BUILD_DIR:-$LV2_DIR/.build-neural-amp-modeler-${REPO_BUILD_ID%% *}}"
BUNDLE="$BUILD_DIR/neural_amp_modeler.lv2"
INSTALL_BUNDLE="$LV2_DIR/neural_amp_modeler.lv2"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

PARALLEL_MODELS=ON
PARALLEL_CABS=OFF
SMART_BYPASS=OFF
# Read only known boolean entries, never execute cache contents as shell code.
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  while IFS='=' read -r key value; do
    case "$value" in
      1|ON|on|YES|yes|TRUE|true|Y|y) value=ON ;;
      0|OFF|off|NO|no|FALSE|false|N|n|IGNORE|NOTFOUND|*-NOTFOUND|"") value=OFF ;;
      *) continue ;;
    esac
    case "$key" in
      AXE_FX_PARALLEL_MODELS_DEFAULT:BOOL) PARALLEL_MODELS="$value" ;;
      AXE_FX_PARALLEL_CABS_DEFAULT:BOOL) PARALLEL_CABS="$value" ;;
      SMART_BYPASS_ENABLED:BOOL) SMART_BYPASS="$value" ;;
    esac
  done < "$BUILD_DIR/CMakeCache.txt"
fi
PARALLEL_MODELS="${BUILD_PARALLEL_MODELS-$PARALLEL_MODELS}"
PARALLEL_MODELS="${PROCESSING_FLAG:-$PARALLEL_MODELS}"
PARALLEL_CABS="${BUILD_PARALLEL_CABS-$PARALLEL_CABS}"
SMART_BYPASS="${BUILD_SMART_BYPASS-$SMART_BYPASS}"
for setting in PARALLEL_MODELS PARALLEL_CABS SMART_BYPASS; do
  case "${!setting}" in
    ON|OFF) ;;
    *) echo "BUILD_$setting must be ON or OFF." >&2; exit 1 ;;
  esac
done

LAUNCH=auto
if (( NO_LAUNCH )); then LAUNCH=none
elif (( FORCE_LAUNCH_STANDALONE )); then LAUNCH=standalone
elif (( FORCE_LAUNCH_ELEMENT )); then LAUNCH=element
fi

processing_mode() {
  if [[ "$PARALLEL_MODELS" == ON ]]; then echo "Parallel"; else echo "Serial"; fi
}

show_settings() {
  echo "Processing mode: $(processing_mode)"
  echo "Threaded NAM cabinets: $PARALLEL_CABS"
  echo "Smart bypass (single-model LV2 only): $SMART_BYPASS"
  echo "Launch: $LAUNCH"
}

choose_processing_mode() {
  local mode_choice
  echo
  echo "Processing mode (macOS standalone):"
  echo "  p  Parallel"
  echo "  s  Serial"
  if ! read -r -p "Mode [current: $(processing_mode)]: " mode_choice; then
    return
  fi
  case "$mode_choice" in
    p|P|parallel|Parallel) PARALLEL_MODELS=ON ;;
    s|S|serial|Serial) PARALLEL_MODELS=OFF ;;
    "") ;;
    *) echo "Invalid mode. Use p or s." ;;
  esac
}

if [[ "$MENU" == on || ( "$MENU" == auto && -t 0 && -t 1 ) ]]; then
  while true; do
    echo
    echo "Axe FX Build Settings"
    show_settings
    echo "1  Processing mode: Parallel / Serial (macOS standalone)"
    echo "2  Toggle threaded NAM cabinets (experimental, macOS standalone)"
    echo "3  Toggle smart bypass (single-model LV2 only, not the rig)"
    echo "4  Cycle launch: auto / standalone / element / none"
    echo "Enter or b: build and install    q: quit"
    if ! read -r -p "Choice: " choice; then
      echo "Build cancelled."
      exit 0
    fi
    case "$choice" in
      1) choose_processing_mode ;;
      2) if [[ "$PARALLEL_CABS" == ON ]]; then PARALLEL_CABS=OFF; else PARALLEL_CABS=ON; fi ;;
      3) if [[ "$SMART_BYPASS" == ON ]]; then SMART_BYPASS=OFF; else SMART_BYPASS=ON; fi ;;
      4) case "$LAUNCH" in auto) LAUNCH=standalone ;; standalone) LAUNCH=element ;; element) LAUNCH=none ;; none) LAUNCH=auto ;; esac ;;
      ""|b|B) break ;;
      q|Q) echo "Build cancelled."; exit 0 ;;
      *) echo "Invalid choice. Use 1-4, Enter, b, or q." ;;
    esac
  done
fi
NO_LAUNCH=0
FORCE_LAUNCH_STANDALONE=0
FORCE_LAUNCH_ELEMENT=0
case "$LAUNCH" in
  none) NO_LAUNCH=1 ;;
  standalone) FORCE_LAUNCH_STANDALONE=1 ;;
  element) FORCE_LAUNCH_ELEMENT=1 ;;
esac

CMAKE_ARGS=(
  -S "$REPO_DIR"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DSMART_BYPASS_ENABLED="$SMART_BYPASS"
)

if (( IS_MACOS )); then
  CMAKE_ARGS+=(
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
    -DBUILD_AXE_FX_STANDALONE=ON
    -DAXE_FX_PARALLEL_MODELS_DEFAULT="$PARALLEL_MODELS"
    -DAXE_FX_PARALLEL_CABS_DEFAULT="$PARALLEL_CABS"
  )
fi

echo
show_settings
if (( ! IS_MACOS )); then
  echo "Parallel model and cabinet choices apply only to the macOS standalone app."
fi
if (( DRY_RUN )); then
  printf 'cmake'
  printf ' %q' "${CMAKE_ARGS[@]}"
  printf '\n'
  exit 0
fi

echo "== 1/5 Configuring: cmake -S $REPO_DIR -B $BUILD_DIR (Release)"
mkdir -p "$BUILD_DIR"
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

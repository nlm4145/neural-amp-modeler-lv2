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
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
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

ensure_local_codesign_identity
codesign --force --deep --keychain "$CODESIGN_KC" --sign "$CODESIGN_ID" "$BUILT_APP" >/dev/null

echo "== 3/3 Installing -> $INSTALL_APP"
mkdir -p "$INSTALL_DIR"
rsync -a --delete "$BUILT_APP/" "$INSTALL_APP/"
codesign --force --deep --keychain "$CODESIGN_KC" --sign "$CODESIGN_ID" "$INSTALL_APP" >/dev/null
codesign --verify --deep --strict "$INSTALL_APP"
touch "$INSTALL_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP" >/dev/null 2>&1 || true
echo "== Ready: $INSTALL_APP"

if [[ "${1:-}" != "--no-launch" ]]; then
  killall "Axe FX" 2>/dev/null || true
  open "$INSTALL_APP"
fi

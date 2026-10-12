#!/usr/bin/env bash
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${REPO_DIR}/dist_temp/AxeFX"
ZIP_FILE="${REPO_DIR}/AxeFX.zip"

echo "Creating clean shareable package in ${DIST_DIR}..."
rm -rf "${REPO_DIR}/dist_temp" "${ZIP_FILE}"
mkdir -p "${DIST_DIR}"

# 1. Copy ready-to-run executables to the root of the distribution
if [ -f "${REPO_DIR}/build-win/src/Axe FX.exe" ]; then
    echo " -> Adding Windows Standalone executable (Axe FX.exe)..."
    cp "${REPO_DIR}/build-win/src/Axe FX.exe" "${DIST_DIR}/Axe FX.exe"
fi

if [ -d "${REPO_DIR}/build/src/Axe FX.app" ]; then
    echo " -> Adding macOS Standalone application (Axe FX.app)..."
    cp -R "${REPO_DIR}/build/src/Axe FX.app" "${DIST_DIR}/Axe FX.app"
fi

# 2. Copy ready-to-use LV2 plugin bundles
mkdir -p "${DIST_DIR}/neural_amp_modeler.lv2"
if [ -d "${REPO_DIR}/build-win/neural_amp_modeler.lv2" ]; then
    echo " -> Adding Windows LV2 plugin binaries (.dll, .ttl)..."
    cp -R "${REPO_DIR}/build-win/neural_amp_modeler.lv2/"* "${DIST_DIR}/neural_amp_modeler.lv2/"
fi
if [ -d "${REPO_DIR}/build/neural_amp_modeler.lv2" ]; then
    echo " -> Adding macOS LV2 plugin binaries (.so)..."
    cp "${REPO_DIR}/build/neural_amp_modeler.lv2/"*.so "${DIST_DIR}/neural_amp_modeler.lv2/" 2>/dev/null || true
fi

# 3. Copy clean source code and build system
echo " -> Adding source code (src/)..."
cp -R "${REPO_DIR}/src" "${DIST_DIR}/src"

echo " -> Adding resources and cmake..."
cp -R "${REPO_DIR}/resources" "${DIST_DIR}/resources"
cp -R "${REPO_DIR}/cmake" "${DIST_DIR}/cmake"
cp "${REPO_DIR}/CMakeLists.txt" "${DIST_DIR}/CMakeLists.txt"
cp "${REPO_DIR}/build.sh" "${DIST_DIR}/build.sh"
cp "${REPO_DIR}/build.bat" "${DIST_DIR}/build.bat"
cp "${REPO_DIR}/README.md" "${DIST_DIR}/README.md"

if [ -d "${REPO_DIR}/installer" ]; then
    echo " -> Adding Windows installer script (installer/)..."
    cp -R "${REPO_DIR}/installer" "${DIST_DIR}/installer"
fi

echo " -> Adding dependencies (deps/)..."
mkdir -p "${DIST_DIR}/deps"
# Copy deps omitting .git internal databases
rsync -a --exclude='.git' "${REPO_DIR}/deps/" "${DIST_DIR}/deps/"

# 4. Create START_HERE.txt instructions
cat << 'EOF' > "${DIST_DIR}/START_HERE.txt"
================================================================================
                    AXE FX & NEURAL AMP MODELER RIG
================================================================================

HOW TO RUN:
-----------
* Windows:
  - Standalone App: Double-click "Axe FX.exe" right in this folder.
  - LV2 Plugin: Copy the "neural_amp_modeler.lv2" folder to:
      C:\Program Files\Common Files\LV2\
    (or run the installer script in installer\AxeFX_Installer.iss).

* macOS:
  - Standalone App: Double-click "Axe FX.app" right in this folder.
  - LV2 Plugin: Copy the "neural_amp_modeler.lv2" folder to:
      ~/Library/Audio/Plug-Ins/LV2/

HOW TO BUILD FROM SOURCE:
-------------------------
* Windows: Double-click "build.bat" (requires CMake and Visual Studio or Clang).
* macOS:   Run "./build.sh" in Terminal (requires CMake and Xcode command line tools).

SOURCE CODE:
------------
The C++ source code is neatly organized inside the "src/" folder.
================================================================================
EOF

# 5. Clean any hidden OS artifacts (.DS_Store)
find "${DIST_DIR}" -name ".DS_Store" -delete 2>/dev/null || true

# 6. Compress into AxeFX.zip
echo "Compressing into ${ZIP_FILE}..."
(cd "${REPO_DIR}/dist_temp" && zip -r -q -9 "${ZIP_FILE}" "AxeFX")
rm -rf "${REPO_DIR}/dist_temp"

echo "========================================================"
echo " Packaging complete!"
echo " Output: ${ZIP_FILE}"
ls -lh "${ZIP_FILE}"
echo "========================================================"

@echo off
setlocal
echo ========================================================
echo   Building Axe FX Standalone & LV2 Plugin (Windows)
echo ========================================================

if not exist build mkdir build

cmake -S . -B build -A x64 -T ClangCL -DBUILD_UTILS=ON -DBUILD_INTERNAL_STATIC_WAVENET=ON -DBUILD_INTERNAL_STATIC_LSTM=ON -DBUILD_NAMCORE=ON -DBUILD_STATIC_RTNEURAL=ON
if %ERRORLEVEL% neq 0 (
    echo CMake configuration with ClangCL failed, falling back to default MSVC compiler...
    cmake -S . -B build -A x64 -DBUILD_UTILS=ON -DBUILD_INTERNAL_STATIC_WAVENET=ON -DBUILD_INTERNAL_STATIC_LSTM=ON -DBUILD_NAMCORE=ON -DBUILD_STATIC_RTNEURAL=ON
)

cmake --build build --config Release -j4
if %ERRORLEVEL% neq 0 (
    echo Build failed!
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo Build successful!
echo Standalone executable: build\src\Release\Axe FX.exe
echo LV2 plugin bundle:     build\neural_amp_modeler.lv2
echo.
pause

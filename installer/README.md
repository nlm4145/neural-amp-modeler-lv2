# Axe FX Windows Installer

This directory contains the Inno Setup script for packaging **Axe FX Standalone** and the **neural_amp_modeler.lv2** plugin for 64-bit Windows systems.

## Prerequisites

- [Inno Setup 6](https://jrsoftware.org/isdl.php) (or install via `choco install innosetup` / `winget install JRSoftware.InnoSetup`)
- A completed Windows build (e.g. in `build-win` or `build`) containing:
  - `src/Axe FX.exe`
  - `neural_amp_modeler.lv2/` (containing `.dll`, `.ttl`, and `manifest.ttl`)

## Building the Installer

### Using `iscc` (Command line)

From the project root:

```cmd
iscc /DBuildDir=build-win installer\AxeFX_Installer.iss
```

Or from the `installer` directory:

```cmd
cd installer
iscc /DBuildDir=..\build-win AxeFX_Installer.iss
```

The resulting installer executable will be generated at:
`installer\Output\AxeFX_Setup_x64.exe`

## Features

- **Component Selection**:
  - Full Installation (Standalone + LV2 Plugin)
  - Standalone Application Only (`C:\Program Files\Axe FX\Axe FX.exe`)
  - LV2 Plugin Only (`C:\Program Files\Common Files\LV2\neural_amp_modeler.lv2\`)
  - Custom Selection
- **Desktop & Start Menu Shortcuts** with optional desktop icon task
- **Uninstaller integration** registered in Windows Apps & Features
- **Post-install launch** option to start Axe FX immediately
- **Preset directory initialization** for `%APPDATA%\Axe FX`

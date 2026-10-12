; Axe FX - Neural Amp Modeler Rig Windows Installer Script
; Compatible with Inno Setup 6.x (https://jrsoftware.org/isdl.php)
;
; Build command:
;   iscc /DBuildDir=path\to\build installer\AxeFX_Installer.iss

#ifndef MyAppName
#define MyAppName "Axe FX"
#endif

#ifndef MyAppVersion
#define MyAppVersion "1.0.0"
#endif

#ifndef MyAppPublisher
#define MyAppPublisher "Axe FX Team"
#endif

#ifndef MyAppURL
#define MyAppURL "https://github.com/mikeoliphant/neural-amp-modeler-lv2"
#endif

#ifndef MyAppExeName
#define MyAppExeName "Axe FX.exe"
#endif

#ifndef BuildDir
#define BuildDir "..\build-win"
#endif

#ifndef ExeDir
  #if FileExists(BuildDir + "\src\Release\" + MyAppExeName)
    #define ExeDir BuildDir + "\src\Release"
  #elif FileExists(BuildDir + "\src\" + MyAppExeName)
    #define ExeDir BuildDir + "\src"
  #elif FileExists(BuildDir + "\" + MyAppExeName)
    #define ExeDir BuildDir
  #else
    #define ExeDir BuildDir + "\src"
  #endif
#endif

[Setup]
; Unique application GUID for uninstallation tracking
AppId={{D97F7D5C-2E3C-4C78-9B7C-A57E882B3654}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=..\installer\Output
OutputBaseFilename=AxeFX_Setup_x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; 64-bit Windows requirement
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64

; Installation privileges (admin required for Common Files\LV2 system directory)
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#MyAppExeName}
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full"; Description: "Full Installation (Standalone Application + LV2 Plugin)"
Name: "standalone_only"; Description: "Standalone Application Only"
Name: "plugin_only"; Description: "LV2 Plugin Only (for DAWs)"
Name: "custom"; Description: "Custom Installation"; Flags: iscustom

[Components]
Name: "standalone"; Description: "Axe FX Standalone Application (Audio Engine & ASIO/WASAPI Host)"; Types: full standalone_only custom
Name: "lv2"; Description: "LV2 Audio Plugin (neural_amp_modeler.lv2 for Reaper, Ardour, Carla, Cakewalk, etc.)"; Types: full plugin_only custom

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Components: standalone; Flags: unchecked

[Files]
; Standalone Application executable
Source: "{#ExeDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion; Components: standalone

; LV2 Bundle contents (.dll, .ttl, manifests, modgui)
Source: "{#BuildDir}\neural_amp_modeler.lv2\*"; DestDir: "{commoncf}\LV2\neural_amp_modeler.lv2"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: lv2

[Icons]
Name: "{autoprograms}\{#MyAppName}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Components: standalone
Name: "{autoprograms}\{#MyAppName}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"; Components: standalone
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; Components: standalone

[Dirs]
Name: "{commoncf}\LV2"; Components: lv2
Name: "{userappdata}\Axe FX"; Permissions: users-full

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent; Components: standalone

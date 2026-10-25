#define AppName "RelayOS"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
#error SourceDir must point to the native RelayOS staging directory.
#endif

[Setup]
AppId={{A9C6D342-220E-4DBF-8D79-68E8872B2C79}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=RelayOS
DefaultDirName={localappdata}\Programs\RelayOS
DefaultGroupName=RelayOS
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist\installer
OutputBaseFilename=RelayOS-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\RelayOSWindows.exe

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\RelayOS"; Filename: "{app}\RelayOSWindows.exe"
Name: "{autodesktop}\RelayOS"; Filename: "{app}\RelayOSWindows.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\RelayOSWindows.exe"; Description: "Launch RelayOS"; Flags: nowait postinstall skipifsilent

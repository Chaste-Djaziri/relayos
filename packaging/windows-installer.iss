#define AppName "Laptop Bridge"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #error SourceDir must point to the PyInstaller onedir output.
#endif

[Setup]
AppId={{A9C6D342-220E-4DBF-8D79-68E8872B2C79}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=RelayOS
DefaultDirName={localappdata}\Programs\RelayOS\Laptop Bridge
DefaultGroupName=RelayOS
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist\installer
OutputBaseFilename=LaptopBridge-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Laptop Bridge.exe

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Laptop Bridge"; Filename: "{app}\Laptop Bridge.exe"
Name: "{autodesktop}\Laptop Bridge"; Filename: "{app}\Laptop Bridge.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\Laptop Bridge.exe"; Description: "Launch Laptop Bridge"; Flags: nowait postinstall skipifsilent

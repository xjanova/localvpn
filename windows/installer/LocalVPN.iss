; LocalVPN Windows installer (Inno Setup 6).
; CI: iscc /DAppVersion=1.2.3 windows\installer\LocalVPN.iss
; Expects a release build in build\windows\x64\runner\Release.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B6F6C4C-5650-4E2D-9C1A-4C4F43414C57}
AppName=LocalVPN
AppVersion={#AppVersion}
AppVerName=LocalVPN {#AppVersion}
AppPublisher=Xman Studio
AppPublisherURL=https://xman4289.com/localvpn
AppSupportURL=https://xman4289.com/localvpn
AppUpdatesURL=https://xman4289.com/localvpn/download
VersionInfoVersion={#AppVersion}
VersionInfoCompany=Xman Studio
VersionInfoDescription=LocalVPN Setup
DefaultDirName={autopf}\LocalVPN
DefaultGroupName=LocalVPN
DisableProgramGroupPage=yes
OutputDir=..\..\release-output
OutputBaseFilename=LocalVPN-Setup-v{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\LocalVPN.exe
UninstallDisplayName=LocalVPN
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Program Files + a network driver (Wintun) both need admin.
PrivilegesRequired=admin
; Updates run while LocalVPN is open: close it, replace files, start again.
CloseApplications=force
RestartApplications=no
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\LocalVPN"; Filename: "{app}\LocalVPN.exe"
Name: "{autodesktop}\LocalVPN"; Filename: "{app}\LocalVPN.exe"; Tasks: desktopicon

[Run]
; The service runs the virtual network card for the app, which then starts
; without a UAC prompt.
Filename: "{app}\LocalVPNService.exe"; Parameters: "--install"; StatusMsg: "Installing the LocalVPN service..."; Flags: runhidden waituntilterminated
; Also runs after a silent in-app update.
Filename: "{app}\LocalVPN.exe"; Description: "{cm:LaunchProgram,LocalVPN}"; Flags: nowait postinstall runasoriginaluser

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM LocalVPN.exe /F"; Flags: runhidden; RunOnceId: "KillLocalVPN"
Filename: "{app}\LocalVPNService.exe"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveLocalVPNService"

[Code]
// An update replaces LocalVPNService.exe, which the running service keeps
// locked: stop and remove it first; [Run] installs it again.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\LocalVPNService.exe')) then
    Exec(ExpandConstant('{app}\LocalVPNService.exe'), '--uninstall', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

; Rebuild with Inno Setup 6's ISCC.exe from this directory. The protected
; Program Files copy owns the SYSTEM service and its desktop companion.
#define AppName "Ceratops Keyboard Layout"
#define AppVersion "1.0.13"
#define AppPublisher "Ceratops-Code"
#define AppURL "https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix"
#define AppDescription "Convert keyboard layouts between English, Hebrew, and Russian."
#define AppCopyright "Copyright (c) 2026 Ceratops-Code contributors"

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
AppComments={#AppDescription}
AppCopyright={#AppCopyright}
AppReadmeFile={app}\README.txt
DefaultDirName={autopf}\CeratopsKeyboardLayout
DisableDirPage=yes
UsePreviousAppDir=no
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
UsePreviousPrivileges=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=.
OutputBaseFilename=CeratopsKeyboardLayout-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=CeratopsKeyboardLayout.ico
UninstallDisplayIcon={app}\CeratopsKeyboardLayout.exe
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} installer
VersionInfoCopyright={#AppCopyright}
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
CloseApplications=yes
RestartApplications=no

[InstallDelete]
Type: files; Name: "{commonstartup}\{#AppName}.lnk"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\UpdateCache"
Type: files; Name: "{commonappdata}\CeratopsKeyboardLayout\Shortcuts.ini"; Check: IsSafeSettingsDirectory
Type: files; Name: "{commonappdata}\CeratopsKeyboardLayout\Shortcuts.ini.pending"; Check: IsSafeSettingsDirectory
Type: files; Name: "{commonappdata}\CeratopsKeyboardLayout\Shortcuts.ini.lock"; Check: IsSafeSettingsDirectory
Type: dirifempty; Name: "{commonappdata}\CeratopsKeyboardLayout"; Check: IsSafeSettingsDirectory

[Dirs]
; Shared data only: an ordinary Startup instance must also be able to save.
Name: "{commonappdata}\CeratopsKeyboardLayout"; Permissions: users-modify

[Files]
Source: "CeratopsKeyboardLayout.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "CeratopsKeyboardLayout.ahk"; DestDir: "{app}"; Flags: ignoreversion
Source: "Manage-KeyboardShortcuts.ahk"; DestDir: "{app}"; Flags: ignoreversion
Source: "CeratopsKeyboardLayout-Service.ahk"; DestDir: "{app}"; Flags: ignoreversion
Source: "Update-AppInstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "CeratopsKeyboardLayout.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "CeratopsKeyboardLayout.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "dependencies.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "license.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "Lib\UIA.ahk"; DestDir: "{app}\Lib"; Flags: ignoreversion
Source: "Lib\LICENSE.txt"; DestDir: "{app}\Lib"; Flags: ignoreversion; AfterInstall: ConfigureService

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\CeratopsKeyboardLayout.exe"; Parameters: """{app}\CeratopsKeyboardLayout.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\CeratopsKeyboardLayout.ico"
Name: "{commonstartup}\{#AppName}"; Filename: "{app}\CeratopsKeyboardLayout.exe"; Parameters: """{app}\CeratopsKeyboardLayout.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\CeratopsKeyboardLayout.ico"; Check: UseStartupFallback

[Run]
Filename: "{app}\CeratopsKeyboardLayout.exe"; Parameters: "{code:GetStartupParameters}"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Check: UseStartupFallback

[Code]
var
  StartupFallback: Boolean;

function GetFileAttributes(Path: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function IsSafeSettingsDirectory: Boolean;
var
  Attributes: Cardinal;
  ErrorCode: LongInt;
begin
  Attributes := GetFileAttributes(ExpandConstant('{commonappdata}\CeratopsKeyboardLayout'));
  if Attributes = $FFFFFFFF then begin
    ErrorCode := DLLGetLastError;
    Result := (ErrorCode = 2) or (ErrorCode = 3);
  end else
    Result := ((Attributes and $400) = 0) and ((Attributes and $10) <> 0);
end;

function UseStartupFallback: Boolean;
begin
  Result := StartupFallback;
end;

function IsUpdaterInstallation: Boolean;
begin
  Result := ExpandConstant('{param:CERATOPSUPGRADE|0}') = '1';
end;

function GetStartupParameters(Param: String): String;
begin
  Result := '"' + ExpandConstant('{app}\CeratopsKeyboardLayout.ahk') + '"';
  if IsUpdaterInstallation then
    Result := Result + ' --skip-update-check';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  RuntimePath, ServiceScriptPath: String;
begin
  if CurStep <> ssInstall then
    Exit;
  { Refuse a substituted settings junction before granting any write permissions. }
  if not IsSafeSettingsDirectory then
    RaiseException('The Ceratops settings folder cannot be a symbolic link or junction.');
  RuntimePath := ExpandConstant('{app}\CeratopsKeyboardLayout.exe');
  ServiceScriptPath := ExpandConstant('{app}\CeratopsKeyboardLayout-Service.ahk');
  if FileExists(RuntimePath) and FileExists(ServiceScriptPath) then
    if (not Exec(RuntimePath, '/script "' + ServiceScriptPath + '" --stop',
        ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode))
        or (ResultCode <> 0) then
      RaiseException('The existing Ceratops service could not be stopped safely.');
end;

procedure ConfigureService;
var
  ResultCode: Integer;
  Outcome: AnsiString;
  OutcomePath, RuntimePath, ServiceScriptPath, InstallParameters: String;
begin
  StartupFallback := True;
  OutcomePath := ExpandConstant('{tmp}\CeratopsServiceOutcome.txt');
  DeleteFile(OutcomePath);
  RuntimePath := ExpandConstant('{app}\CeratopsKeyboardLayout.exe');
  ServiceScriptPath := ExpandConstant('{app}\CeratopsKeyboardLayout-Service.ahk');
  InstallParameters := '/script "' + ServiceScriptPath + '" --install "' +
    ExpandConstant('{tmp}') + '" "' + OutcomePath + '"';
  if IsUpdaterInstallation then
    InstallParameters := InstallParameters + ' --skip-update-check';
  if Exec(RuntimePath, InstallParameters,
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    StartupFallback := ResultCode <> 0;
  if StartupFallback then begin
    if LoadStringFromFile(OutcomePath, Outcome) then
      Log('Ceratops service fallback: ' + Trim(String(Outcome)))
    else
      Log('Ceratops service fallback: no installer result');
    if not WizardSilent then
      MsgBox('The elevated service could not start on this PC. ' +
        'Ceratops will start normally at each Windows sign-in. ' +
        'Administrator-run editors may not be accessible.',
        mbInformation, MB_OK);
  end;
  DeleteFile(OutcomePath);
end;

function InitializeUninstall: Boolean;
var
  ResultCode: Integer;
  RuntimePath, ServiceScriptPath: String;
begin
  RuntimePath := ExpandConstant('{app}\CeratopsKeyboardLayout.exe');
  ServiceScriptPath := ExpandConstant('{app}\CeratopsKeyboardLayout-Service.ahk');
  Result := FileExists(RuntimePath) and FileExists(ServiceScriptPath);
  if Result then
    Result := Exec(RuntimePath, '/script "' + ServiceScriptPath + '" --uninstall',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode)
      and (ResultCode = 0);
  if not Result then
    MsgBox('Ceratops could not remove its service. Uninstall was stopped ' +
      'so the service is not left pointing at deleted files.',
      mbError, MB_OK);
end;

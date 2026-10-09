; Rebuild with Inno Setup 6's ISCC.exe from this directory. The protected
; Program Files copy owns the SYSTEM service and its desktop companion.
#define AppName "Ceratops Keyboard Layout"
#define AppVersion "1.0.10"

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
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
OutputBaseFilename=CeratopsKeyboardLayout-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=CeratopsKeyboardLayout.ico
UninstallDisplayIcon={app}\CeratopsKeyboardLayout.exe
VersionInfoCompany={#AppName}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
CloseApplications=yes
RestartApplications=no

[InstallDelete]
Type: files; Name: "{commonstartup}\{#AppName}.lnk"

[Files]
Source: "CeratopsKeyboardLayout.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "CeratopsKeyboardLayout.ahk"; DestDir: "{app}"; Flags: ignoreversion
Source: "CeratopsKeyboardLayout-Service.ahk"; DestDir: "{app}"; Flags: ignoreversion
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
Filename: "{app}\CeratopsKeyboardLayout.exe"; Parameters: """{app}\CeratopsKeyboardLayout.ahk"""; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Check: UseStartupFallback

[Code]
var
  StartupFallback: Boolean;

function UseStartupFallback: Boolean;
begin
  Result := StartupFallback;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  RuntimePath, ServiceScriptPath: String;
begin
  if CurStep <> ssInstall then
    Exit;
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
  OutcomePath, RuntimePath, ServiceScriptPath: String;
begin
  StartupFallback := True;
  OutcomePath := ExpandConstant('{tmp}\CeratopsServiceOutcome.txt');
  DeleteFile(OutcomePath);
  RuntimePath := ExpandConstant('{app}\CeratopsKeyboardLayout.exe');
  ServiceScriptPath := ExpandConstant('{app}\CeratopsKeyboardLayout-Service.ahk');
  if Exec(RuntimePath, '/script "' + ServiceScriptPath + '" --install "' +
      ExpandConstant('{tmp}') + '" "' + OutcomePath + '"',
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

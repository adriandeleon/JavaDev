#define AppName "Java Dev Environment (OpenJDK 25 + Maven 3.x)"
#define AppVersion "1.0"

; --- EDIT THESE 2 LINES ---
#define JdkMsi "OpenJDK25U-jdk_x64_windows_hotspot_25.0.1_8.msi"
#define MavenDirName "apache-maven-3.9.12"
; --------------------------

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={autopf}\JavaDev
OutputDir=.
OutputBaseFilename=JavaDev_OpenJDK25_Maven3
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin

ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Files]
; JDK MSI to temp
Source: "{#JdkMsi}"; DestDir: "{tmp}"; Flags: deleteafterinstall

; Maven folder (uncompressed) copied into {app}\maven
; This copies the CONTENTS of apache-maven-3.9.12\... into {app}\maven\...
Source: "{#MavenDirName}\*"; DestDir: "{app}\maven"; Flags: recursesubdirs createallsubdirs

[Run]
; Install OpenJDK silently
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\{#JdkMsi}"" /qn /norestart"; Flags: waituntilterminated

[Code]
const
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall';
  WM_SETTINGCHANGE = $001A;
  SMTO_ABORTIFHUNG = $0002;

function SendMessageTimeout(hWnd: Integer; Msg: Integer; wParam: Integer; lParam: string;
  fuFlags: Integer; uTimeout: Integer; out lpdwResult: Integer): Integer;
  external 'SendMessageTimeoutW@user32.dll stdcall';

procedure BroadcastEnvChange();
var
  ResultCode: Integer;
begin
  SendMessageTimeout($FFFF, WM_SETTINGCHANGE, 0, 'Environment', SMTO_ABORTIFHUNG, 5000, ResultCode);
end;

procedure SetSystemEnv(const Name, Value: string);
begin
  RegWriteStringValue(HKLM, EnvironmentKey, Name, Value);
end;

function GetSystemEnv(const Name: string): string;
begin
  if not RegQueryStringValue(HKLM, EnvironmentKey, Name, Result) then
    Result := '';
end;

function AddToSystemPath(const AddValue: string): Boolean;
var
  PathValue: string;
begin
  PathValue := GetSystemEnv('Path');

  // avoid duplicates
  if Pos(';' + Uppercase(AddValue) + ';', ';' + Uppercase(PathValue) + ';') > 0 then
  begin
    Result := False;
    Exit;
  end;

  if (PathValue <> '') and (Copy(PathValue, Length(PathValue), 1) <> ';') then
    PathValue := PathValue + ';';

  PathValue := PathValue + AddValue;
  RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', PathValue);
  Result := True;
end;

procedure RemoveFromSystemPath(const RemoveValue: string);
var
  PathValue, UPath, URem: string;
begin
  PathValue := GetSystemEnv('Path');
  UPath := ';' + Uppercase(PathValue) + ';';
  URem := ';' + Uppercase(RemoveValue) + ';';

  while Pos(URem, UPath) > 0 do
    Delete(UPath, Pos(URem, UPath), Length(URem)-1);

  if (Length(UPath) >= 2) then
    PathValue := Copy(UPath, 2, Length(UPath)-2)
  else
    PathValue := '';

  RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', PathValue);
end;

function LooksLikeTemurin25(const DisplayName: string): Boolean;
var
  S: string;
begin
  S := Uppercase(DisplayName);

  Result :=
    ((Pos('ECLIPSE', S) > 0) or (Pos('ADOPTIUM', S) > 0) or (Pos('TEMURIN', S) > 0)) and
    (Pos('JDK', S) > 0) and
    (Pos('25', S) > 0);
end;

function FindJdkInstallLocationInUninstall(const RootKey: Integer; const BaseKey: string): string;
var
  SubKeys: TArrayOfString;
  I: Integer;
  K, DisplayName, InstallLocation: string;
begin
  Result := '';

  if not RegGetSubkeyNames(RootKey, BaseKey, SubKeys) then
    Exit;

  for I := 0 to GetArrayLength(SubKeys) - 1 do
  begin
    K := BaseKey + '\' + SubKeys[I];

    DisplayName := '';
    if RegQueryStringValue(RootKey, K, 'DisplayName', DisplayName) then
    begin
      if LooksLikeTemurin25(DisplayName) then
      begin
        InstallLocation := '';
        if RegQueryStringValue(RootKey, K, 'InstallLocation', InstallLocation) then
        begin
          if InstallLocation <> '' then
          begin
            Result := InstallLocation;
            Exit;
          end;
        end;
      end;
    end;
  end;
end;

function FindJdkHome(): string;
begin
  Result := '';

  // 64-bit view first
  Result := FindJdkInstallLocationInUninstall(HKLM64, UninstallKey);
  if Result <> '' then Exit;

  // fallback
  Result := FindJdkInstallLocationInUninstall(HKLM32, UninstallKey);
  if Result <> '' then Exit;

  // last resort default base folder
  Result := ExpandConstant('{autopf}\Eclipse Adoptium');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  MavenTarget, JdkHome: string;
begin
  if CurStep = ssPostInstall then
  begin
    MavenTarget := ExpandConstant('{app}\maven');

    // Verify Maven exists
    if not FileExists(MavenTarget + '\bin\mvn.cmd') then
      MsgBox(
        'Maven did not install correctly. Missing: ' + MavenTarget + '\bin\mvn.cmd' + #13#10 +
        'Make sure the Maven folder "' + ExpandConstant('{src}\{#MavenDirName}') + '" exists next to setup.iss when compiling.',
        mbError, MB_OK
      );

    // Set Maven env vars + PATH
    SetSystemEnv('MAVEN_HOME', MavenTarget);
    AddToSystemPath(MavenTarget + '\bin');

    // Set Java env vars + PATH (detect from registry)
    JdkHome := FindJdkHome();
    SetSystemEnv('JAVA_HOME', JdkHome);
    AddToSystemPath(JdkHome + '\bin');

    BroadcastEnvChange();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  MavenTarget, JdkHome: string;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    MavenTarget := ExpandConstant('{app}\maven');
    JdkHome := GetSystemEnv('JAVA_HOME');

    RemoveFromSystemPath(MavenTarget + '\bin');
    if JdkHome <> '' then
      RemoveFromSystemPath(JdkHome + '\bin');

    RegDeleteValue(HKLM, EnvironmentKey, 'MAVEN_HOME');
    RegDeleteValue(HKLM, EnvironmentKey, 'JAVA_HOME');

    BroadcastEnvChange();
  end;
end;

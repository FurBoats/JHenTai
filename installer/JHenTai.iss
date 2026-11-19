; JHenTai (Xray fork) Windows installer — Inno Setup 6 script.
;
; Per-user install: no admin rights needed, neither for the program
; ({localappdata}\Programs\JHenTai) nor for its data, which the app keeps
; in the roaming AppData folder (%APPDATA%\top.jtmonster\jhentai) via
; path_provider. CI builds the Flutter Windows release first, then runs:
;   ISCC.exe /DMyAppVersion=<version> installer\JHenTai.iss

#ifndef MyAppVersion
  #define MyAppVersion "8.0.18"
#endif

#define MyAppName "JHenTai"
#define MyAppExeName "jhentai.exe"
#define MyAppPublisher "FurBoats"

[Setup]
; Fixed AppId: this is what lets a new installer detect and update an
; existing installation (and what the uninstall registry key hangs off).
AppId={{6F3A9C24-1B7E-4D05-9A82-3E5F7C1D90AB}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\JHenTai
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
OutputBaseFilename=JHenTai-{#MyAppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startmenu"; Description: "添加到开始菜单"; GroupDescription: "附加快捷方式："
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F3A9C24-1B7E-4D05-9A82-3E5F7C1D90AB}_is1';
  { The app's own data folder (settings, account, default downloads), as
    computed by path_provider from the runner's CompanyName/ProductName.
    This fixed suffix is the ONLY thing uninstall data-erasure may touch. }
  AppDataSuffix = 'top.jtmonster\jhentai';

var
  ExistingVersion: String;
  UninstallEraseData: Boolean;
  EraseDataCheckBox: TNewCheckBox;

function GetExistingVersion: String;
var
  Version: String;
begin
  Version := '';
  if RegQueryStringValue(HKCU, UninstallRegKey, 'DisplayVersion', Version) then
  begin
    Result := Version;
    exit;
  end;
  if RegQueryStringValue(HKLM, UninstallRegKey, 'DisplayVersion', Version) then
  begin
    Result := Version;
    exit;
  end;
  Result := '';
end;

function InitializeSetup: Boolean;
begin
  ExistingVersion := GetExistingVersion;
  Result := True;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: String;
begin
  S := '';
  if ExistingVersion <> '' then
  begin
    if ExistingVersion = '{#MyAppVersion}' then
      S := S + '检测到已安装版本：' + ExistingVersion + '，本次将重新安装该版本。' + NewLine + NewLine
    else
      S := S + '检测到已安装版本：' + ExistingVersion + '，本次将更新到 {#MyAppVersion}。' + NewLine + NewLine;
  end
  else
    S := S + '未检测到已安装版本，将进行全新安装。' + NewLine + NewLine;
  S := S + MemoDirInfo + NewLine;
  if MemoTasksInfo <> '' then
    S := S + NewLine + MemoTasksInfo + NewLine;
  Result := S;
end;

{ Uninstall: before anything is removed, offer the "erase app data"
  checkbox (only when the data folder actually exists). Cancelling this
  dialog aborts the uninstall; the checkbox choice is remembered and
  acted on in CurUninstallStepChanged. }
function InitializeUninstall: Boolean;
var
  Form: TSetupForm;
  InfoLabel: TLabel;
  OkButton, CancelButton: TNewButton;
  DataDir: String;
begin
  Result := True;
  UninstallEraseData := False;
  DataDir := ExpandConstant('{userappdata}\' + AppDataSuffix);
  if not DirExists(DataDir) then
    exit;

  Form := CreateCustomForm;
  try
    Form.Caption := '卸载 {#MyAppName}';
    Form.ClientWidth := ScaleX(440);
    Form.ClientHeight := ScaleY(150);

    InfoLabel := TLabel.Create(Form);
    InfoLabel.Parent := Form;
    InfoLabel.Left := ScaleX(16);
    InfoLabel.Top := ScaleY(14);
    InfoLabel.Width := Form.ClientWidth - ScaleX(32);
    InfoLabel.AutoSize := False;
    InfoLabel.WordWrap := True;
    InfoLabel.Caption := '即将卸载 {#MyAppName}。应用数据保存在：' + DataDir;

    EraseDataCheckBox := TNewCheckBox.Create(Form);
    EraseDataCheckBox.Parent := Form;
    EraseDataCheckBox.Left := ScaleX(16);
    EraseDataCheckBox.Top := ScaleY(56);
    EraseDataCheckBox.Width := Form.ClientWidth - ScaleX(32);
    EraseDataCheckBox.Caption := '擦除应用数据（设置、账号与默认下载内容）';
    EraseDataCheckBox.Checked := True;

    OkButton := TNewButton.Create(Form);
    OkButton.Parent := Form;
    OkButton.Caption := '继续卸载';
    OkButton.ModalResult := mrOk;
    OkButton.Default := True;
    OkButton.Left := Form.ClientWidth - ScaleX(196);
    OkButton.Top := Form.ClientHeight - ScaleY(44);
    OkButton.Width := ScaleX(84);
    OkButton.Height := ScaleY(28);

    CancelButton := TNewButton.Create(Form);
    CancelButton.Parent := Form;
    CancelButton.Caption := '取消';
    CancelButton.ModalResult := mrCancel;
    CancelButton.Cancel := True;
    CancelButton.Left := Form.ClientWidth - ScaleX(100);
    CancelButton.Top := Form.ClientHeight - ScaleY(44);
    CancelButton.Width := ScaleX(84);
    CancelButton.Height := ScaleY(28);

    if Form.ShowModal = mrOk then
      UninstallEraseData := EraseDataCheckBox.Checked
    else
      Result := False;
  finally
    Form.Free;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir, AppDir, UserAppData: String;
begin
  if (CurUninstallStep <> usPostUninstall) or (not UninstallEraseData) then
    exit;

  UserAppData := RemoveBackslashUnlessRoot(ExpandConstant('{userappdata}'));
  DataDir := RemoveBackslashUnlessRoot(UserAppData + '\' + AppDataSuffix);
  AppDir := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));

  { Safety net against ever deleting the wrong thing:
    - the target must be exactly {userappdata}\top.jtmonster\jhentai,
      rebuilt here from constants only — never from user input, the
      registry, or the install path;
    - it must live directly under this user's AppData folder;
    - it must not be the install folder, nor contain it, nor be
      contained by it.
    If any check fails, skip the deletion silently and leave the data. }
  if CompareText(Copy(DataDir, 1, Length(UserAppData)), UserAppData) <> 0 then
    exit;
  if CompareText(Copy(DataDir, Length(UserAppData) + 2, 4096), AppDataSuffix) <> 0 then
    exit;
  if CompareText(DataDir, AppDir) = 0 then
    exit;
  if Pos(Lowercase(AppDir) + '\', Lowercase(DataDir) + '\') = 1 then
    exit;
  if Pos(Lowercase(DataDir) + '\', Lowercase(AppDir) + '\') = 1 then
    exit;

  if DirExists(DataDir) then
    DelTree(DataDir, True, True, True);
end;

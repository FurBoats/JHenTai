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
; OutputDir=. puts the finished installer next to this script; Inno's
; default is an Output subfolder, and CI moves the exe from here.
OutputDir=.
OutputBaseFilename=JHenTai-{#MyAppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern

[Languages]
; The ChineseSimplified.isl shipped with Inno Setup is not present in
; every installation (e.g. the GitHub-hosted runner image), so the
; official language file is vendored next to this script.
Name: "chinesesimplified"; MessagesFile: "{#SourcePath}ChineseSimplified.isl"
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
  { The app's own data folder (settings, account, and the default
    download folder as a subfolder named download), as computed by
    path_provider from the runner's CompanyName/ProductName.
    This fixed suffix is the ONLY thing uninstall data-erasure may touch. }
  AppDataSuffix = 'top.jtmonster\jhentai';
  { Name of the download subfolder inside the data folder. Uninstall
    erasure always keeps this one; everything else in the data folder
    is removed. }
  DownloadDirName = 'download';

var
  ExistingVersion: String;

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

{ Uninstall always erases the app data (settings, account, caches)
  with no prompt and no opt-out — except the downloads, which are
  kept: the download subfolder inside the data folder is left
  untouched, and a download folder the user picked elsewhere is
  outside the data folder and never touched at all. }
procedure EraseAppDataExceptDownloads;
var
  DataDir, AppDir, UserAppData, Entry: String;
  FindRec: TFindRec;
begin
  UserAppData := RemoveBackslashUnlessRoot(ExpandConstant('{userappdata}'));
  DataDir := RemoveBackslashUnlessRoot(UserAppData + '\' + AppDataSuffix);
  AppDir := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));

  { Safety net against ever deleting the wrong thing:
    - the target must be exactly the per-user AppData folder
      plus the fixed suffix top.jtmonster\jhentai,
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

  if not DirExists(DataDir) then
    exit;

  { Delete every entry directly inside the data folder except the
    download subfolder. The data folder itself stays in place so the
    kept downloads keep their path. }
  if FindFirst(DataDir + '\*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') and
           (CompareText(FindRec.Name, DownloadDirName) <> 0) then
        begin
          Entry := DataDir + '\' + FindRec.Name;
          if (FindRec.Attributes and faDirectory) <> 0 then
            DelTree(Entry, True, True, True)
          else
            DeleteFile(Entry);
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    EraseAppDataExceptDownloads;
end;

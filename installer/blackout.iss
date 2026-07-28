; Blackout installer (Inno Setup 6)
;
; Installs for the current user only: no admin rights, no UAC prompt, and the
; program directory stays writable so todo.txt can live next to the exe.
;
; Build:  iscc installer\blackout.iss
; Version is read out of the compiled exe, so version.h is the single source
; of truth: version.h -> resource.rc -> Blackout.exe -> this installer.

#define SourceExe "..\bin\Blackout.exe"
#define AppName   "Blackout"
#define AppVer    GetStringFileInfo(SourceExe, "FileVersion")
#define AppUrl    "https://github.com/CharlesGuooo/blackout"

[Setup]
AppId={{8F3A2C41-9B7E-4D52-A6C8-1E0D5B4F7A93}
AppName={#AppName}
AppVersion={#AppVer}
AppVerName={#AppName} {#AppVer}
AppPublisher=Charles Guo
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVer}

; "lowest" makes {autopf} resolve to {localappdata}\Programs -- installing there
; means no UAC prompt at all, and the app keeps its portable data layout.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE

; Refuse to install the x64 build on 32-bit Windows instead of failing later.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Detect a running instance and offer to close it rather than failing on a
; locked file. Must match MUTEX_NAME in src/main.c.
AppMutex=Local\BlackoutSingleton
CloseApplications=yes

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\assets\blackout.ico
UninstallDisplayIcon={app}\Blackout.exe
UninstallDisplayName={#AppName}
OutputDir=..\dist
OutputBaseFilename={#AppName}-{#AppVer}-Setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Checked by default on purpose: Blackout is driven entirely by a global
; hotkey. If it is not running, the hotkey does nothing and the program looks
; broken. The label says exactly what it does and it is one click to opt out.
Name: "startup"; Description: "Start {#AppName} when Windows starts"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE";   DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
; The first-run list IS the tutorial. onlyifdoesntexist is load-bearing: an
; upgrade must never overwrite the list the user has built up.
Source: "first-run-todo.txt"; DestDir: "{app}"; DestName: "todo.txt"; \
    Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\Blackout.exe"
Name: "{autodesktop}\{#AppName}";  Filename: "{app}\Blackout.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "Blackout"; ValueData: """{app}\Blackout.exe"""; \
    Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Blackout.exe"; Description: "Launch {#AppName} now"; \
    Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  TasksFile: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    { The tray menu can write this value too, so uninsdeletevalue alone would
      leave it behind when the install-time task was unchecked. }
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', 'Blackout');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    TasksFile := ExpandConstant('{app}\todo.txt');
    if FileExists(TasksFile) then
    begin
      { SuppressibleMsgBox, not MsgBox: plain MsgBox ignores /SUPPRESSMSGBOXES
        and blocks forever on an unattended uninstall. The last argument is the
        answer used in silent mode -- IDNO, because silently deleting someone's
        task list would be rude. MB_DEFBUTTON2 makes No the default
        interactively too. }
      if SuppressibleMsgBox('Delete your task list as well?' + #13#10 + #13#10 +
                TasksFile + #13#10 + #13#10 +
                'Choose No to keep it.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
      begin
        DeleteFile(TasksFile);
        DeleteFile(ExpandConstant('{app}\todo.txt.tmp'));
        DeleteFile(ExpandConstant('{app}\todo.ini'));
        RemoveDir(ExpandConstant('{app}'));
      end;
    end;
  end;
end;

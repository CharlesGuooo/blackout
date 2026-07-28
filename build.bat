@echo off
setlocal

rem Keep this file pure ASCII. cmd.exe reads .bat in the OEM codepage,
rem so non-ASCII comments get mangled into parse errors.
rem Also: VS install paths contain "(x86)", whose ")" closes an if(...) block
rem early -- that is why this script uses goto instead of parenthesised blocks.

pushd "%~dp0"

if defined VSCMD_ARG_TGT_ARCH goto :envready

rem Locate Visual Studio through vswhere so this works on any machine and on
rem GitHub Actions runners, not just a hardcoded local install path.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :novswhere

set "VCVARS="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH goto :novswhere
set "VCVARS=%VSPATH%\VC\Auxiliary\Build\vcvars64.bat"
if exist "%VCVARS%" goto :runvcvars

:novswhere
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if exist "%VCVARS%" goto :runvcvars
echo [ERROR] Visual Studio with the C++ toolset was not found.
echo         Install "Visual Studio Build Tools" with the "Desktop development with C++" workload.
popd
exit /b 1

:runvcvars
call "%VCVARS%" >nul
if errorlevel 1 goto :fail

:envready
if not exist bin mkdir bin
if not exist obj mkdir obj

if exist assets\blackout.ico goto :haveicon
where python >nul 2>&1
if errorlevel 1 goto :noicon
python tools\make_icon.py
if errorlevel 1 goto :noicon

:haveicon
set "RESOBJ="
if not exist src\resource.rc goto :norc
if not exist assets\blackout.ico goto :norc
rc /nologo /fo obj\resource.res src\resource.rc
if errorlevel 1 goto :fail
set "RESOBJ=obj\resource.res"
goto :norc

:noicon
echo [WARN] assets\blackout.ico missing and python unavailable - building without icon
set "RESOBJ="

:norc
cl /nologo /std:c11 /utf-8 /W4 /O1 /GS- /Gy /Gw /GR- /MT ^
   /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN ^
   /Fo:obj\ /Fe:bin\Blackout.exe ^
   src\main.c %RESOBJ% ^
   /link /SUBSYSTEM:WINDOWS /OPT:REF /OPT:ICF /INCREMENTAL:NO ^
   kernel32.lib user32.lib gdi32.lib shell32.lib advapi32.lib
if errorlevel 1 goto :fail

echo.
for %%F in (bin\Blackout.exe) do echo [OK] %%~fF - %%~zF bytes
popd
exit /b 0

:fail
echo.
echo [FAIL] build failed
popd
exit /b 1

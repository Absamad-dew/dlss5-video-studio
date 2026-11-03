@echo off
setlocal
set "SRC=%~dp0native"
set "SL=%~dp0third_party\streamline-sdk-v2.12.0"
if defined DLSS5_STREAMLINE_SDK set "SL=%DLSS5_STREAMLINE_SDK%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Test-BuildPrerequisites.ps1" -Target Streamline
if errorlevel 1 exit /b 2
set "OUT=%~dp0dist\streamline"
if not exist "%OUT%" mkdir "%OUT%"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSROOT="
if exist "%VSWHERE%" for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%I"
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
pushd "%SRC%"
cl /nologo /std:c++20 /utf-8 /O2 /EHsc /W3 /MD /I"%SL%\include" streamline_probe.cpp ^
  /Fe:"%OUT%\streamline-probe.exe" /link "%SL%\lib\x64\sl.interposer.lib" dxgi.lib
set "RESULT=%ERRORLEVEL%"
popd
exit /b %RESULT%

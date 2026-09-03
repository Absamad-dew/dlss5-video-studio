@echo off
setlocal
set "SRC=%~dp0native"
set "SDK=%~dp0third_party\nvidia_ngx_sdk"
set "SL=%~dp0third_party\streamline-sdk-v2.12.0"
set "NVCODEC=%~dp0third_party\nvcodec\include"
if not exist "%NVCODEC%\ffnvcodec\nvEncodeAPI.h" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-NvCodecHeaders.ps1"
  if errorlevel 1 exit /b 1
)
if not defined DLSS5_BUILD_OUT set "DLSS5_BUILD_OUT=%~dp0dist\engine"
set "OUT=%DLSS5_BUILD_OUT%"

if not exist "%OUT%" mkdir "%OUT%"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSROOT="
if exist "%VSWHERE%" for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%I"
if defined VSROOT set "VCVARS=%VSROOT%\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
  echo Visual C++ x64 build tools were not found.
  exit /b 1
)
call "%VCVARS%" >nul
if errorlevel 1 exit /b 1

pushd "%SRC%"
cl /nologo /std:c++20 /utf-8 /O2 /openmp /EHsc /W3 /MD /I"%SDK%\include" /I"%SL%\include" /I"%NVCODEC%" dlss5_video_host.cpp ^
  /Fe:"%OUT%\dlss5-video-host.exe" ^
  /link "%SDK%\lib\Windows_x86_64\x64\nvsdk_ngx_d.lib" ^
  "%SL%\lib\x64\sl.interposer.lib" ^
  version.lib kernel32.lib user32.lib gdi32.lib advapi32.lib ole32.lib comctl32.lib d3dcompiler.lib
set "RESULT=%ERRORLEVEL%"
popd
exit /b %RESULT%

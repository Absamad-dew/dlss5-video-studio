@echo off
setlocal
set "SRC=%~dp0native"
set "SDK=%~dp0third_party\nvidia_ngx_sdk"
set "SL=%~dp0third_party\streamline-sdk-v2.12.0"
if not defined DLSS5_BUILD_OUT set "DLSS5_BUILD_OUT=%~dp0dist\engine"
set "OUT=%DLSS5_BUILD_OUT%"

if not exist "%OUT%" mkdir "%OUT%"

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

pushd "%SRC%"
cl /nologo /std:c++20 /utf-8 /O2 /openmp /EHsc /W3 /MD /I"%SDK%\include" /I"%SL%\include" dlss5_video_host.cpp ^
  /Fe:"%OUT%\dlss5-video-host.exe" ^
  /link "%SDK%\lib\Windows_x86_64\x64\nvsdk_ngx_d.lib" ^
  "%SL%\lib\x64\sl.interposer.lib" ^
  version.lib kernel32.lib user32.lib gdi32.lib advapi32.lib ole32.lib comctl32.lib d3dcompiler.lib d3d12.lib
set "RESULT=%ERRORLEVEL%"
popd
exit /b %RESULT%

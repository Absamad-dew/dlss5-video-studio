@echo off
setlocal
set "SRC=%~dp0native"
set "SL=%~dp0third_party\streamline-sdk-v2.12.0"
set "OUT=%~dp0dist\streamline"
if not exist "%OUT%" mkdir "%OUT%"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
pushd "%SRC%"
cl /nologo /std:c++20 /utf-8 /O2 /EHsc /W3 /MD /I"%SL%\include" streamline_probe.cpp ^
  /Fe:"%OUT%\streamline-probe.exe" /link "%SL%\lib\x64\sl.interposer.lib" dxgi.lib
set "RESULT=%ERRORLEVEL%"
popd
exit /b %RESULT%

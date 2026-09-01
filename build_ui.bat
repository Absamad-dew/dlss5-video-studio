@echo off
setlocal
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
set "SMA=C:\Windows\Microsoft.Net\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll"
if not defined DLSS5_UI_OUT set "DLSS5_UI_OUT=%~dp0dist\DLSS5 Video Studio.exe"
set "OUT=%DLSS5_UI_OUT%"

for %%I in ("%OUT%") do if not exist "%%~dpI" mkdir "%%~dpI"

"%CSC%" /nologo /target:winexe /platform:x64 /optimize+ /out:"%OUT%" ^
  /reference:"%SMA%" /reference:System.Windows.Forms.dll "%~dp0Program.cs"
exit /b %ERRORLEVEL%

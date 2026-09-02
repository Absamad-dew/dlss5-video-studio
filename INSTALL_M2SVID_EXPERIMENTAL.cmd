@echo off
setlocal
cd /d "%~dp0"
echo Installing the optional experimental M2SVid full-frame backend...
echo Required download: about 9 GB. Existing partial downloads will resume.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-VRGenerativeModels.ps1"
if errorlevel 1 (
  echo.
  echo M2SVid installation did not finish. The partial download was kept for resume.
  pause
  exit /b 1
)
echo.
echo M2SVid experimental backend is ready.
pause

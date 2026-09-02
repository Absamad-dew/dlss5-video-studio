@echo off
setlocal
cd /d "%~dp0"
echo Installing the experimental Moebius sparse inpainting backend...
echo Required download: about 1.1 GB. Existing partial downloads will resume.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-MoebiusModels.ps1"
if errorlevel 1 (
  echo.
  echo Moebius installation did not finish. The partial download was kept for resume.
  pause
  exit /b 1
)
echo.
echo Experimental Moebius backend is ready.
pause

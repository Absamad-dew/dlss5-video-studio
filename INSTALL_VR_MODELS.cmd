@echo off
setlocal
cd /d "%~dp0"
echo Installing Temporal Atlas for native-resolution 2K/4K VR reconstruction...
echo Required download: about 28 MB. Existing partial downloads will resume.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-TemporalAtlasModels.ps1"
if errorlevel 1 (
  echo.
  echo Temporal Atlas installation did not finish. The partial download was kept for resume.
  pause
  exit /b 1
)
echo.
echo Temporal Atlas generative VR is ready.
pause

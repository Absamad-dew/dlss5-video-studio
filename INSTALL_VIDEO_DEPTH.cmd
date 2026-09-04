@echo off
setlocal
cd /d "%~dp0"
echo Installing Video Depth Anything Small and its streaming runtime (about 112 MiB)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-DepthModels.ps1" -PortableRoot "%~dp0." -Selection VideoSmall
if errorlevel 1 (
  echo Installation failed. See the error above; no different model was substituted.
  pause
  exit /b 1
)
echo Video Depth Anything is ready. Restart Studio if it was open.
pause

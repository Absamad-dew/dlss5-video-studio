@echo off
setlocal
cd /d "%~dp0"
echo Installing optional Depth Anything 3 Large into this portable folder...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-DepthModels.ps1" -PortableRoot "%~dp0" -Selection DA3Large
if errorlevel 1 (
  echo.
  echo DA3 Large installation failed.
  pause
  exit /b 1
)
echo.
echo DA3 Large is ready.
pause

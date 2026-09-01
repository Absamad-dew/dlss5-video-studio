@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NeuralModels.ps1"
if errorlevel 1 (
  echo.
  echo Model installation did not finish. See the message above.
  pause
  exit /b 1
)
echo.
echo Neural model verification completed.
pause

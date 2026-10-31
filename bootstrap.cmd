@echo off
rem One-stop setup wizard for a new project from this template. Double-click it, or run it from PowerShell / cmd.
rem Same as: powershell -ExecutionPolicy Bypass -File tools\bootstrap.ps1  (prefers PowerShell 7 when installed)
cd /d "%~dp0"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\bootstrap.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\bootstrap.ps1" %*
)
set RC=%ERRORLEVEL%
rem Keep the window open when started by double-click
echo %cmdcmdline% | find /i "/c" >nul && pause
exit /b %RC%

@echo off
rem Wrapper so tools\codex-local.ps1 runs regardless of PowerShell execution policy (prefers pwsh 7).
where pwsh >/dev/null 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-local.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-local.ps1" %*
)
exit /b %ERRORLEVEL%

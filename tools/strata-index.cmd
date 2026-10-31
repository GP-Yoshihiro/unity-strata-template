@echo off
rem Wrapper so tools\strata-index.ps1 runs regardless of PowerShell execution policy (prefers pwsh 7).
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0strata-index.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strata-index.ps1" %*
)
exit /b %ERRORLEVEL%

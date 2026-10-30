@echo off
setlocal
if /I "%SystemDrive%"=="X:" tzutil /s "Korea Standard Time" >nul 2>&1
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect.ps1"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%

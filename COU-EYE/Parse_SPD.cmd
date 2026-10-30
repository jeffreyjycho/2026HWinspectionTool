@echo off
setlocal
title COU-EYE V1.1 RAM SPD Import
set "PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Parse_SPD.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo SPD IMPORT: COMPLETE) else (echo SPD IMPORT: REVIEW REQUIRED - exit %RC%)
pause
exit /b %RC%

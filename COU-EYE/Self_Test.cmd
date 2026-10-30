@echo off
setlocal
title COU-EYE V1.1 Self Test
cd /d "%~dp0"
set "PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Self_Test.ps1"
set "RC=%ERRORLEVEL%"
echo.
if errorlevel 1 (echo SELF TEST: FAIL) else (echo SELF TEST: PASS)
pause
exit /b %RC%

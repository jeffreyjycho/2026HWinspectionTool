@echo off
setlocal
title COU-EYE V1.0 ROM PARSER
cd /d "%~dp0"
set "PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
if not exist "%PS%" (echo [ERROR] PowerShell not found & pause & exit /b 1)
echo ============================================
echo   COU-EYE V1.0 - UNIVERSAL ROM PARSER
echo ============================================
echo Put .rom files in ROM_INBOX and run this file.
echo.
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Parse_ROM.ps1" -Path "%~dp0ROM_INBOX"
pause

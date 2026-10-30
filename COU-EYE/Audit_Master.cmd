@echo off
setlocal
title COU-EYE V1.0 - Korea Product Master Audit
cd /d "%~dp0"
set "PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
echo ============================================
echo   COU-EYE V1.0 - MASTER AUDIT
echo ============================================
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Audit_Master.ps1"
pause

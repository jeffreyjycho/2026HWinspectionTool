@echo off
setlocal
if /I "%SystemDrive%"=="X:" tzutil /s "Korea Standard Time" >nul 2>&1
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (echo PowerShell not found. & pause & exit /b 1)
"%PS%" -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0COU_EYE_UI.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (echo COU-EYE UI could not start. WinPE requires PowerShell and .NET Windows Forms. & pause)
exit /b %RC%
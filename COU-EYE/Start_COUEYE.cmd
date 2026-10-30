@echo off
if /I "%SystemDrive%"=="X:" tzutil /s "Korea Standard Time" >nul 2>&1
call "%~dp0Start_COUI.cmd"
exit /b %ERRORLEVEL%

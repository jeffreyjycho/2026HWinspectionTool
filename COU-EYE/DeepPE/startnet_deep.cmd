@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "TRACE=X:\COUEYE_BOOT_TRACE.log"
set "SESSION=%RANDOM%_%RANDOM%"
echo DEEP>X:\Windows\System32\COUEYE_DEEP_SESSION.tag
call :LOG STARTNET_ENTERED patch=1.3.11-bootlog1
call :LOG WPEINIT_BEGIN
wpeinit >>"%TRACE%" 2>&1
set "WPE_RC=%ERRORLEVEL%"
call :LOG WPEINIT_RETURNED RC=%WPE_RC%
tzutil /s "Korea Standard Time" >nul 2>&1
call :LOG VOLUME_SEARCH_BEGIN
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\COUEYE_DATA.TAG" if exist "%%D:\COU-EYE\COUEYE.TAG" (
 set "APP=%%D:\COU-EYE"
 goto :FOUND
)
call :LOG DATA_APP_NOT_FOUND
goto :END
:FOUND
call :LOG DATA_APP_FOUND %APP%
if not exist "%APP%\DeepPE\Working\DEEP_PENDING.json" (
 call :LOG PENDING_NOT_FOUND
 goto :END
)
call :LOG PENDING_FOUND
set "PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
 call :LOG POWERSHELL_NOT_FOUND
 goto :END
)
echo COU-EYE Headless Deep Evidence PE
echo Display output may reset. Results are saved before ONE automatic CoreSafe return reboot.
echo If internal Windows starts after reboot, select this USB again from the boot menu.
call :LOG POWERSHELL_LAUNCH
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%APP%\DeepPE\Boot_Entry.ps1" -PendingFile "%APP%\DeepPE\Working\DEEP_PENDING.json" >>"%TRACE%" 2>&1
set "PS_RC=%ERRORLEVEL%"
call :LOG POWERSHELL_RETURNED RC=%PS_RC%
goto :END
:LOG
echo [%DATE% %TIME%] session=%SESSION% %* >>"%TRACE%"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
 if exist "%%D:\COUEYE_DATA.TAG" (
  if not exist "%%D:\COU-EYE\Logs\Boot" mkdir "%%D:\COU-EYE\Logs\Boot" >nul 2>&1
  copy /y "%TRACE%" "%%D:\COU-EYE\Logs\Boot\startnet_%SESSION%.log" >nul 2>&1
 )
 if exist "%%D:\COUEYE_BOOT.TAG" (
  if not exist "%%D:\COUEYE_BOOT_TRACE" mkdir "%%D:\COUEYE_BOOT_TRACE" >nul 2>&1
  copy /y "%TRACE%" "%%D:\COUEYE_BOOT_TRACE\startnet_%SESSION%.log" >nul 2>&1
 )
)
exit /b 0
:END
call :LOG STARTNET_SHELL_WAIT
echo COU-EYE startup stopped. See Logs\Boot or COUEYE_BOOT_TRACE.
cmd.exe
goto :END

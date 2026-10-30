@echo off
wpeinit
tzutil /s "Korea Standard Time" >nul 2>&1

echo.
echo ==========================================
echo          COU-EYE Corporate WinPE
echo ==========================================
echo Searching for COU-EYE...
echo.

for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\COU-EYE\COUEYE.TAG" (
        echo COU-EYE found on %%D:
        call "%%D:\COU-EYE\Start_COUEYE.cmd"
        goto :END
    )
)

echo [ERROR] COU-EYE application was not found.
echo Expected: \COU-EYE\COUEYE.TAG
cmd.exe
:END

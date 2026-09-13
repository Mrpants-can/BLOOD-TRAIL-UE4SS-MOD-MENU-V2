@echo off
title Blood Trail Mod Menu - auto-open setup
cd /d "%~dp0"

rem Installs a small background watcher that opens the Mod Menu control panel
rem whenever Blood Trail starts - no matter how you launched it: Oculus / Meta
rem Quest Link, the Oculus dash inside the headset, Steam, SteamVR, or the exe.
rem
rem Run this file again to turn it off.

set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "LINK=%STARTUP%\Blood Trail Mod Menu Watcher.lnk"

if exist "%LINK%" (
    del "%LINK%"
    taskkill /F /IM pythonw.exe /FI "WINDOWTITLE eq ModMenuWatcher*" >nul 2>&1
    echo.
    echo   Auto-open REMOVED.
    echo   The Mod Menu will no longer open by itself.
    echo   You can still open it with "Launch Mod Menu.bat".
    echo.
    pause
    exit /b 0
)

rem Prefer pythonw so there is no console window at any point.
where pythonw >nul 2>&1
if %errorlevel%==0 (
    set "PYW=pythonw.exe"
) else (
    where pyw >nul 2>&1
    if %errorlevel%==0 (
        set "PYW=pyw.exe"
    ) else (
        echo.
        echo   Python was not found, so the watcher cannot run.
        echo   Install it from https://www.python.org/downloads/
        echo   and tick "Add python.exe to PATH".
        echo.
        pause
        exit /b 1
    )
)

powershell -NoProfile -Command ^
  "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%LINK%');" ^
  "$s.TargetPath='%PYW%';" ^
  "$s.Arguments='\"%~dp0ModMenuWatcher.pyw\"';" ^
  "$s.WorkingDirectory='%~dp0';" ^
  "$s.WindowStyle=7;" ^
  "$s.Description='Opens the Blood Trail Mod Menu when the game starts';" ^
  "$s.Save()"

if not exist "%LINK%" (
    echo.
    echo   Could not create the shortcut.
    echo.
    pause
    exit /b 1
)

rem start it now too, so it works this session without a reboot
start "" "%PYW%" "%~dp0ModMenuWatcher.pyw"

echo.
echo   Auto-open ENABLED.
echo.
echo   The Mod Menu will now open by itself whenever Blood Trail starts -
echo   including when you launch from Oculus / Meta Quest Link or from
echo   inside the headset. It closes again when you quit the game.
echo.
echo   It is running now, and will start with Windows from here on.
echo   Run this file again to turn it off.
echo.
pause

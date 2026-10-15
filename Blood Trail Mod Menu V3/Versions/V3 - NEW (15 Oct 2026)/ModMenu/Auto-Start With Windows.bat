@echo off
title Blood Trail Mod Menu - auto-start setup
cd /d "%~dp0"

rem Puts a shortcut to the control panel in the Windows Startup folder, so it is
rem already running whenever you play - no need to remember to launch it.
rem Run this file again to remove it.

set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "LINK=%STARTUP%\Blood Trail Mod Menu.lnk"

if exist "%LINK%" (
    del "%LINK%"
    echo.
    echo   Auto-start REMOVED.
    echo   The Mod Menu will no longer open by itself.
    echo.
    pause
    exit /b 0
)

powershell -NoProfile -Command ^
  "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%LINK%');" ^
  "$s.TargetPath='%~dp0Launch Mod Menu.bat';" ^
  "$s.WorkingDirectory='%~dp0';" ^
  "$s.WindowStyle=7;" ^
  "$s.Description='Blood Trail Mod Menu control panel';" ^
  "$s.Save()"

if exist "%LINK%" (
    echo.
    echo   Auto-start ENABLED.
    echo   The Mod Menu control panel will now open when Windows starts.
    echo   Run this file again to turn it off.
    echo.
) else (
    echo.
    echo   Could not create the shortcut.
    echo   You can still use "Play Blood Trail (with Mod Menu).bat" instead.
    echo.
)
pause

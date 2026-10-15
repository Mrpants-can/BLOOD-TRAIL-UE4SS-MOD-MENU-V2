@echo off
title Blood Trail + Mod Menu
cd /d "%~dp0"

rem Starts the game, and makes sure the control panel is up.
rem
rem If the auto-open watcher is installed it will open the panel by itself when
rem the game appears, so this script does NOT open one as well - that is what
rem produced two Mod Menu windows. The panel also refuses to start twice, so
rem even if both paths fire you still get a single window.

set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "WATCHER=%STARTUP%\Blood Trail Mod Menu Watcher.lnk"

if exist "%WATCHER%" (
    rem watcher is installed - it will handle the panel
    goto launchgame
)

rem no watcher: open the panel ourselves, windowless
where pyw >nul 2>&1
if %errorlevel%==0 (
    start "" pyw "BloodTrailModMenu.py"
    goto launchgame
)
where pythonw >nul 2>&1
if %errorlevel%==0 (
    start "" pythonw "BloodTrailModMenu.py"
    goto launchgame
)
echo   Python not found - the control panel will not open.
echo   The in-game menu still works: press Insert.
timeout /t 4 >nul

:launchgame
start "" "steam://rungameid/1032430"
exit /b 0

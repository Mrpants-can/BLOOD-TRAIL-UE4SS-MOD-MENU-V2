@echo off
rem Blood Trail Mod Menu - starts the desktop app for the MUSIC tab.
rem
rem The in-game MUSIC tab runs this by itself when you press a button and the
rem app is not open, so you never have to take the headset off. You can also
rem double-click it. The app opens minimised, and when it was started this way
rem it closes itself again a little while after you quit the game.
rem
rem It must never wait for anything: the game waits for this to hand over.
cd /d "%~dp0"

where pyw >nul 2>&1
if %errorlevel%==0 (
    start "" /min pyw "BloodTrailModMenu.py" --from-game
    exit /b 0
)

where pythonw >nul 2>&1
if %errorlevel%==0 (
    start "" /min pythonw "BloodTrailModMenu.py" --from-game
    exit /b 0
)

if exist "Blood Trail Mod Menu.exe" (
    start "" /min "Blood Trail Mod Menu.exe" --from-game
    exit /b 0
)

exit /b 1

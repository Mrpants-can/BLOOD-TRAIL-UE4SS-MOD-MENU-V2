@echo off
title Blood Trail Mod Menu
cd /d "%~dp0"

rem pyw / pythonw open the window WITHOUT leaving a black console box on top of
rem it. If the app hits a fatal error it shows a popup itself, so nothing is
rem lost by hiding the console.

where pyw >nul 2>&1
if %errorlevel%==0 (
    start "" pyw "BloodTrailModMenu.py"
    exit /b 0
)

where pythonw >nul 2>&1
if %errorlevel%==0 (
    start "" pythonw "BloodTrailModMenu.py"
    exit /b 0
)

rem No windowed launcher - fall back to the console versions.
where py >nul 2>&1
if %errorlevel%==0 (
    py "BloodTrailModMenu.py"
    goto ended
)

where python >nul 2>&1
if %errorlevel%==0 (
    python "BloodTrailModMenu.py"
    goto ended
)

echo.
echo   Python is not installed, or is not on your PATH.
echo   Get it from https://www.python.org/downloads/
echo   and tick "Add python.exe to PATH" during setup.
echo.
pause
exit /b 1

:ended
if errorlevel 1 (
    echo.
    echo   The mod menu closed with an error - the message above says why.
    echo.
    pause
)

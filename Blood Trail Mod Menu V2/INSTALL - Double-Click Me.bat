@echo off
setlocal enabledelayedexpansion
title Blood Trail Mod Menu - Installer

echo.
echo   ================================================
echo     BLOOD TRAIL MOD MENU  -  INSTALLER
echo   ================================================
echo.

REM Where this package lives, so the .bat works from any drive or folder.
set "PKG=%~dp0"
if "%PKG:~-1%"=="\" set "PKG=%PKG:~0,-1%"

REM ---------------------------------------------------------------
REM Find the game. The usual Steam path first, then every other drive,
REM so a library on D:, E: or an external disk still gets found.
REM ---------------------------------------------------------------
set "GAME="

if exist "D:\SteamLibrary\steamapps\common\Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe" (
    set "GAME=D:\SteamLibrary\steamapps\common\Blood Trail\BTVR\Binaries\Win64"
)

if not defined GAME (
    echo   Looking for Blood Trail...
    for %%D in (C D E F G H I J K L) do (
        if not defined GAME (
            if exist "%%D:\SteamLibrary\steamapps\common\Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe" (
                set "GAME=%%D:\SteamLibrary\steamapps\common\Blood Trail\BTVR\Binaries\Win64"
            )
        )
        if not defined GAME (
            if exist "%%D:\Program Files (x86)\Steam\steamapps\common\Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe" (
                set "GAME=%%D:\Program Files (x86)\Steam\steamapps\common\Blood Trail\BTVR\Binaries\Win64"
            )
        )
        if not defined GAME (
            if exist "%%D:\Steam\steamapps\common\Blood Trail\BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe" (
                set "GAME=%%D:\Steam\steamapps\common\Blood Trail\BTVR\Binaries\Win64"
            )
        )
    )
)

if not defined GAME (
    echo.
    echo   Could not find Blood Trail automatically.
    echo.
    echo   No problem - you can install it by hand:
    echo     1. Open the ModMenu folder next to this file
    echo     2. Copy it
    echo     3. Paste it into your game's folder, here:
    echo          Blood Trail\BTVR\Binaries\Win64\Mods\
    echo.
    echo   Or drag your Win64 folder onto this file to install there.
    echo.
    pause
    exit /b 1
)

echo   Found the game:
echo     %GAME%
echo.

REM UE4SS must already be installed - Mods folder is the giveaway.
if not exist "%GAME%\Mods" (
    echo   WARNING: no Mods folder in the game.
    echo   That usually means UE4SS is not installed yet.
    echo   Installing anyway - the folder will be created.
    echo.
)

echo   Installing the mod menu...
robocopy "%PKG%\ModMenu" "%GAME%\Mods\ModMenu" /E /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
    echo.
    echo   Copy FAILED. If the game is running, close it and try again.
    echo   If it still fails, right-click this file and Run as administrator.
    echo.
    pause
    exit /b 1
)

REM Keep any settings that are already there rather than wiping them.
if not exist "%GAME%\Mods\ModMenu\control.txt" (
    echo seq=0> "%GAME%\Mods\ModMenu\control.txt"
    echo action=>> "%GAME%\Mods\ModMenu\control.txt"
    echo arg=>> "%GAME%\Mods\ModMenu\control.txt"
)

echo.
echo   ================================================
echo     DONE - the mod menu is installed.
echo   ================================================
echo.
echo   How to play:
echo     - Double-click "Play Blood Trail (with Mod Menu).bat"
echo       (or just launch the game normally)
echo     - In the headset, press INSERT or NUMPAD 0 for the menu
echo     - On the desktop, the control panel opens by itself
echo.
echo   Want the panel to open every time the game does?
echo     Double-click "Auto-Open With The Game.bat"
echo.
pause

@echo off
title Blood Trail Mod Menu V3 - Install
rem Puts the newest version in the Versions folder into your game.
rem Finds the game by itself, sets up UE4SS if it is missing, keeps your
rem settings, and saves the version you had first. All the work is done by
rem "Switcher files\VersionSwitcher.ps1".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switcher files\VersionSwitcher.ps1" -Install
echo.
pause

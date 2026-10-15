@echo off
rem Opens the Version Switcher window: pick the version you want, click it.
rem The work is done by "Switcher files\VersionSwitcher.ps1".
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Switcher files\VersionSwitcher.ps1"

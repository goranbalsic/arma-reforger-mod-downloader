@echo off
title Stop - Reforger Mod Manager
echo Stopping the helper processes (watchdog, addon mirror) for this folder...
echo The game server and your mods are not touched.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0stop.ps1'"
echo.
pause

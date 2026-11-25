@echo off
title Update - Reforger Mod Manager
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0update.ps1' -Install"
echo.
pause

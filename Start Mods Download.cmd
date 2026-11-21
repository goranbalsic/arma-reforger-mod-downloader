@echo off
title Arma Reforger Mods Download
echo Starting the Mod Manager... a browser window will open at http://localhost:8123/
echo Keep this window open while it runs. Close it when you are done.
echo.
rem say something only when a newer version exists (silent when offline)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0update.ps1' -Quiet"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0download-web.ps1'"
echo.
echo The Mod Manager has stopped.
pause

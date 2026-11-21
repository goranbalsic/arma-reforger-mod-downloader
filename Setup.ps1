# One-time setup. Creates the download engine this tool needs.
#
# The Workshop has no public download link: files are served only to a signed-in
# game or to the free Arma Reforger dedicated server. So the tool uses that server
# as its downloader. This script installs it once, with Steam's anonymous login, so
# no Steam account is needed.
$ErrorActionPreference = 'Stop'
$Root   = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Engine = Join-Path $Root 'armar-server'
$Steam  = Join-Path $Root 'steamcmd'
$Exe    = Join-Path $Engine 'ArmaReforgerServer.exe'
$AppId  = '1874900'   # Arma Reforger dedicated server

if (Test-Path $Exe) {
  Write-Host 'The download engine is already installed. Nothing to do.' -ForegroundColor Green
  exit 0
}

Write-Host '=== Setup: Reforger Mod Manager ===' -ForegroundColor Cyan
Write-Host 'This downloads about 12 GB, once. Most of it is the free dedicated'
Write-Host 'server, which the tool uses as a download engine.'
Write-Host ''

if (-not (Test-Path (Join-Path $Steam 'steamcmd.exe'))) {
  Write-Host '1/2  Downloading the installer (SteamCMD, ~800 KB)...' -ForegroundColor Yellow
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $zip = Join-Path $Root 'steamcmd.zip'
  Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing -TimeoutSec 600
  New-Item -ItemType Directory -Force $Steam | Out-Null
  Expand-Archive -Path $zip -DestinationPath $Steam -Force
  Remove-Item $zip -Force
} else {
  Write-Host '1/2  SteamCMD is already here.' -ForegroundColor Green
}

Write-Host '2/2  Downloading the engine (~12 GB). Progress is printed below; this' -ForegroundColor Yellow
Write-Host '     can take a while.'
# The path is passed as a plain argument on purpose: embedding quote characters
# (as an earlier version did) makes SteamCMD fail with "Missing configuration".
$scArgs = @('+force_install_dir', $Engine, '+login', 'anonymous', '+app_update', $AppId, 'validate', '+quit')
& (Join-Path $Steam 'steamcmd.exe') @scArgs
$code = $LASTEXITCODE

Write-Host ''
if (Test-Path $Exe) {
  Write-Host 'Download engine installed.' -ForegroundColor Green
  exit 0
}
Write-Host "The engine did not install (SteamCMD exit code $code)." -ForegroundColor Red
Write-Host 'Things to try:'
Write-Host '  - run this setup again (the download resumes)'
Write-Host '  - check that you are online and that the disk has ~20 GB free'
Write-Host "  - look at $Steam\logs\console_log.txt for the exact error"
exit 1

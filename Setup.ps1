# One-time setup. Creates the download engine this tool needs.
#
# The Workshop has no public download link: files are served only to a signed-in
# game or to the free Arma Reforger dedicated server. So the tool uses that server
# as its downloader. This script installs it once, with Steam's anonymous login, so
# no Steam account is needed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'state.ps1')
$Root   = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Engine = Join-Path $Root 'armar-server'
$Steam  = Join-Path $Root 'steamcmd'
$Exe    = Join-Path $Engine 'ArmaReforgerServer.exe'
$AppId  = '1874900'   # Arma Reforger dedicated server
$SteamCmdDigest = 'sha256:7669b170dee42db8ee2273775ed7dfb2d173bdba1b849f70d2c7b379290bce13'

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
  $zip = Join-Path $Root ('steamcmd-' + [guid]::NewGuid().ToString('N') + '.zip')
  try {
    Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing -TimeoutSec 600 -MaximumRedirection 2
    if (!(Test-Sha256 $zip $SteamCmdDigest)) {
      throw 'Valve changed the SteamCMD installer. Update the downloader before trying again.'
    }
    New-Item -ItemType Directory -Force $Steam | Out-Null
    Expand-ProjectArchive $zip $Steam
  } finally {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  }
} else {
  Write-Host '1/2  SteamCMD is already here.' -ForegroundColor Green
}

Write-Host '2/2  Downloading the engine (~12 GB). Progress is printed below; this' -ForegroundColor Yellow
Write-Host '     can take a while.'
$steamCmd = Join-Path $Steam 'steamcmd.exe'
$steamLog = Join-Path $Steam 'logs\console_log.txt'
# On a fresh SteamCMD install the anonymous app cache can be missing the server
# entry. Refresh it after login before requesting the depot.
$scArgs = @('+force_install_dir', $Engine, '+login', 'anonymous',
  '+app_info_update', '1', '+app_update', $AppId, 'validate', '+quit')
Push-Location -LiteralPath $Steam
try {
  & $steamCmd @scArgs
  $code = $LASTEXITCODE
  if (!(Test-Path -LiteralPath $Exe) -and
      (Get-Content -LiteralPath $steamLog -Tail 12 -ErrorAction SilentlyContinue |
        Select-String -SimpleMatch "Failed to install app '$AppId' (Missing configuration)")) {
    Write-Host 'Steam has not loaded the server configuration yet. Retrying once...'
    & $steamCmd @scArgs
    $code = $LASTEXITCODE
  }
} finally {
  Pop-Location
}
Write-Host ''
if (Test-Path $Exe) {
  Write-Host 'Download engine installed.' -ForegroundColor Green
  exit 0
}
Write-Host "The engine did not install (SteamCMD exit code $code)." -ForegroundColor Red
Write-Host 'Things to try:'
Write-Host '  - run this setup again (the download resumes)'
Write-Host '  - check that you are online and that the disk has ~20 GB free'
Write-Host "  - look at $(Join-Path (Join-Path $Steam 'logs') 'console_log.txt') for the exact error"
exit 1

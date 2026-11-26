# Rejoin the game addons folder when the downloader was started without it.
param([switch]$Loop)

. (Join-Path $PSScriptRoot 'state.ps1')
$root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$profile = Join-Path $root 'serverprofile'
$addons = Join-Path $profile 'addons'
$config = Join-Path $data 'batch1-serverconfig.json'

function Sync-AddonsFolder {
  $client = Get-ClientAddons $profile
  if ($client -eq $addons) { return $true }
  if ((Get-Item -LiteralPath $addons -Force -ErrorAction SilentlyContinue).LinkType) { return $true }

  try { Initialize-AddonsLink $addons $client $config }
  catch {
    Write-Warning "Could not link the game addons folder: $($_.Exception.Message)"
    $false
  }
}

if (!$Loop) { if (Sync-AddonsFolder) { exit 0 } else { exit 1 } }

$closedIdlePasses = 0
while ($true) {
  $null = Sync-AddonsFolder
  if ($env:RFMM_DESKTOP_OWNER_PID -and !(Get-Process -Id $env:RFMM_DESKTOP_OWNER_PID -ErrorAction SilentlyContinue)) {
    $queued = Get-Queued $config
    if ((Test-Path -LiteralPath (Join-Path $data 'paused.flag')) -or !$queued.Count) { $closedIdlePasses++ }
    else { $closedIdlePasses = 0 }
    if ($closedIdlePasses -ge 3) { break }
  }
  Start-Sleep -Seconds 10
}

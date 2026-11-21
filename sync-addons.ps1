# Copies completed mods into the client addons folder using the shared package check.
param([switch]$Loop)

$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$src = "$Root\serverprofile\addons"
$dst = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"
. "$PSScriptRoot\state.ps1"
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }

# a linked engine folder IS the game folder: there is nothing to copy, and
# robocopy would be handed the same path as source and destination
$srcItem = Get-Item $src -Force -ErrorAction SilentlyContinue
if ($srcItem -and $srcItem.LinkType) { exit 0 }

function Sync-Completed {
  $quietBefore = (Get-Date).AddMinutes(-2)
  $copiesOk = $true
  Get-ChildItem $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_([0-9A-F]{16})$' -and $_.LastWriteTime -le $quietBefore -and
      (Test-AddonComplete $_.FullName $_.LastWriteTime) } |
    ForEach-Object {
      $dir = $_
      $id = [regex]::Match($dir.Name, '(?i)_([0-9A-F]{16})$').Groups[1].Value
      # Reuse the game's folder name for the same Workshop ID.
      $same = @(Get-ChildItem $dst -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "_$id$" })
      $target = if ($same.Count) { $same[0].FullName } else { Join-Path $dst $dir.Name }
      if ($same.Count -and $same[0].LinkType) { return }
      if ($same.Count -and (Test-AddonComplete $target $same[0].LastWriteTime)) {
        $sourceVersion = $null
        $targetVersion = $null
        if ([version]::TryParse((Get-InstalledVersion $dir.FullName), [ref]$sourceVersion) -and
            [version]::TryParse((Get-InstalledVersion $target), [ref]$targetVersion) -and
            $sourceVersion -le $targetVersion) { return }
      }
      robocopy $dir.FullName $target /E /XJ /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
      if ($LASTEXITCODE -ge 8) { $copiesOk = $false; Write-Host "copy failed: $($dir.Name)" -ForegroundColor Red }
    }
  $copiesOk
}

# Serialize manual and background copies into the same game addons folder.
$mutex = [System.Threading.Mutex]::new($false, 'ReforgerSyncLoop')
if (-not $mutex.WaitOne(0)) { Write-Host 'another sync is already running' -ForegroundColor Yellow; exit 0 }

if (-not $Loop) { if (Sync-Completed) { exit 0 } else { Write-Host 'sync failed' -ForegroundColor Red; exit 1 } }

$miss = 0
$closedIdlePasses = 0
while ($true) {
  if (Sync-Completed) { $miss = 0 }
  else {
    $miss++
    if ($miss -eq 3) { Write-Host "sync failed - still retrying every 60 s" -ForegroundColor Yellow }
  }
  if ($env:RFMM_DESKTOP_OWNER_PID -and !(Get-Process -Id $env:RFMM_DESKTOP_OWNER_PID -ErrorAction SilentlyContinue)) {
    $queued = Get-Queued (Join-Path $Data 'batch1-serverconfig.json')
    if ((Test-Path -LiteralPath (Join-Path $Data 'paused.flag')) -or !$queued.Count) { $closedIdlePasses++ }
    else { $closedIdlePasses = 0 }
    if ($closedIdlePasses -ge 3) { break }
  }
  Start-Sleep 60
}

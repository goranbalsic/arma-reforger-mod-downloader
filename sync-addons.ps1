# Mirrors completed mods into the client addons folder. robocopy /MIR = exact
# replica, safe to re-run. The dashboard's /status completed list is the SINGLE
# completion rule (assembled + quiet + size match) - this script never guesses.
param([switch]$Loop)

$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$src = "$Root\serverprofile\addons"
$dst = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"
$Url = 'http://localhost:8123/status'

# a linked engine folder IS the game folder: there is nothing to copy, and
# robocopy would be handed the same path as source and destination
$srcItem = Get-Item $src -Force -ErrorAction SilentlyContinue
if ($srcItem -and $srcItem.LinkType) { exit 0 }

function Sync-Completed {
  try { $s = Invoke-RestMethod $Url -TimeoutSec 10 } catch { return $false }   # dashboard down -> caller decides
  $copiesOk = $true
  Get-ChildItem $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_([0-9A-F]{16})$' -and $s.recent.id -contains $Matches[1] } |
    ForEach-Object {
      $dir = $_
      $id = [regex]::Match($dir.Name, '(?i)_([0-9A-F]{16})$').Groups[1].Value
      # one folder per mod id: an older copy under another name would make the
      # game mount the same mod twice, and /MIR would fill both
      $same = @(Get-ChildItem $dst -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "_$id$" })
      $target = if ($same.Count) { $same[0].FullName } else { Join-Path $dst $dir.Name }
      $same | Select-Object -Skip 1 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
      robocopy $dir.FullName $target /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
      if ($LASTEXITCODE -ge 8) { $copiesOk = $false; Write-Host "copy failed: $($dir.Name)" -ForegroundColor Red }
    }
  $copiesOk
}

# one writer at a time, including the one-shot form: robocopy /MIR deletes in the
# destination, so a manual run during the loop's copy can delete files it is
# still writing. The mutex kills that race.
$mutex = [System.Threading.Mutex]::new($false, 'ReforgerSyncLoop')
if (-not $mutex.WaitOne(0)) { Write-Host 'another sync is already running' -ForegroundColor Yellow; exit 0 }

if (-not $Loop) { if (Sync-Completed) { exit 0 } else { Write-Host 'sync failed' -ForegroundColor Red; exit 1 } }

$miss = 0
while ($true) {
  if (Sync-Completed) { $miss = 0 }
  else {
    # a single failed /status fetch must not silently stop the mirror forever
    $miss++
    # keep retrying: the dashboard is often restarted for a few minutes and this
    # loop is the only thing that mirrors finished mods into the game folder
    if ($miss -eq 3) { Write-Host "sync failed - still retrying every 60 s" -ForegroundColor Yellow }
  }
  Start-Sleep 60
}

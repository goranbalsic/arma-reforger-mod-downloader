# Fill in non-exact / zero sizes in batch1-sizes.json via /v2/mods/{id} (60 req/min).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'state.ps1')
. (Join-Path $PSScriptRoot 'workshop-api.ps1')
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$ver = ((Get-Content (Join-Path $PSScriptRoot 'version.txt') -Raw -ErrorAction SilentlyContinue) -replace '\s', '')
$h = @{ 'User-Agent' = "arma-reforger-mod-downloader/$(if ($ver) { $ver } else { 'dev' })" }
$p = Join-Path $Data 'batch1-sizes.json'
$j = Read-Json $p $null
# a 0-byte file parses to $null; piping that produced one bogus "need" entry and
# then wrote "mods": null, which every other script reads as "no sizes at all"
if (-not $j -or -not $j.mods) { throw "$p has no mods map - restore it instead of overwriting it" }
$mods = $j.mods
$need = @($mods.PSObject.Properties | Where-Object { -not $_.Value.exact -or -not $_.Value.bytes })
"to fetch: $($need.Count)"
$updates = @{}
foreach ($e in $need) {
  try {
    $m = Invoke-WorkshopApi -Uri "https://api.reforgermods.net/v2/mods/$($e.Name)" -Headers $h -TimeoutSec 30
    if ($m.mod -and $m.mod.size) {
      $updates[$e.Name] = @{ name = $m.mod.name; bytes = $m.mod.size; exact = $true }
    }
  } catch { "skip $($e.Name): $($_.Exception.Message)" }
  Start-Sleep -Milliseconds 1200   # stay under 60/min
}
$mutex = Lock-WorkshopState $Data
try {
  $latest = Read-Json $p $null
  if (!$latest -or !$latest.mods) { throw "$p has no mods map - restore it instead of overwriting it" }
  $done = 0
  foreach ($id in $updates.Keys) {
    $current = $latest.mods.PSObject.Properties[$id]
    if ($current -and (!$current.Value.exact -or !$current.Value.bytes)) {
      $latest.mods.$id = $updates[$id]
      $done++
    }
  }
  $total = [double]($latest.mods.PSObject.Properties | ForEach-Object { [double]$_.Value.bytes } | Measure-Object -Sum).Sum
  Save-Json @{ totalBytes = $total; mods = $latest.mods } $p 4
} finally { Unlock-WorkshopState $mutex }
"updated $done sizes; new total {0:N2} GB" -f ($total / 1GB)

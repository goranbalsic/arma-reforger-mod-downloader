# Keep only unfinished mods in the engine config to stay within the 1 MB download-list response limit.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
. (Join-Path $PSScriptRoot 'state.ps1')
$cfgPath = Join-Path $Data 'batch1-serverconfig.json'
$addons  = Join-Path (Join-Path $Root 'serverprofile') 'addons'


$ctl = Lock-Engine
if (-not $ctl) {
  "another start/stop is in progress - config and partial folders left alone"
  exit 1
}
try {
  $eng = Get-OwnEngine $cfgPath
  if ($null -eq $eng) {
    "cannot read the process list right now - config and partial folders left alone"
    exit 1
  }
  if (@($eng).Count) {
    "engine is running - config and partial folders left alone"
    exit 1
  }
  Initialize-EngineAddonsDirectory $addons
  $j = Read-EngineConfig $cfgPath

  $done = @{}
  # Validate only the queued mods.
  foreach ($m in @($j.game.mods)) {
    $mid = Test-ModId $m.modId
    if (-not $mid) { "skipping a queued entry with an invalid mod id: $($m.modId)"; continue }
    if ($done.ContainsKey($mid)) { continue }
    $d = Get-ChildItem $addons -Directory -Filter "*_$mid" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m.version -and $d -and (Get-InstalledVersion $d.FullName) -ne $m.version) { continue }
    if ($d -and (Test-AddonComplete $d.FullName $d.LastWriteTime)) { $done[$mid] = $true }
  }
  "assembled on disk: $($done.Count)"

  $left = @($j.game.mods | Where-Object { (Test-ModId $_.modId) -and -not $done.ContainsKey($_.modId) })
  "config: $(@($j.game.mods).Count) -> remaining: $($left.Count)"

  # Remove incomplete addons only when their markers cause the engine to skip them. Hold the engine lock through cleanup and the config write.
  $j.game.mods = $left
  $reFile = Join-Path $Data 'redownload.json'
  $re = Read-Json $reFile ([pscustomobject]@{})
  $now = Get-Date
  foreach ($m in $left) {
    $mid = Test-ModId $m.modId
    if (-not $mid) { "skipping a queued entry with an invalid mod id: $($m.modId)"; continue }
    $d = Get-ChildItem $addons -Directory -Filter "*_$mid" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d -or $m.version) { continue }  # the engine updates pinned revisions in place
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'addon.gproj'))) { continue }
    # Allow one cleanup attempt per mod every 30 minutes.
    $last = $re.PSObject.Properties[$mid]
    if ($last -and $last.Value) {
      $at = [datetime]::MinValue
      if ([datetime]::TryParse([string]$last.Value, [ref]$at) -and ($now - $at).TotalMinutes -lt 30) {
        "kept a partial (already re-downloaded less than 30 min ago): $($d.Name)"
        continue
      }
    }
    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $d.FullName)) {
      $re | Add-Member -NotePropertyName $mid -NotePropertyValue ($now.ToString('s')) -Force
      "deleted unusable partial (the engine would have skipped it): $($d.Name)"
    }
  }
  # Prune cleanup records older than a day.
  foreach ($p in @($re.PSObject.Properties)) {
    $at = [datetime]::MinValue
    if ([datetime]::TryParse([string]$p.Value, [ref]$at) -and ($now - $at).TotalDays -ge 1) { $re.PSObject.Properties.Remove($p.Name) }
  }
  Save-Json $re $reFile 4
  Save-Json $j $cfgPath
  "saved"
} finally { $ctl.ReleaseMutex() }
exit 0

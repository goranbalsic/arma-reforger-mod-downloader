# Trim batch1-serverconfig.json to mods not yet assembled in the DS profile.
# the DS fetches a download list for every config mod, and its 1 MB response
# limit chokes once the list gets big - so the config must only hold what's left.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
. "$PSScriptRoot\state.ps1"
$cfgPath = "$Data\batch1-serverconfig.json"
$addons  = "$Root\serverprofile\addons"


$raw = Get-Content $cfgPath -Raw -ErrorAction SilentlyContinue
$j = Read-Json $cfgPath ($CfgStub | ConvertFrom-Json)
if (-not $raw) { "config was empty or unreadable - recreated" }
# adds name/scenarioId (the engine refuses a config without them) and repairs
# "mods": null, which the DS writes on shutdown
$j = Repair-Cfg $j

$done = @{}
# only the queued mods are checked: the engine's folder is linked into the game
# folder and holds the whole library, and parsing 1000 meta files before every
# engine start made the watchdog crawl. Same completion rule as Get-HaveIds.
foreach ($m in @($j.game.mods)) {
  if (-not $m.modId -or $done.ContainsKey($m.modId)) { continue }
  $d = Get-ChildItem $addons -Directory -Filter "*_$($m.modId)" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($d -and (Test-AddonComplete $d.FullName $d.LastWriteTime)) { $done[$m.modId] = $true }
}
"assembled on disk: $($done.Count)"

$left = @($j.game.mods | Where-Object { -not $done.ContainsKey($_.modId) })
"config: $(@($j.game.mods).Count) -> remaining: $($left.Count)"

# A partial download with addon.gproj/meta/rdb on disk looks installed to the DS,
# so it is skipped forever and the queue never drains. A folder WITHOUT those
# markers is re-fetched by the DS by itself, so only the installed-looking ones
# are deleted. The whole tail - check, delete, config write - runs under the engine
# mutex: the watchdog starts the DS from another process, and it must not start
# while files are being removed or the config is half-written.
$j.game.mods = $left
$reFile = "$Data\redownload.json"
$re = Read-Json $reFile @{}
$now = Get-Date
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
  foreach ($m in $left) {
    $d = Get-ChildItem $addons -Directory -Filter "*_$($m.modId)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d) { continue }
    if (-not (Test-Path (Join-Path $d.FullName 'addon.gproj'))) { continue }
    # one attempt per 30 min: a mod the DS can never finish would otherwise be
    # deleted and downloaded again on every restart, forever
    $last = $re.PSObject.Properties[$m.modId]
    if ($last -and $last.Value) {
      $at = [datetime]::MinValue
      if ([datetime]::TryParse([string]$last.Value, [ref]$at) -and ($now - $at).TotalMinutes -lt 30) {
        "kept a partial (already re-downloaded less than 30 min ago): $($d.Name)"
        continue
      }
    }
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $d.FullName)) {
      $re | Add-Member -NotePropertyName $m.modId -NotePropertyValue ($now.ToString('s')) -Force
      "deleted unusable partial (the engine would have skipped it): $($d.Name)"
    }
  }
  # forget attempts older than a day, so the file never grows past the library
  foreach ($p in @($re.PSObject.Properties)) {
    $at = [datetime]::MinValue
    if ([datetime]::TryParse([string]$p.Value, [ref]$at) -and ($now - $at).TotalDays -ge 1) { $re.PSObject.Properties.Remove($p.Name) }
  }
  Save-Json $re $reFile 4
  Save-Json $j $cfgPath
  "saved"
} finally { $ctl.ReleaseMutex() }

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
# are deleted. Only when no engine is running: never delete files under a live one.
$eng = Get-OwnEngine $cfgPath
if ($null -ne $eng -and @($eng).Count -eq 0) {
  foreach ($m in $left) {
    $d = Get-ChildItem $addons -Directory -Filter "*_$($m.modId)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d) { continue }
    if (-not (Test-Path (Join-Path $d.FullName 'addon.gproj'))) { continue }
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    "deleted unusable partial (the engine would have skipped it): $($d.Name)"
  }
}

$j.game.mods = $left
Save-Json $j $cfgPath
"saved"

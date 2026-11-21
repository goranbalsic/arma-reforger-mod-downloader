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

# A partial download has addon.gproj/meta/rdb on disk, so the DS can believe it
# is installed and never fetch it again. Delete only files that have not been
# touched for 15 minutes: a fresh partial may be resumed by the next run and
# deleting it would throw that progress away.
if (-not (Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue)) {
  foreach ($m in $left) {
    $d = Get-ChildItem $addons -Directory -Filter "*_$($m.modId)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d) { continue }
    # the newest FILE, not the folder: the DS appends inside <mod>\temp\ and never
    # touches the directory time, so a 40-minute download looked 40 minutes stale
    # and got deleted - throwing away every fragment it had fetched
    $newest = (Get-ChildItem $d.FullName -File -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if (-not $newest -or $newest -gt (Get-Date).AddMinutes(-15)) { continue }
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    "deleted stale partial download: $($d.Name)"
  }
}

$j.game.mods = $left
Save-Json $j $cfgPath
"saved"

# Asserts the LIVE completion rule end-to-end: every mod the dashboard calls
# "completed" must satisfy the addon's own meta file list (exact name + size per
# file) and must have finished unpacking its transfer cache. Run while the dashboard
# is up. Also asserts the inverse: any folder the dashboard would treat as "have"
# (resume/queue skip it) must pass the same rule, and a partial folder must stay
# queued - an unqueued partial is never re-downloaded.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
. (Join-Path $PSScriptRoot 'state.ps1')
$s = try {
  $completed = $null
  $deadline = [datetime]::UtcNow.AddSeconds(20)
  do {
    $status = Invoke-RestMethod 'http://localhost:8123/status' -TimeoutSec 10
    $completed = Invoke-RestMethod 'http://localhost:8123/completed' -TimeoutSec 10
    if (!$status.inventoryPending -and $status.recentRev -eq $completed.rev) { break }
    Start-Sleep -Milliseconds 100
  } while ([datetime]::UtcNow -lt $deadline)
  if ($status.inventoryPending -or $status.recentRev -ne $completed.rev) { throw 'The library inventory did not become ready.' }
  $completed
}
     catch { "FAIL dashboard not reachable at http://localhost:8123/ ($($_.Exception.Message))"; exit 1 }
$ds = Get-ClientAddons (Join-Path $Root 'serverprofile')
if (-not (Test-Path $ds)) {
  "FAIL no addons folder at $ds"
  "set RFMM_HOME/RFMM_DATA to the live install (this run would otherwise test the wrong tree)"
  exit 1
}
$fail = 0
foreach ($r in $s.recent) {
  $dir = Get-ChildItem $ds -Directory -Filter "*_$($r.id)" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $dir) { "FAIL no folder: $($r.name)"; $fail++; continue }
  if (Test-Path -LiteralPath (Join-Path $dir.FullName 'temp') -PathType Container) { "FAIL transfer cache remains: $($r.name)"; $fail++ }
  if (-not (Test-AddonComplete $dir.FullName)) { "FAIL meta file list does not match: $($r.name)"; $fail++ }
}

# a folder the dashboard calls complete must not still be queued, and a partial
# folder must be queued - otherwise nothing ever re-downloads it
$queuedIds = @()
$cj = Get-Content -LiteralPath (Join-Path $Data 'batch1-serverconfig.json') -Raw | ConvertFrom-Json
foreach ($m in $cj.game.mods) { $queuedIds += $m.modId }
# a partial is only recoverable while the dashboard still knows the mod: "Queue
# all missing" enumerates the sizes map plus every tracked server's modlist
$tracked = @{}
foreach ($p in (Get-Content -LiteralPath (Join-Path $Data 'batch1-sizes.json') -Raw | ConvertFrom-Json).mods.PSObject.Properties) { $tracked[$p.Name] = $true }
foreach ($sv in (Get-Content -LiteralPath (Join-Path $Data 'batch1-servers.json') -Raw | ConvertFrom-Json).servers) { foreach ($m in $sv.mods) { $tracked[$m.id] = $true } }
Get-ChildItem $ds -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object {
    $id = $Matches[1]
    if (Test-AddonComplete $_.FullName) { return }   # complete, nothing to assert
    if ($s.recent.id -contains $id) { "FAIL partial folder counted as completed: $($_.Name)"; $fail++ }
    else {
      # orphaned: partial and nothing will ever re-fetch it (the bug that
      # stranded 3 AD2 mods). Not being queued right now is fine - Queue all
      # missing picks it up as long as the dashboard tracks the mod.
      if ($queuedIds -contains $id) { "note: partial folder on disk, queued for re-download: $($_.Name)" }
      elseif ($tracked.ContainsKey($id)) { "note: partial folder on disk, 'Queue all missing' re-fetches it: $($_.Name)" }
      else { "FAIL partial folder not tracked by any server or size entry: $($_.Name)"; $fail++ }
    }
  }
# the served page script must be syntactically valid: one stray bracket leaves
# the whole page stuck at "connecting to dashboard..." (that happened)
if (Get-Command node -ErrorAction SilentlyContinue) {
  $page = (Invoke-WebRequest 'http://localhost:8123/' -UseBasicParsing -TimeoutSec 30).Content
  $js = [regex]::Match($page, '(?s)<script\b[^>]*>(.*)</script>').Groups[1].Value
  $tmpJs = Join-Path ([IO.Path]::GetTempPath()) "rfmm-page-$PID.js"
  Set-Content $tmpJs $js -Encoding UTF8
  if (!$js) { 'FAIL dashboard script was not found'; $fail++ }
  node --check $tmpJs 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    # keep node's message: "unexpected token" without a line number is useless
    $why = (& node --check $tmpJs 2>&1 | Select-Object -First 3) -join ' '
    "FAIL dashboard page JavaScript: $why"; $fail++
  }
  else { 'page JS: syntax ok' }
  Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
} else { 'note: node not available - page JS syntax not checked' }

# a truncated state file (a kill during the old non-atomic save) used to kill the
# dashboard before it could serve anything - assert it now starts with defaults
$st = Join-Path ([IO.Path]::GetTempPath()) ('rfmm-statetest-' + [guid]::NewGuid().ToString('N'))
$fixtureData = Join-Path $st 'data'
$fixtureHome = Join-Path $st 'home'
$keepH = $env:RFMM_HOME; $keepD = $env:RFMM_DATA; $keepGame = $env:RFMM_GAME_PROFILE
try {
  New-Item -ItemType Directory -Force $fixtureData, $fixtureHome | Out-Null
  Set-Content -LiteralPath (Join-Path $fixtureData 'batch1-sizes.json') -Value '{"totalBytes":0,"mods":{"66C8A7B6CE49E24D":{"name":"x",' -NoNewline
  Set-Content -LiteralPath (Join-Path $fixtureData 'batch1-serverconfig.json') -Value '{"game":{"mods":[]}}' -NoNewline
  Set-Content -LiteralPath (Join-Path $fixtureData 'batch1-servers.json') -Value '{"servers":[]}' -NoNewline
  $env:RFMM_HOME = $fixtureHome; $env:RFMM_DATA = $fixtureData; $env:RFMM_GAME_PROFILE = Join-Path $st 'game'
  $shellName = if ($IsLinux) { 'pwsh' } else { 'powershell.exe' }
  $check = & (Join-Path $PSHOME $shellName) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'download-web.ps1') -Check
  if ($LASTEXITCODE -ne 0 -or $check -match 'GET-STATUS FAILED') { 'FAIL a truncated state file still stops the dashboard'; $fail++ }
  elseif (-not (Get-ChildItem -LiteralPath $fixtureData -Filter '*.corrupt-*')) { 'FAIL corrupt state file was not quarantined'; $fail++ }
  else { 'state files: truncated json starts with defaults, original kept as .corrupt-*' }
} finally {
  $env:RFMM_HOME = $keepH; $env:RFMM_DATA = $keepD; $env:RFMM_GAME_PROFILE = $keepGame
  Remove-Item -LiteralPath $st -Recurse -Force -ErrorAction SilentlyContinue
}

"checked $($s.recent.Count) completed mods, failures: $fail"
if ($fail) { exit 1 } else { 'OK' }

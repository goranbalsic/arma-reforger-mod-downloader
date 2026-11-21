# Stress test against a RUNNING dashboard: every route, wrong ids, wrong token,
# parallel polls, a server remove/re-add round trip, then the state files are
# checked for damage. It restarts the download at the end.
#
#   powershell -File test-torture.ps1          (exit 0 = everything survived)
#   powershell -File test-torture.ps1 -NoServerRoundTrip
#
# It works on the live install: pause/start and one refresh hit the real queue.
# Nothing is deleted from disk; removing a server only drops it from the list and
# it is added back at the end.
param(
  [string]$Base = 'http://localhost:8123',
  [switch]$NoServerRoundTrip
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $Root 'data' }
$script:checks = 0
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $script:checks++
  if ($Ok) { "  ok   $Name" } else { "  FAIL $Name $(if ($Detail) { "- $Detail" })"; $script:fail++ }
}
function Call([string]$Path, [string]$Method = 'GET', $Body = $null) {
  try {
    $p = @{ Uri = "$Base$Path"; Method = $Method; UseBasicParsing = $true; TimeoutSec = 90 }
    if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
    $r = Invoke-WebRequest @p
    $j = $null; try { $j = $r.Content | ConvertFrom-Json } catch { }
    @{ code = [int]$r.StatusCode; json = $j; content = $r.Content }
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    $body = ''
    try { $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
    $j = $null; try { $j = $body | ConvertFrom-Json } catch { }
    @{ code = $code; json = $j; content = $body }
  }
}
function Status {
  try { (Invoke-WebRequest "$Base/status" -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json } catch { $null }
}

"== the page and the read routes"
$page = Call '/'
Check 'serves the page' ($page.code -eq 200 -and $page.content -match 'Reforger Mods Download')
foreach ($r in '/status', '/servers') {
  $x = Call $r
  Check "$r answers json" ($x.code -eq 200 -and $null -ne $x.json) "code $($x.code)"
}
$s = Status
Check 'status has the fields the page reads' ($null -ne $s -and $null -ne $s.running -and $null -ne $s.queue)
$tok = $s.tok
Check 'status carries the action token' ([bool]$tok)

"== wrong things are refused"
Check 'unknown route is 404'  ((Call '/definitely-not-a-route').code -eq 404)
$noTok = Call '/start' 'POST'
Check 'POST without the token is 403' ($noTok.code -eq 403)
$badTok = Call '/start?t=deadbeef' 'POST'
Check 'POST with a wrong token is 403' ($badTok.code -eq 403)

"== parallel polling (8 clients x 12 polls)"
$jobs = 1..8 | ForEach-Object {
  Start-Job -ScriptBlock {
    param($u)
    $ok = 0
    for ($i = 0; $i -lt 12; $i++) {
      try { if ((Invoke-WebRequest "$u/status" -UseBasicParsing -TimeoutSec 30).StatusCode -eq 200) { $ok++ } } catch { }
    }
    $ok
  } -ArgumentList $Base
}
$null = Wait-Job $jobs -Timeout 180
$parallelOk = @($jobs | Receive-Job) | Measure-Object -Sum
$jobs | Remove-Job -Force -ErrorAction SilentlyContinue
Check 'every parallel poll answered' ($parallelOk.Sum -eq 96) "$($parallelOk.Sum)/96"

"== hammering the buttons"
$startOk = $true
1..5 | ForEach-Object {
  $x = Call "/start?t=$tok" 'POST'
  if ($x.code -ne 200 -or $x.json.ok -ne $true) { $startOk = $false }
}
Check 'five Start clicks in a row all succeed' $startOk
$p = Call "/pause?t=$tok" 'POST'
Check 'Pause succeeds' ($p.code -eq 200 -and $p.json.ok -eq $true)
Check 'pause flag is written' (Test-Path (Join-Path $Data 'paused.flag'))
$r = Call "/start?t=$tok" 'POST'
Check 'Start after Pause succeeds' ($r.code -eq 200 -and $r.json.ok -eq $true)
Check 'Start clears the pause flag' (-not (Test-Path (Join-Path $Data 'paused.flag')))
$v = Call "/verify?t=$tok" 'POST'
Check 'Verify answers' ($v.code -eq 200 -and $v.json.msg -match 'verify')

"== unknown ids are rejected, not crashed on"
foreach ($route in 'refresh-server', 'remove-server', 'make-preset', 'add-server', 'add-mod', 'queue-server') {
  $x = Call "/$route?id=NOTAVALIDID&t=$tok" 'POST'
  Check "$route rejects an unknown id" ($null -ne $x.json -and [bool]$x.json.error) "code $($x.code)"
}

"== one server: refresh, remove, add back"
$servers = (Call '/servers').json.servers
Check 'at least one server is tracked' (@($servers).Count -ge 1)
if (-not $NoServerRoundTrip -and @($servers).Count -ge 1) {
  $victim = @($servers)[-1]
  $before = @($servers).Count
  $rf = Call "/refresh-server?id=$($victim.id)&t=$tok" 'POST'
  Check 'Refresh on a server row answers' ($rf.code -eq 200 -or ($rf.json -and $rf.json.error)) "code $($rf.code)"
  $rm = Call "/remove-server?id=$($victim.id)&t=$tok" 'POST'
  Check 'Remove answers' ($rm.code -eq 200 -and $rm.json.ok -eq $true)
  Check 'server is gone from the list' (@((Call '/servers').json.servers).Count -eq $before - 1)
  $ad = Call "/add-server?id=$($victim.id)&t=$tok" 'POST'
  Check 'it can be added back' (@((Call '/servers').json.servers).Count -eq $before) "msg: $($ad.json.msg)"
}

"== state files survived"
function Read-JsonFile($p) { try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null } }
$cfg = Read-JsonFile (Join-Path $Data 'batch1-serverconfig.json')
Check 'engine config is valid json' ($null -ne $cfg -and $null -ne $cfg.game)
$ids = @($cfg.game.mods | ForEach-Object { $_.modId })
Check 'every queued id is well formed' (@($ids | Where-Object { $_ -notmatch '^[0-9A-F]{16}$' }).Count -eq 0)
Check 'no mod is queued twice' (@($ids).Count -eq @($ids | Select-Object -Unique).Count)
Check 'config still has name and scenario' ([bool]$cfg.game.name -and [bool]$cfg.game.scenarioId)
$sz = Read-JsonFile (Join-Path $Data 'batch1-sizes.json')
Check 'sizes file is valid json' ($null -ne $sz -and $null -ne $sz.mods)
$srv = Read-JsonFile (Join-Path $Data 'batch1-servers.json')
Check 'server list is valid json' ($null -ne $srv -and $null -ne $srv.servers)
$dupeServers = @($srv.servers | Where-Object {
  $m = @($_.mods | ForEach-Object { $_.id }); $m.Count -ne @($m | Select-Object -Unique).Count })
Check 'no server has a repeated mod' ($dupeServers.Count -eq 0)
$dupes = @(Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons" -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_[0-9A-F]{16}$' } |
  Group-Object { [regex]::Match($_.Name, '_([0-9A-F]{16})$').Groups[1].Value } | Where-Object { $_.Count -gt 1 })
Check 'no addon folder exists twice' ($dupes.Count -eq 0) "$($dupes.Count) duplicated id(s)"
$link = Get-Item (Join-Path $Root 'serverprofile\addons') -Force -ErrorAction SilentlyContinue
Check 'engine addons folder is still a link' ([bool]($link -and $link.LinkType))
$after = Status
Check 'dashboard still answers after the beating' ($null -ne $after)

"== leave the download running"
$end = Call "/start?t=$tok" 'POST'
Check 'final Start succeeds' ($end.code -eq 200 -and $end.json.ok -eq $true)

""
"checks: $script:checks   failures: $script:fail"
if ($script:fail) { "TORTURE: FAIL"; exit 1 }
"TORTURE: OK"
exit 0

# Comprehensive local stress test for the downloader backend.
#
#   powershell -File tools\Test-Stress.ps1
#
# Runs in a throwaway install (temp folder, empty game profile, a stub engine that
# only sleeps) against a local mock Workshop API. No internet, no real addons, no
# engine download. Drives the real worker scripts over the desktop stdin protocol,
# including the read-only status worker, and checks the state files after every phase.
param([switch]$RunHttpSuites)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'state.ps1')
$shell = Join-Path $PSHOME $(if ($IsLinux) { 'pwsh' } else { 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('rfmm-stress-' + [guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $tmp 'home'
$data = Join-Path $installRoot 'data'
$game = Join-Path $tmp 'game'
$gameAddons = Join-Path $game 'addons'
$profile = Join-Path $installRoot 'serverprofile'
$engineDir = Join-Path $installRoot 'armar-server'
$configFile = Join-Path $data 'batch1-serverconfig.json'
$addonsDir = $gameAddons
$port = 18765
$api = "http://localhost:$port/v2"
$script:checks = 0
$script:failed = 0
$script:main = $null
$script:read = $null
$script:mock = $null
$script:http = $null

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $script:checks++
  if ($Ok) { "  ok   $Name" } else { "  FAIL $Name $(if ($Detail) { "- $Detail" })"; $script:failed++ }
}
function ReplyText($reply) { @($reply.json.msg) -join '' }
function Cleanup {
  foreach ($p in @($script:main, $script:read, $script:http, $script:mock)) {
    try { if ($p -and -not $p.HasExited) { $p.Kill() } } catch { }
  }
  Get-OwnEngine $configFile | ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
trap { "STRESS ERROR: $($_.Exception.Message)"; Cleanup; exit 1 }

if (Get-EngineProcesses) { "A dedicated server is already running. Close it before the stress test."; exit 2 }
New-Item -ItemType Directory -Force $data, $profile, $engineDir, $gameAddons | Out-Null
$script:gameRunning = @(Get-Process -Name 'ArmaReforger*' -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -notlike 'ArmaReforgerSer*' }).Count -gt 0

# --- stub engine: a process named ArmaReforgerServer.exe that only sleeps ----------
if ($IsLinux) {
  $stub = Join-Path $engineDir 'ArmaReforgerServer'
  $source = Join-Path $tmp 'stub.c'
  Set-Content -LiteralPath $source -Value "#include <unistd.h>`nint main(void) { for (;;) pause(); }"
  & cc -o $stub $source
} else {
  $stub = Join-Path $engineDir 'ArmaReforgerServer.exe'
  $source = Join-Path $tmp 'stub.cs'
  Set-Content -LiteralPath $source 'class P { static void Main() { System.Threading.Thread.Sleep(600000); } }'
  & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe "/out:$stub" $source
}
if ($LASTEXITCODE -ne 0) { throw 'Could not build the stub engine.' }

# --- mock Workshop API -------------------------------------------------------------
$fixture = @{
  serverId = '11111111-1111-1111-1111-111111111111'
  serverName = 'Stress Server'
  vanillaId = '22222222-2222-2222-2222-222222222222'
  mods = @(
    @{ id = 'AAAAAAAAAAAAAAA1'; name = 'Alpha'; version = '2.0.0'; size = 1048576; sizeKnown = $true },
    @{ id = 'AAAAAAAAAAAAAAA2'; name = 'Beta'; version = '1.1.0'; size = 2097152; sizeKnown = $true },
    @{ id = 'AAAAAAAAAAAAAAA3'; name = 'Gamma'; version = '1.0.0'; size = 3145728; sizeKnown = $true }
  )
  serverVersion = @{ AAAAAAAAAAAAAAA2 = '1.0.0' }
  depsId = 'CCCCCCCCCCCCCCC1'
}
Set-Content (Join-Path $tmp 'fixture.json') ($fixture | ConvertTo-Json -Depth 6)
$mockCode = @'
param($port, $fixturePath, $readyPath)
$fx = Get-Content $fixturePath -Raw | ConvertFrom-Json
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Set-Content $readyPath 'ready'
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $path = $ctx.Request.Url.AbsolutePath
    $body = '{"error":"not found"}'
    $query = $ctx.Request.QueryString
    if ($path -eq '/v2/mods' -and $query['page'] -eq '2' -and $query['sort'] -eq 'largest' -and
        $query['search'] -eq 'Alpha & co' -and (($query.GetValues('tags') -join ',') -ceq 'WEAPONS,TERRAINS')) {
      $body = @{ meta = @{ totalMods = 17; totalPages = 2; currentPage = 2 }; data = @(
        @{ id = $fx.mods[0].id; name = $fx.mods[0].name; tags = @('WEAPONS','TERRAINS'); subscriberCount = 20 }
      ) } | ConvertTo-Json -Depth 5
    } elseif ($path -eq '/v2/mods' -and $query['sort'] -eq 'recently-updated') {
      $body = @{ meta = @{ totalPages = 1 }; data = @(
        @{ id = 'AAAAAAAAAAAAAAA1'; name = 'Alpha'; version = '2.1.0'; size = 1048576 },
        @{ id = 'EEEEEEEEEEEEEEEE'; name = 'Not installed'; version = '3.0.0'; size = 50 }
      ) } | ConvertTo-Json -Depth 5
    } elseif ($path -eq '/v2/mods' -or $path -eq '/v2/mods/') {
      $body = @{ meta = @{ totalMods = $fx.mods.Count; totalPages = 1 }; data = @($fx.mods) } | ConvertTo-Json -Depth 5
    } elseif ($path -eq "/v2/mods/$($fx.mods[0].id)/versions/2.0.0") {
      $body = '{"data":{"version":"2.0.0","changelog":"First line\nSecond line"}}'
    } elseif ($path -eq "/v2/mods/$($fx.mods[0].id)/versions") {
      $body = '{"data":{"versions":[{"version":"2.0.0","published":true},{"version":"3.0.0","published":false}]}}'
    } elseif ($path -match '^/v2/mods/([0-9A-Fa-f]{16})/dependencies$') {
      $id = $Matches[1].ToUpperInvariant()
      if ($id -eq $fx.depsId) {
        $deps = @(1..300 | ForEach-Object { @{ id = ('{0:X16}' -f $_); name = "Dep$_"; size = 1024 } })
        $body = @{ data = @{ dependencies = $deps } } | ConvertTo-Json -Depth 5
      } else { $body = @{ data = @{ dependencies = @() } } | ConvertTo-Json -Depth 5 }
    } elseif ($path -match '^/v2/mods/([0-9A-Fa-f]{16})$') {
      $id = $Matches[1].ToUpperInvariant()
      $mod = @($fx.mods | Where-Object { $_.id -eq $id })[0]
      if (!$mod) { $mod = @{ id = $id; name = "Mod $id"; version = '9.9.9'; size = 4096; sizeKnown = $true } }
      if ($id -eq $fx.mods[0].id) {
        $mod | Add-Member -NotePropertyName description -NotePropertyValue 'Alpha description'
        $mod | Add-Member -NotePropertyName dependencies -NotePropertyValue @($fx.mods[1])
        $mod | Add-Member -NotePropertyName screenshots -NotePropertyValue @('https://ar-gcp-cdn.bistudio.com/image/mock/1.jpg')
      }
      $body = @{ mod = $mod } | ConvertTo-Json -Depth 5
    } elseif ($path -eq "/v2/servers/$($fx.vanillaId)") {
      $body = @{ server = @{ id = $fx.vanillaId; name = 'Vanilla Server'; online = $true; modCount = 0 } } | ConvertTo-Json
    } elseif ($path -eq "/v2/servers/$($fx.serverId)/history" -and $query['range'] -eq '7d') {
      $body = '{"points":[{"t":1700000000,"avg":25,"min":20,"max":30,"cap":60}]}'
    } elseif ($path -match '^/v2/servers/([0-9a-fA-F-]{36})$') {
      $mods = @($fx.mods | ForEach-Object {
        $v = if ($fx.serverVersion.PSObject.Properties[$_.id]) { [string]$fx.serverVersion.($_.id) } else { $_.version }
        @{ id = $_.id; name = $_.name; version = $v; size = $_.size; sizeKnown = $true } })
      $invite = @{ id = $fx.serverId; inviteToken = '' } | ConvertTo-Json -Compress
      $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($invite)).TrimEnd('=').Replace('+','-').Replace('/','_')
      $body = @{ server = @{ id = $fx.serverId; name = $fx.serverName; mods = $mods; online = $true; joinable = $true
        joinUrl = "steam://run/1874880//$encoded/" } } | ConvertTo-Json -Depth 6
    } elseif ($path -eq '/v2/servers' -and $query['page'] -eq '2' -and $query['sort'] -eq 'name' -and
        $query['region'] -eq 'new_york' -and $query['platform'] -eq 'psn' -and $query['includeOffline'] -eq 'true' -and
        $query['online'] -eq 'false' -and $query['locked'] -eq 'true' -and $query['official'] -eq 'false' -and
        $query['battleye'] -eq 'true' -and $query['hasMods'] -eq 'true' -and $query['search'] -eq 'Stress & Test') {
      $body = @{ meta = @{ totalPages = 3; totalServers = 60; currentPage = 2 }; data = @(
        @{ id = $fx.serverId; name = $fx.serverName; region = 'new_york'; platforms = @('pc','psn')
           online = $false; passwordProtected = $true; scenarioName = 'Test'; modCount = $fx.mods.Count }
      ) } | ConvertTo-Json -Depth 5
    } elseif ($path -eq '/v2/servers') {
      $body = @{ meta = @{ totalServers = 1; totalPages = 1; currentPage = 1 }; data = @(
        @{ id = $fx.serverId; name = $fx.serverName; players = 3; maxPlayers = 60; online = $true; modCount = $fx.mods.Count }
      ) } | ConvertTo-Json -Depth 5
    } elseif ($path -eq '/v2/tools/storage-plan') {
      $body = @{ data = @{ downloads = @($fx.mods) } } | ConvertTo-Json -Depth 5
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch { } finally { $ctx.Response.OutputStream.Close() }
}
'@
Set-Content (Join-Path $tmp 'mock.ps1') $mockCode
$mockArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -port {1} -fixturePath "{2}" -readyPath "{3}"' -f
  (Join-Path $tmp 'mock.ps1'), $port, (Join-Path $tmp 'fixture.json'), (Join-Path $tmp 'ready')
$mockOptions = @{ FilePath = $shell; ArgumentList = $mockArgs; PassThru = $true }
if (!$IsLinux) { $mockOptions.WindowStyle = 'Hidden' }
$script:mock = Start-Process @mockOptions
foreach ($i in 1..50) { if (Test-Path (Join-Path $tmp 'ready')) { break }; Start-Sleep -Milliseconds 100 }
if (-not (Test-Path (Join-Path $tmp 'ready'))) { throw 'The mock API did not start.' }

# --- workers -----------------------------------------------------------------------
function Start-Worker([string]$mode, [switch]$Http) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $shell
  $flags = if ($Http) { '-NoHelpers' } else { "-Desktop -NoHelpers $mode" }
  $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f (Join-Path $repo 'download-web.ps1'), $flags
  $psi.WorkingDirectory = $repo
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['RFMM_HOME'] = $installRoot
  $psi.EnvironmentVariables['RFMM_DATA'] = $data
  $psi.EnvironmentVariables['RFMM_GAME_PROFILE'] = $game
  $psi.EnvironmentVariables['RFMM_API'] = $api
  $psi.EnvironmentVariables['RFMM_TEST_ALLOW_HTTP'] = '1'
  $psi.EnvironmentVariables['RFMM_ENGINE_EXE'] = $stub
  [Diagnostics.Process]::Start($psi)
}
function Ask($proc, [string]$path, [string]$method = 'GET') {
  $proc.StandardInput.WriteLine((@{ path = $path; method = $method } | ConvertTo-Json -Compress))
  while ($true) {
    $readLine = $proc.StandardOutput.ReadLineAsync()
    if (!$readLine.Wait(45000)) { throw "Worker timed out on $($path.Split('?')[0])." }
    $line = $readLine.Result
    if ($null -eq $line) { return @{ status = 0; body = ''; json = $null } }
    if ($line.StartsWith('RFMM ')) { break }
  }
  $reply = $line.Substring(5) | ConvertFrom-Json
  $json = $null
  try { $json = $reply.body | ConvertFrom-Json } catch { }
  @{ status = [int]$reply.status; body = [string]$reply.body; json = $json; type = $reply.type }
}
function Cfg { Get-Content (Join-Path $data 'batch1-serverconfig.json') -Raw | ConvertFrom-Json }
function Get-ServersData { @((Get-Content (Join-Path $data 'batch1-servers.json') -Raw | ConvertFrom-Json).servers) }
function QueueIds { @((Cfg).game.mods | ForEach-Object { $_.modId }) }

# a token from a previous run must be ignored by the read-only worker
Set-Content (Join-Path $data 'desktop-token.json') (@{ token = 'stale-token'; written = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3600) } | ConvertTo-Json)
$script:read = Start-Worker '-ReadOnly'
$script:main = Start-Worker ''   # started after the read-only worker on purpose: it must still share the token
Start-Sleep -Milliseconds 2000
$status = Ask $main '/status'
for ($i = 0; $i -lt 40; $i++) {
  if ($status.json -and -not $status.json.inventoryPending) { break }
  Start-Sleep -Milliseconds 250; $status = Ask $main '/status'
}
$tok = $status.json.tok
$rs = Ask $read '/status'
for ($i = 0; $i -lt 60; $i++) { if ($rs.status -eq 200) { break }; Start-Sleep -Milliseconds 250; $rs = Ask $read '/status' }
if ($rs.status -ne 200) { "  [debug] read status=$($rs.status) exited=$($script:read.HasExited)" }

if (-not $status.json) { "  [debug] main exited=$($script:main.HasExited) err=$($script:main.StandardError.ReadToEnd())" }
"== surface"
Check 'the page is served' ((Ask $main '/').body -match 'Downloads')
Check 'status has the fields the page needs' ($status.status -eq 200 -and $null -ne $status.json.queue -and $status.json.recentRev)
Check 'status does not ship the completed list' ($null -eq $status.json.PSObject.Properties['recent'])
$completed = Ask $read '/completed'
for ($i = 0; $i -lt 20; $i++) {
  if (@($completed.json.recent).Count -gt 0) { break }
  Start-Sleep -Milliseconds 250; $completed = Ask $read '/completed'
}
Check 'completed returns a revision and rows' ($completed.json.rev -and $null -ne $completed.json.recent)
$rs = Ask $read '/status'
Check 'the read-only worker shares the action token' ($rs.json.tok -and $rs.json.tok -eq $tok -and $rs.json.tok -ne 'stale-token')
Check 'the read-only worker refuses other routes' ((Ask $read '/servers').status -eq 403)
Check 'unknown routes are 404' ((Ask $main '/definitely-not-a-route').status -eq 404)
Check 'a mutating route needs the token' ((Ask $main '/start' 'POST').status -eq 403)

"== server and Workshop discovery"
$browserJoin = "/join-server?id=$($fixture.serverId)&source=browser&t=$tok"
Check 'browser join requires a discovered server' ((Ask $main $browserJoin 'POST').status -ne 200)
$browse = Ask $main '/browse?q=Stress%20%26%20Test&page=2&sort=name&region=new_york&platform=psn&online=false&locked=true&official=false&battleye=true&hasMods=true'
Check 'server filtering preserves scope, escaping and page metadata' ($browse.status -eq 200 -and $browse.json.page -eq 2 -and $browse.json.pages -eq 3 -and
  !$browse.json.servers[0].online -and $browse.json.servers[0].locked -and $browse.json.servers[0].platforms -contains 'psn') $browse.body
Check 'server browse omits upstream join payloads' ($null -eq $browse.json.servers[0].PSObject.Properties['joinUrl'])
$null = Ask $main '/browse'
Check 'browser join resolves an invite without tracking the server' ((Ask $main $browserJoin 'POST').json.url -match '^steam://run/1874880//')
$serverDetails = Ask $main "/browse-server?id=$($fixture.serverId)"
Check 'server details preserve reported mod versions and bytes' ($serverDetails.json.mods[1].version -ceq '1.0.0' -and $serverDetails.json.mods[1].expB -eq 2097152)
$history = Ask $main "/server-history?id=$($fixture.serverId)&range=7d"
Check 'server history returns the requested range' ($history.status -eq 200 -and $history.json.points[0].avg -eq 25)
$vanilla = Ask $main "/browse-server?id=$($fixture.vanillaId)"
Check 'a vanilla server has an empty public mod list' ($vanilla.status -eq 200 -and $vanilla.json.hasModList -and $vanilla.json.mods.Count -eq 0)
Check 'regional ping requires the action token' ((Ask $main '/measure-ping' 'POST').status -eq 403)
$catalog = Ask $main '/search-mods'
Check 'Workshop opens a populated catalogue without a search query' ($catalog.status -eq 200 -and $catalog.json.mods.Count -eq 3)
$filtered = Ask $main '/search-mods?q=Alpha+%26+co&tags=WEAPONS,TERRAINS&page=2&sort=largest'
Check 'Workshop sends repeated tags, sort and page without mixing caches' ($filtered.status -eq 200 -and $filtered.json.page -eq 2 -and
  $filtered.json.total -eq 17 -and $filtered.json.mods[0].tags.Count -eq 2 -and $filtered.json.mods[0].subscribers -eq 20) $filtered.body
$alpha = $fixture.mods[0].id
$exact = Ask $main "/search-mods?q=$($alpha.ToLowerInvariant())"
Check 'exact Workshop ID search returns one normalized result' ($exact.status -eq 200 -and $exact.json.mods.Count -eq 1 -and $exact.json.mods[0].id -ceq $alpha)
$modDetails = Ask $main "/mod-details?id=$alpha"
Check 'Workshop detail returns description, dependencies and media' ($modDetails.status -eq 200 -and $modDetails.json.description -eq 'Alpha description' -and
  $modDetails.json.dependencies[0].id -eq $fixture.mods[1].id -and $modDetails.json.images.Count -eq 1) $modDetails.body
$versions = Ask $main "/mod-versions?id=$alpha"
Check 'Workshop version history excludes unpublished releases' ($versions.status -eq 200 -and $versions.json.versions.Count -eq 1 -and $versions.json.versions[0].version -eq '2.0.0')
Check 'Workshop release notes preserve newlines' ((Ask $main "/mod-versions?id=$alpha&version=2.0.0").json.changelog -ceq "First line$([char]10)Second line")
Check 'Workshop paths reject non-IDs and invalid version segments' ((Ask $main '/mod-details?id=bad').status -ne 200 -and
  (Ask $main "/mod-versions?id=$alpha&version=%2e%2e").status -ne 200)

"== add server, auto-start, no duplicates"
$add = Ask $main "/add-server?id=$($fixture.serverId)&t=$tok" 'POST'
Check 'adding a server queues its missing mods' (@(QueueIds).Count -eq 3 -and @((Get-Content (Join-Path $data 'batch1-servers.json') -Raw | ConvertFrom-Json).servers).Count -eq 1) "status=$($add.status) queue=$(@(QueueIds).Count) raw=$((Get-Content (Join-Path $data 'batch1-servers.json') -Raw))"
Check 'adding a server starts the download' ((ReplyText $add) -match 'Downloads started') (ReplyText $add)
$null = Ask $main "/add-server?id=$($fixture.serverId)&t=$tok" 'POST'
Check 'adding the same server again keeps one entry' (@((Get-Content (Join-Path $data 'batch1-servers.json') -Raw | ConvertFrom-Json).servers).Count -eq 1) "raw=$((Get-Content (Join-Path $data 'batch1-servers.json') -Raw))"
Check 'join requires the desktop action token' ((Ask $main "/join-server?id=$($fixture.serverId)" 'POST').status -eq 403)
$join = Ask $main "/join-server?id=$($fixture.serverId)&t=$tok" 'POST'
Check 'join resolves a Steam invite for a tracked server' ($join.json.url -match '^steam://run/1874880//')
Check 'join reports readable status text' ($join.json.msg -ceq 'Opening Arma Reforger through Steam...')
Check 'desktop JSON replies declare UTF-8' ($join.type -eq 'application/json; charset=utf-8')
Check 'join rejects servers outside the Library' ((Ask $main "/join-server?id=99999999-9999-9999-9999-999999999999&t=$tok" 'POST').status -ne 200)
Check 'open addons returns the same game folder used for downloads' ((Ask $main "/open-addons-folder?t=$tok" 'POST').json.folder -eq $gameAddons)
Check 'the queue has no duplicates' (@(QueueIds).Count -eq @(QueueIds | Select-Object -Unique).Count)
$trackedVanilla = Ask $main "/add-server?id=$($fixture.vanillaId)&t=$tok" 'POST'
$trackedRows = (Ask $main '/servers').json.servers
Check 'tracking a vanilla server adds no mods to the queue' ($trackedVanilla.status -eq 200 -and @(QueueIds).Count -eq 3 -and
  @($trackedRows | Where-Object id -eq $fixture.vanillaId).Count -eq 1)
$null = Ask $main "/remove-server?id=$($fixture.vanillaId)&t=$tok" 'POST'

"== add mod"
$newMod = 'DDDDDDDDDDDDDDD1'
$m1 = Ask $main "/add-mod?id=$newMod&t=$tok" 'POST'
Check 'adding a mod queues it' ((QueueIds) -contains $newMod)
Check 'adding a mod starts the download' ((ReplyText $m1) -match 'Downloads started')
Check 'adding the same mod is a no-op' ((ReplyText (Ask $main "/add-mod?id=$newMod&t=$tok" 'POST')) -match 'already queued')
Check 'an invalid mod id is refused' ([bool](Ask $main '/add-mod?id=not-an-id&t='$tok 'POST').json.error)
$deps = Ask $main "/add-mod?id=$($fixture.depsId)&t=$tok" 'POST'
Check 'a huge dependency list is capped' ((ReplyText $deps) -match 'limit' -and @(QueueIds).Count -le 210)

"== queue controls"
$q = Ask $main "/queue-server?id=$($fixture.serverId)&t=$tok" 'POST'
Check 'queue first puts the server mods in front' ((QueueIds)[0] -in @($fixture.mods.id))
Check 'queue first reports the download started' ((ReplyText $q) -match 'Downloads started')
Check 'clear queue empties it' ((Ask $main "/clear-queue?t=$tok" 'POST').status -eq 200 -and @(QueueIds).Count -eq 0)
Check 'resume all requeues missing mods' ((Ask $main "/resume-all?t=$tok" 'POST').status -eq 200 -and @(QueueIds).Count -gt 0)

"== refresh and server management"
$job = Ask $main "/refresh-servers?t=$tok" 'POST'
$done = $null
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 500
  $st = Ask $main "/job?id=$($job.json.job)&t=$tok" 'POST'
  if ($st.json.state -ne 'running') { $done = $st.json; break }
}
Check 'the refresh job completes' ($done -and $done.state -eq 'done')
Check 'refresh keeps one server entry' (@(Get-ServersData).Count -eq 1) "servers=$(@(Get-ServersData).Count)"
$rem = Ask $main "/remove-server?id=$($fixture.serverId)&t=$tok" 'POST'
Check 'removing a server keeps its mods' ($rem.status -eq 200 -and @(Get-ServersData).Count -eq 0 -and @(QueueIds).Count -gt 0)
$back = Ask $main "/add-server?id=$($fixture.serverId)&t=$tok" 'POST'
Check 'the server can be added back' (@(Get-ServersData).Count -eq 1 -and $back.status -eq 200) "status=$($back.status) msg=$(ReplyText $back)"

"== verify and presets"
$v = Ask $main "/verify?t=$tok" 'POST'
$vs = Ask $read '/status'
Check 'verify reports a result through the read-only worker' ($v.status -eq 200 -and $vs.json.verify) "status=$($v.status) verify=$([bool]$vs.json.verify) readStatus=$($vs.status)"
$conf = Join-Path $tmp 'ReforgerGameSettings.conf'
"GameUserSettings {`r`n  SCR_WorkshopAddonManagerPresetStorage SCR_WorkshopAddonManagerPresetStorage `"{6AEA4081FE80EE32}`" {`r`n  }`r`n}" | Set-Content $conf
foreach ($m in $fixture.mods) {
  $dir = Join-Path $gameAddons ("$($m.name)_$($m.id)")
  New-Item -ItemType Directory -Force $dir | Out-Null
  [IO.File]::WriteAllText((Join-Path $dir 'data.pak'), 'x')
  $ver = if ($m.id -eq 'AAAAAAAAAAAAAAA2') { '1.0.0' } else { $m.version }
  ('{ "meta": { "selectedRev": 0, "versions": [ { "version": "' + $ver + '", "package": { "files": [ { "name": "data.pak", "size": 1 } ] } } ] } }') | Set-Content (Join-Path $dir 'meta')
}
$oldData = $env:RFMM_DATA; $oldHome2 = $env:RFMM_HOME; $env:RFMM_DATA = $data; $env:RFMM_HOME = $installRoot
$pout = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'make-preset.ps1') -ServerId $fixture.serverId -ConfPath $conf -AddonsDir $addonsDir 2>&1
$env:RFMM_DATA = $oldData; $env:RFMM_HOME = $oldHome2
$confText = try { Get-Content $conf -Raw } catch { '' }
Check 'a preset is created from installed mods' ((($pout -join ' ') -match 'OK - preset') -and $confText -match 'SCR_WorkshopAddonPreset "\{') "out=$(($pout -join ' '))"

"== updates"
"  (clear the queue first so a queued server mod cannot hide the update)"
$null = Ask $main "/clear-queue?t=$tok" 'POST'
$auto = Ask $main "/update-mods?scope=all&check=1&auto=1&t=$tok" 'POST'
Check 'a stale dashboard cannot launch an automatic update check' ($auto.status -eq 400 -and
  !(Test-Path -LiteralPath (Join-Path $data 'update-progress.json')))
$u = Ask $main "/update-mods?scope=tracked&t=$tok" 'POST'
Check 'the update check starts' ($u.status -eq 200) $u.body
$sawProgress = $false; $upDone = $false
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep -Milliseconds 500
  $st = Ask $read '/status'
  if ($st.json.modUpdateProgress -and $st.json.modUpdateProgress.total -ge 1) { $sawProgress = $true }
  if ($st.json.modUpdateProgress.phase -eq 'done' -and $sawProgress) { $upDone = $true; break }
}
Check 'the update check reports progress through the read-only worker' ($sawProgress)
Check 'the update check finishes' ($upDone)
  $updEntry = @((Cfg).game.mods | Where-Object { $_.modId -eq 'AAAAAAAAAAAAAAA2' -and $_.version -eq '1.1.0' }).Count
Check 'a newer Workshop version is queued with its version' ($updEntry -eq 1)
Check 'the update result is shown' ([bool]$st.json.modUpdate) $st.json.modUpdate
Check 'cancel updates removes the pending batch' ((Ask $main "/cancel-mod-updates?t=$tok" 'POST').status -eq 200)

$manualCheck = Ask $main "/update-mods?scope=all&check=1&t=$tok" 'POST'
Check 'manual update detection starts without queueing mods' ($manualCheck.status -eq 200 -and @(QueueIds).Count -eq 0)
$preview = $null
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 250
  $preview = Ask $main '/available-mod-updates'
  if ($preview.json.updates.modId -contains 'AAAAAAAAAAAAAAA1') { break }
}
Check 'recent catalog exposes an installed mod update before the check changes any queue entries' (
  @($preview.json.updates | Where-Object { $_.modId -eq 'AAAAAAAAAAAAAAA1' -and $_.version -eq '2.1.0' }).Count -eq 1 -and
  @($preview.json.updates | Where-Object modId -eq 'EEEEEEEEEEEEEEEE').Count -eq 0 -and @(QueueIds).Count -eq 0) $preview.body
Check 'applying detected updates requires the action token' ((Ask $main '/apply-mod-updates' 'POST').status -eq 403)
$one = Ask $main "/apply-mod-updates?id=AAAAAAAAAAAAAAA1&t=$tok" 'POST'
Check 'an individual detection can be queued without the other updates' (
  $one.status -eq 200 -and @((Cfg).game.mods).Count -eq 1 -and (Cfg).game.mods[0].version -eq '2.1.0') $one.body
for ($i = 0; $i -lt 60; $i++) {
  $st = Ask $read '/status'
  if ($st.json.modUpdateProgress.phase -eq 'done' -and $st.json.modUpdatesRevision) { break }
  Start-Sleep -Milliseconds 250
}
$preview = Ask $main '/available-mod-updates'
Check 'detail lookup finds an update missing from the recent catalog' (
  @($preview.json.updates | Where-Object { $_.modId -eq 'AAAAAAAAAAAAAAA2' -and $_.version -eq '1.1.0' }).Count -eq 1) $preview.body
$all = Ask $main "/apply-mod-updates?t=$tok" 'POST'
Check 'update all appends the remaining update without duplicating the first' (
  $all.status -eq 200 -and @((Cfg).game.mods).Count -eq 2 -and (QueueIds) -contains 'AAAAAAAAAAAAAAA2') $all.body
$cancelAgain = Ask $main "/cancel-mod-updates?t=$tok" 'POST'
Check 'cancelling clears updates applied in separate requests' ($cancelAgain.status -eq 200 -and @(QueueIds).Count -eq 0)

"== cancel downloads"
$partialId = 'AAAAAAAAAAAAAAA3'
$partial = Join-Path $gameAddons "Gamma_$partialId"
[IO.File]::WriteAllText((Join-Path $partial 'data.pak'), 'half')
Remove-Item (Join-Path $partial 'meta') -Force -ErrorAction SilentlyContinue
$keep = Join-Path $gameAddons 'Alpha_AAAAAAAAAAAAAAA1'
$cd = Ask $main "/cancel-downloads?t=$tok" 'POST'
$gameNow = @(Get-Process -Name 'ArmaReforger*' -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -notlike 'ArmaReforgerSer*' }).Count -gt 0
if ($gameNow) {
  Check 'cancel downloads refuses while the game is open' ($cd.status -eq 500 -and $cd.body -match 'Close Arma Reforger') "status=$($cd.status) body=$($cd.body)"
} else {
  Check 'cancel downloads clears the queue' (@(QueueIds).Count -eq 0) "queue=$(@(QueueIds).Count) status=$($cd.status) body=$($cd.body)"
  Check 'cancel removes the tracked partial and keeps installed mods' ((-not (Test-Path $partial)) -and (Test-Path $keep)) "status=$($cd.status) body=$($cd.body)"
}

"== transport robustness"
$main.StandardInput.WriteLine('{not json')
$raw = $main.StandardOutput.ReadLine()
while ($raw -and -not $raw.StartsWith('RFMM ')) { $raw = $main.StandardOutput.ReadLine() }
Check 'a malformed request gets an error, not a crash' ([bool]$raw -and (($raw.Substring(5) | ConvertFrom-Json).status -ge 400))
Check 'the worker still answers after a malformed request' ((Ask $main '/status').status -eq 200)
for ($i = 0; $i -lt 30; $i++) { $null = Ask $read '/status'; $null = Ask $main '/status' }
Check 'both workers survive 30 alternating polls' ((Ask $main '/status').status -eq 200 -and (Ask $read '/status').status -eq 200)

"== invariants"
$cfg = Cfg
$ids = @($cfg.game.mods | ForEach-Object { $_.modId })
Check 'the config has name and scenario' ([bool]$cfg.game.name -and [bool]$cfg.game.scenarioId)
Check 'queued ids are unique and well formed' (@($ids).Count -eq @($ids | Select-Object -Unique).Count -and @($ids | Where-Object { $_ -notmatch '^[0-9A-F]{16}$' }).Count -eq 0)
Check 'server ids are unique' (@(Get-ServersData | ForEach-Object { $_.id } | Select-Object -Unique).Count -eq @(Get-ServersData).Count)
Check 'no job result files are left behind' (@(Get-ChildItem $data -Filter 'job-*.json' -ErrorAction SilentlyContinue).Count -eq 0)
Check 'the action token did not change' ((Ask $read '/status').json.tok -eq $tok)

if ($RunHttpSuites) {
  $null = Ask $main "/pause?t=$tok" 'POST'
  foreach ($worker in $main, $read) {
    $worker.StandardInput.Close()
    if (!$worker.WaitForExit(10000)) { throw 'The stdio worker did not close.' }
  }
  Update-Cfg {
    param($config)
    $config.game.mods = @([pscustomobject]@{
      modId = 'AAAAAAAAAAAAAAA2'; name = 'Beta'; version = '1.1.0'; size = 2097152
    })
  } $configFile | Out-Null
  foreach ($file in Get-ChildItem -LiteralPath $keep -File) { $file.LastWriteTime = (Get-Date).AddMinutes(-5) }
  $http = Start-Worker -Http
  $deadline = [datetime]::UtcNow.AddSeconds(15)
  do {
    try { $ready = (Invoke-WebRequest 'http://localhost:8123/status' -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 }
    catch { Start-Sleep -Milliseconds 100 }
  } until ($ready -or $http.HasExited -or [datetime]::UtcNow -ge $deadline)
  if (!$ready) { throw 'The fixture HTTP dashboard did not start.' }
  $saveEnvironment = @{}
  foreach ($key in 'RFMM_HOME', 'RFMM_DATA', 'RFMM_GAME_PROFILE') { $saveEnvironment[$key] = [Environment]::GetEnvironmentVariable($key) }
  try {
    $env:RFMM_HOME = $installRoot
    $env:RFMM_DATA = $data
    $env:RFMM_GAME_PROFILE = $game
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'test-rules.ps1')
    Check 'live completion and integrity suite passed' ($LASTEXITCODE -eq 0)
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'test-torture.ps1') -ServerRoundTrip
    Check 'legacy dashboard torture suite passed' ($LASTEXITCODE -eq 0)
  } finally {
    foreach ($key in $saveEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $saveEnvironment[$key]) }
  }
}

""
"checks: $checks   failures: $failed"
if ($failed) { Cleanup; "STRESS: FAIL"; exit 1 }
Cleanup
"STRESS: OK"
exit 0

param([switch]$Check)
# Arma Reforger mod manager - local web dashboard: batch downloader, live server
# browser, per-server queue-first, launcher presets, client addon sync.
# double-click the .cmd: serves http://localhost:8123 and opens your browser.
#
# Paths: everything is relative to this folder, so the project folder is portable.
#   RFMM_HOME  where the big data lives (serverprofile\, airmar-server\, steamcmd\)
#   RFMM_DATA  where the json state lives (data\)   [both optional; default = here]
# On this machine they are set until migrate-here.ps1 moves the folders in here.
$ErrorActionPreference = 'Stop'
$Root    = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data    = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$Exe     = "$Root\armar-server\ArmaReforgerServer.exe"
$Cfg     = "$Data\batch1-serverconfig.json"
$Sizes   = "$Data\batch1-sizes.json"
$ServersPath = "$Data\batch1-servers.json"
$DsProfile = "$Root\serverprofile"
$Addons  = "$DsProfile\addons"
$ClientAddons = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"
$Url     = 'http://localhost:8123/'

# shared helpers (Save-Json, Read-Json, Test-AddonComplete): one copy for every
# script, so the completion rule cannot drift between the app, the trim and the test
. "$PSScriptRoot\state.ps1"

. "$PSScriptRoot\dashboard-core.ps1"

# first run on any machine: create empty state files instead of failing
if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Force $Data | Out-Null }
if (-not (Test-Path $Sizes))       { '{"totalBytes":0,"mods":{}}' | Set-Content $Sizes -Encoding UTF8 }
if (-not (Test-Path $Cfg))         { $CfgStub | Set-Content $Cfg -Encoding UTF8 }
if (-not (Test-Path $ServersPath)) { '{"servers":[]}'           | Set-Content $ServersPath -Encoding UTF8 }

# The engine can only assemble mods inside its own profile, and the game reads its
# own addons folder. A directory junction makes those one folder: each mod is
# stored once, where the game looks, instead of downloaded here and copied there.
if (-not (Initialize-AddonsLink $Addons $ClientAddons $Cfg)) {
  Write-Host 'the engine folder could not be linked to the game addons folder - mods are kept here and copied there'
}


$j = Read-Json $Sizes ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json)
$sizeMap = @{}
foreach ($p in $j.mods.PSObject.Properties) { $sizeMap[$p.Name] = $p.Value }
$TotalBytes = $j.totalBytes

$serverList = @((Read-Json $ServersPath ('{"servers":[]}' | ConvertFrom-Json)).servers)
foreach ($sv in $serverList) { foreach ($m in $sv.mods) {
  $sm = $sizeMap[$m.id]
  $m | Add-Member -NotePropertyName e -NotePropertyValue ([double]($(if ($sm) { $sm.bytes } else { 0 }))) -Force
} }

$verify = $null   # last verify result shown on the page
$script:maxDone = [double]0; $script:maxDoneTotal = [double]0   # high-water progress: the DS deletes temp files, so raw bytes dip
$script:skipped = @(); $script:skippedAt = (Get-Date).AddMinutes(-10)
$script:rateSamples = @()                                      # rolling byte-rate for a live speed
$script:activeMax = @{}                                        # per-mod high-water progress
$script:exactCache = @{}                                       # path -> exact package check
$script:logCache = $null; $script:logCacheAt = (Get-Date).AddMinutes(-1)
$script:dsCache = $null; $script:dsAt = (Get-Date).AddMinutes(-1)
$script:speedCache = @{ b = 0; age = 999 }; $script:speedCacheAt = (Get-Date).AddMinutes(-5)

$ApiBase = 'https://api.reforgermods.net/v2'
$ApiH = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$script:bCache = @{}; $script:bCacheAt = @{}   # /browse search cache
$script:dCache = @{}; $script:dCacheAt = @{}   # /browse-server detail cache




$script:dirCache = $null; $script:dirCacheAt = (Get-Date).AddMinutes(-10)
$script:clCache = @(); $script:clCacheAt = (Get-Date).AddMinutes(-10)
$script:clBytes = [double]0; $script:clBytesAt = (Get-Date).AddMinutes(-10)
$script:haveCache = @{}; $script:haveAt = (Get-Date).AddMinutes(-10)







if ($Check) {
  try { Get-Status | ConvertTo-Json -Depth 5 | Out-String -Width 300 }
  catch { "GET-STATUS FAILED: $($_.Exception.Message)"; "at: $($_.InvocationInfo.PositionMessage)" }
  exit 0
}
























# per-run token: the six state-changing endpoints only answer requests that carry
# it, so another website open in the browser cannot drive this server (CSRF)
$token = [guid]::NewGuid().ToString('N')
$mutating = '/start','/pause','/verify','/queue-server','/resume-all','/clear-queue','/make-preset','/add-server','/refresh-servers','/refresh-server','/job','/remove-server','/add-mod'

$html = Get-Content (Join-Path $PSScriptRoot 'page.html') -Raw


$l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url)
try { $l.Start() }
catch {
  # port busy: a just-killed dashboard's keep-alive sockets linger for a while.
  # retry once before concluding another instance is actually serving.
  Start-Sleep 5
  try { $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url); $l.Start() }
  catch {
    Write-Host 'dashboard already running - opening browser' -ForegroundColor Cyan
    Start-Process $Url
    exit 0
  }
}
Write-Host '=== Arma Reforger Mods - web dashboard ===' -ForegroundColor White
Write-Host "open: $Url   (keep this window open; closing it only stops the UI, not the download)" -ForegroundColor Cyan
# -Command + quoted path: -File breaks on a repo path containing a space,
# which silently disabled the client-addon mirror
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',`
  '-Command',"& '$PSScriptRoot\sync-addons.ps1' -Loop"   # auto-mirror completed mods into client addons
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',`
 '-Command',"& '$PSScriptRoot\watchdog.ps1'"            # restarts the downloader when it exits or stalls
Start-Process $Url

while ($l.IsListening) {
  $ctx = $l.GetContext()
  try {
    $msg = $null   # must reset per request or it leaks into the next response body
    $jobId = $null
    $path = $ctx.Request.Url.AbsolutePath
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.Headers.Add('X-Frame-Options', 'DENY')
    $ctx.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $ctx.Response.Headers.Add('Content-Security-Policy',
      "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
    # every mutating route is POST-only: a GET can be triggered by an <img> tag or a
    # link, and answering it with 200 made that possible even with a leaked token
    if ($path -in $mutating -and $ctx.Request.HttpMethod -ne 'POST') {
      $ctx.Response.StatusCode = 405
      $b = [Text.Encoding]::UTF8.GetBytes('{"error":"use POST"}')
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      continue
    }
    if ($path -in $mutating -and $ctx.Request.QueryString['t'] -ne $token) {
      $ctx.Response.StatusCode = 403
      $b = [Text.Encoding]::UTF8.GetBytes('{"error":"bad or missing token"}')
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      continue
    }
    switch ($path) {
      '/' {
        $b = [Text.Encoding]::UTF8.GetBytes($html.Replace('__T__', $token))
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.ContentLength64 = $b.Length
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/status' {
        $b = [Text.Encoding]::UTF8.GetBytes((Get-Status | ConvertTo-Json -Depth 5 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/servers' {
        # exact per-server counts: a mod only counts when its own file list matches
        $have = Get-HaveIds
        $rows = @($serverList | ForEach-Object {
          $s = $_
          [PSCustomObject]@{ id = $s.id; name = $s.name; mods = $s.mods
                             haveCount = @($s.mods | Where-Object { $have.ContainsKey($_.id) }).Count } })
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = $rows } | ConvertTo-Json -Depth 6 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse' {
        $have = Get-HaveIds
        $tracked = @{}
        foreach ($sv in $serverList) { $tracked[$sv.id] = $sv }
        $rows = @(Get-Browse $ctx.Request.QueryString['q'] | ForEach-Object {
          # tracked servers get a real on-disk count; others only the API's total
          $haveCount = -1; $total = $_.modCount
          if ($tracked.ContainsKey($_.id)) {
            $mods = @($tracked[$_.id].mods)
            $haveCount = @($mods | Where-Object { $have.ContainsKey($_.id) }).Count
            $total = $mods.Count
          }
          [PSCustomObject]@{ id = $_.id; name = $_.name; players = $_.players; maxPlayers = $_.maxPlayers
                             region = $_.region; online = $_.online; modCount = $_.modCount
                             scenarioName = $_.scenarioName; haveCount = $haveCount; totalMods = $total
                             changed = $(if ($tracked.ContainsKey($_.id) -and $tracked[$_.id].PSObject.Properties['changed']) { $tracked[$_.id].changed } else { $null }) } })
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = $rows } | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse-server' {
        $s = Get-Detail $ctx.Request.QueryString['id']
        $have = Get-HaveIds
        $rows = @($s.mods | ForEach-Object {
          $exp = if ($sizeMap.ContainsKey($_.id)) { [double]$sizeMap[$_.id].bytes } else { [double]$_.size }
          [PSCustomObject]@{ id = $_.id; name = $_.name; expB = $exp; have = [bool]$have.ContainsKey($_.id) } })
        $missing = @($rows | Where-Object { -not $_.have })
        $out = @{ name = $s.name; online = [bool]$s.online; mods = $rows
                  haveCount = @($rows | Where-Object { $_.have }).Count
                  missingBytes = [double]($missing | ForEach-Object { $_.expB } | Measure-Object -Sum).Sum }
        $b = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/start'  { $msg = Invoke-StartQueue;  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/pause'  { $msg = Stop-DS;         Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/verify' { $msg = Invoke-Verify;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      '/queue-server' { $msg = Invoke-QueueServer $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/resume-all'   { $msg = Invoke-ResumeAll;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/clear-queue'  { $msg = Invoke-ClearQueue;  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/make-preset'  { $msg = Invoke-MakePreset $ctx.Request.QueryString['id'];  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      '/search-mods' {
        $r = Search-Mods ([string]$ctx.Request.QueryString['q']) ([int]$ctx.Request.QueryString['page'])
        $mods = @($r.mods | ForEach-Object {
          [PSCustomObject]@{ id = $_.id; name = $_.name; author = $_.author
                             size = [double]$_.size; version = $_.version }
        })
        $b = [Text.Encoding]::UTF8.GetBytes((@{ total = $r.total; page = $r.page; pages = $r.pages; mods = $mods } | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/add-mod' { $msg = Invoke-AddMod $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/add-server'   { $msg = Invoke-AddServer $ctx.Request.QueryString['id'];   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/refresh-servers' {
        $r = Start-RefreshJob @($serverList | ForEach-Object { $_.id })
        $msg = $r.msg; $jobId = $r.job
        Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan
      }
      '/refresh-server' {
        $sid = [string]$ctx.Request.QueryString['id']
        if (-not @($serverList | Where-Object { $_.id -eq $sid }).Count) { throw 'server is not in the list' }
        $r = Start-RefreshJob @($sid)
        $msg = $r.msg; $jobId = $r.job
        Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan
      }
      '/job' {
        # collects a background refresh: applies the result once, then reports it
        $r = Complete-RefreshJob ([string]$ctx.Request.QueryString['id'])
        $b = [Text.Encoding]::UTF8.GetBytes(($r | ConvertTo-Json -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/remove-server'   { $msg = Invoke-RemoveServer  $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      default   {
        $ctx.Response.StatusCode = 404
        $b = [Text.Encoding]::UTF8.GetBytes('{"error":"no such route"}')
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
    }
    if ($null -ne $msg) {
      # Durable trail of every state-changing action, whoever triggered it: the
      # console scrolls away, and the user's own clicks arrive in this same
      # process. "api" is a script, "browser" is a person at the page.
      try {
        $src = if ($ctx.Request.UserAgent -match 'PowerShell') { 'api' } else { 'browser' }
        # never write the request token: it is the CSRF guard for these routes
        $what = $ctx.Request.Url.AbsolutePath
        if ($ctx.Request.QueryString['id']) { $what += '?id=' + $ctx.Request.QueryString['id'] }
        Add-Content (Join-Path $Data 'actions.log') ("[{0:yyyy-MM-dd HH:mm:ss}] {1,7} {2} <- {3}: {4}" -f
          (Get-Date), $src, $what, $ctx.Request.RemoteEndPoint, ($msg -replace '\s+', ' '))
      } catch { }
      $resp = @{ ok = $true; msg = [string]$msg }
      if ($jobId) { $resp.job = [string]$jobId }
      $b = [Text.Encoding]::UTF8.GetBytes(($resp | ConvertTo-Json -Compress))
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    }
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    # never hand-roll this json: a Windows path in the message ("C:\Users\...")
    # contains \U, an illegal escape, so the page's r.json() threw a SyntaxError
    # and showed that instead of the real error
    $b = [Text.Encoding]::UTF8.GetBytes((@{ error = [string]$_.Exception.Message } | ConvertTo-Json -Compress))
    $ctx.Response.StatusCode = 500
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
  }
  finally { $ctx.Response.OutputStream.Close() }
}


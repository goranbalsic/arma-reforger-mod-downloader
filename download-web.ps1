param([switch]$Check, [switch]$Desktop, [switch]$DesktopStop, [switch]$ReadOnly, [switch]$NoHelpers)
# Serve the desktop dashboard over stdio or the browser dashboard at localhost:8123.
# RFMM_HOME sets the engine folder. RFMM_DATA sets the queue and log folder.
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
if ($Desktop -or $DesktopStop) {
  [Console]::InputEncoding = $utf8
  [Console]::OutputEncoding = $utf8
}
$Root    = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data    = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$Cfg     = Join-Path $Data 'batch1-serverconfig.json'
$Sizes   = Join-Path $Data 'batch1-sizes.json'
$ServersPath = Join-Path $Data 'batch1-servers.json'
$DsProfile = Join-Path $Root 'serverprofile'
$Url     = 'http://localhost:8123/'
$JsonType = 'application/json; charset=utf-8'

. (Join-Path $PSScriptRoot 'state.ps1')
. (Join-Path $PSScriptRoot 'workshop-api.ps1')

. (Join-Path $PSScriptRoot 'dashboard-core.ps1')
$project = Get-ProjectRepository

# State changes require a per-session token.
$token = [guid]::NewGuid().ToString('N')
if ($Desktop) {
  if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Force $Data | Out-Null }
  $tokenFile = Join-Path $Data 'desktop-token.json'
  $sessionToken = $env:RFMM_DESKTOP_SESSION_TOKEN
  if ($sessionToken) {
    if ($sessionToken -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid desktop session token.' }
    $token = $sessionToken
  }
  if ($ReadOnly -and !$sessionToken) {
    # Use the action worker's current token. Ignore a token file older than this worker.
    $startedUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $accepted = $false
    for ($i = 0; $i -lt 600; $i++) {
      $saved = Read-Json $tokenFile $null
      if ($saved -and $saved.token -and $saved.written -and [long]$saved.written -ge ($startedUnix - 2)) {
        $token = [string]$saved.token
        $accepted = $true
        break
      }
      Start-Sleep -Milliseconds 100
    }
    if (-not $accepted) { throw 'The downloader token is not ready. Reopen the app.' }
  } elseif (!$ReadOnly) {
    Save-Json @{ token = $token; written = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } $tokenFile
  }
}
$Exe = Get-EngineExecutable $Root
$Addons = Get-ClientAddons $DsProfile

if ($DesktopStop) {
  if (Test-Path -LiteralPath $Data) { Invoke-PauseQueue | Out-Null }
  exit 0
}

# Create first-run state files.
if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Force $Data | Out-Null }
if ($ReadOnly) {
  # The action worker initializes shared state.
  for ($i = 0; $i -lt 100 -and -not (Test-Path $Cfg); $i++) { Start-Sleep -Milliseconds 100 }
  if (-not (Test-Path $Cfg)) { throw "The downloader state is not ready. Reopen the app." }
} else {
  if (-not (Test-Path $Cfg))         { Save-Json ($CfgStub | ConvertFrom-Json) $Cfg 5 }
  $workshopMutex = Lock-WorkshopState $Data
  try {
    if (-not (Test-Path -LiteralPath $Sizes)) { Save-Json ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json) $Sizes 4 }
    if (-not (Test-Path -LiteralPath $ServersPath)) { Save-Json @{ servers = @() } $ServersPath 5 }
  } finally { Unlock-WorkshopState $workshopMutex }
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

$script:backgroundInventory = $true
$verify = $null   # last verify result shown on the page
$script:maxDone = [double]0; $script:progressBatch = ''   # high-water progress: the DS deletes temp files, so raw bytes dip
$script:skipped = @(); $script:skippedAt = (Get-Date).AddMinutes(-10)
$script:rateSamples = @()                                      # rolling byte-rate for a live speed
$script:activeMax = @{}                                        # per-mod high-water progress
$script:exactCache = @{}                                       # path -> exact package check
$script:logCache = $null; $script:logCacheAt = (Get-Date).AddMinutes(-1)
$script:dsCache = $null; $script:dsAt = (Get-Date).AddMinutes(-1)
$script:speedCache = @{ b = 0; age = 999 }; $script:speedCacheAt = (Get-Date).AddMinutes(-5)

$ApiBase = if ($env:RFMM_API) { (Get-WorkshopUri $env:RFMM_API).AbsoluteUri.TrimEnd('/') } else { 'https://api.reforgermods.net/v2' }
# one user agent for every API call, versioned from version.txt
$UserAgent = 'arma-reforger-mod-downloader/' + (((Get-Content (Join-Path $PSScriptRoot 'version.txt') -Raw -ErrorAction SilentlyContinue) -replace '\s', ''))
if ($UserAgent -match '/$') { $UserAgent = 'arma-reforger-mod-downloader/dev' }
$ApiH = @{ 'User-Agent' = $UserAgent }
$script:directoryCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$script:browserServers = @{}
$script:regionLatency = $null




$script:dirCache = $null; $script:dirCacheAt = (Get-Date).AddMinutes(-10)
$script:clCache = @(); $script:clCacheAt = (Get-Date).AddMinutes(-10)
$script:clBytes = [double]0; $script:clBytesAt = (Get-Date).AddMinutes(-10)
$script:haveCache = @{}; $script:haveAt = (Get-Date).AddMinutes(-10)







if ($Check) {
  try { Get-Status | ConvertTo-Json -Depth 5 | Out-String -Width 300 }
  catch {
    "GET-STATUS FAILED: $($_.Exception.Message)"
    "at: $($_.InvocationInfo.PositionMessage)"
    exit 1
  }
  exit 0
}

$mutating = '/update-mods','/apply-mod-updates','/cancel-mod-updates','/start','/pause','/verify','/queue-server','/resume-all','/clear-queue','/cancel-downloads','/remove-queued-mod','/requeue-partial-mod','/make-preset','/add-server','/refresh-servers','/refresh-server','/job','/remove-server','/add-mod','/open-addons-folder','/join-server','/measure-ping'
$script:modUpdateJob = $null

function Start-DownloadHelpers {
  if ($Desktop) {
    if (!$env:RFMM_DESKTOP_OWNER_PID) { $env:RFMM_DESKTOP_OWNER_PID = [string]$PID }
    $env:RFMM_DESKTOP_OWNER_TOKEN = [guid]::NewGuid().ToString('N')
    $ctl = Lock-Engine
    if (!$ctl) { throw 'Could not register the downloader window.' }
    try {
      Save-Json @{ token = $env:RFMM_DESKTOP_OWNER_TOKEN } (Join-Path $Data 'desktop-owner.json')
    } finally { $ctl.ReleaseMutex() }
  }
  if ($IsLinux) {
    $helper = Join-Path $PSScriptRoot 'watchdog.ps1'
    Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList ('-NoProfile -File "{0}"' -f $helper) -RedirectStandardInput '/dev/null' -RedirectStandardOutput (Join-Path $Data 'watchdog-output.log') -RedirectStandardError (Join-Path $Data 'watchdog-error.log')
    return
  }
  $shell = Join-Path $PSHOME 'powershell.exe'
  if (!(Test-Path $shell)) { $shell = Join-Path $PSHOME 'pwsh.exe' }
  Start-Process $shell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'watchdog.ps1'))
}
function Stop-ModUpdateCheck {
  if ($modUpdateJob) {
    Stop-Job $modUpdateJob -ErrorAction SilentlyContinue
    Remove-Job $modUpdateJob -Force
    $script:modUpdateJob = $null
    try { Save-Json @{ phase = 'cancelled'; text = 'Update check cancelled.' } (Join-Path $Data 'update-progress.json') 4 } catch { }
  }
}
function Test-ActionToken([string]$Provided, [string]$Expected) {
  if ($Provided.Length -ne $Expected.Length) { return $false }
  $difference = 0
  for ($index = 0; $index -lt $Expected.Length; $index++) {
    $difference = $difference -bor ([int]$Provided[$index] -bxor [int]$Expected[$index])
  }
  $difference -eq 0
}
function Test-LocalDashboardRequest($Request) {
  $address = $Request.RemoteEndPoint.Address
  if ($address.IsIPv4MappedToIPv6) { $address = $address.MapToIPv4() }
  $hostHeader = [string]$Request.Headers['Host']
  $origin = [string]$Request.Headers['Origin']
  [Net.IPAddress]::IsLoopback($address) -and
    $hostHeader -in 'localhost:8123','127.0.0.1:8123' -and
    (!$origin -or $origin -eq "http://$hostHeader")
}
function Write-DashboardError($Response, [int]$Status, [string]$Message) {
  $Response.StatusCode = $Status
  $Response.ContentType = $JsonType
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ error = $Message } | ConvertTo-Json -Compress))
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Write-DirectoryJson($Response, $Value) {
  $Response.ContentType = $JsonType
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 6 -Compress))
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Invoke-DashboardRequest($ctx) {
  try {
    $msg = $null   # must reset per request or it leaks into the next response body
    $jobId = $null
    $path = $ctx.Request.Url.AbsolutePath
    $nonce = if ($path -eq '/') { [guid]::NewGuid().ToString('N') } else { $null }
    $scriptPolicy = if ($nonce) { "'nonce-$nonce'" } else { "'none'" }
    if ($Desktop) { $ctx.Response.Nonce = $nonce }
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.Headers.Add('X-Frame-Options', 'DENY')
    $ctx.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $ctx.Response.Headers.Add('Content-Security-Policy',
      "default-src 'self'; script-src $scriptPolicy; style-src 'self' 'unsafe-inline'; img-src https://ar-gcp-cdn.bistudio.com/image/; frame-ancestors 'none'; base-uri 'none'")
    if (!$Desktop -and !(Test-LocalDashboardRequest $ctx.Request)) {
      Write-DashboardError $ctx.Response 403 'This dashboard accepts local, same-origin requests only.'
      return
    }
    if ($path -in $mutating -and $ctx.Request.HttpMethod -ne 'POST') {
      Write-DashboardError $ctx.Response 405 'use POST'
      return
    }
    if ($path -in $mutating) {
      $provided = if ($Desktop) { $ctx.Request.QueryString['t'] } else { $ctx.Request.Headers['X-RFMM-Token'] }
      if (!(Test-ActionToken $provided $token)) {
        $message = if ($Desktop) { 'bad or missing token' } else { 'Dashboard session changed. Reload the page and try again.' }
        Write-DashboardError $ctx.Response 403 $message
        return
      }
    }
    switch ($path) {
      { $_ -in '/open-addons-folder','/join-server' } {
        if (!$Desktop) { Write-DashboardError $ctx.Response 403 'Open the desktop app to use this action.'; return }
        $payload = if ($path -eq '/join-server') {
          $browser = $ctx.Request.QueryString['source'] -eq 'browser'
          @{ url = Get-LibraryJoinUrl $ctx.Request.QueryString['id'] -Browser:$browser; msg = 'Opening Arma Reforger through Steam...' }
        } else {
          [void][IO.Directory]::CreateDirectory($Addons)
          @{ folder = $Addons; msg = 'Opened the addons folder.' }
        }
        $b = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/' {
        $html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'page.html'))
        $transport = if ($Desktop) { 'true' } else { 'false' }
        $b = [Text.Encoding]::UTF8.GetBytes($html.Replace('__VERSION__', [Net.WebUtility]::HtmlEncode($UserAgent.Split('/')[-1])).Replace('__REPO__', $project.name).Replace('__T__', $token).Replace('__DESKTOP__', $transport).Replace('__NONCE__', $nonce))
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.ContentLength64 = $b.Length
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/status' {
        $status = Get-Status
        if (!$Desktop) { $status.Remove('tok') }
        if ($modUpdateJob) {
          $child = $modUpdateJob.ChildJobs[0]
          $status.modUpdateRunning = $modUpdateJob.State -in 'Running','NotStarted'
          $status.modUpdate = if ($modUpdateJob.State -eq 'Failed') { "Update failed: $($child.JobStateInfo.Reason.Message)" }
            elseif ($child.Output.Count) { [string]$child.Output[$child.Output.Count-1] } else { 'Checking installed mods...' }
        }
        # Read the update worker's progress file.
        $progFile = Join-Path $Data 'update-progress.json'
        $progInfo = [IO.FileInfo]::new($progFile)
        if ($progInfo.Exists) {
          $progStamp = "$($progInfo.LastWriteTimeUtc.Ticks)|$($progInfo.Length)"
          if ($script:updateProgressStamp -ne $progStamp) {
            $progress = Read-Json $progFile $null
            if ($progress) {
              $script:updateProgress = $progress
              $script:updateProgressStamp = $progStamp
            }
          }
        }
        $up = $script:updateProgress
        if ($up) {
          $status.modUpdateProgress = $up
          $fresh = $true
          if ($up.at) { try { $fresh = ((Get-Date).ToUniversalTime() - [datetime]::Parse($up.at)).TotalMinutes -lt 2 } catch { } }
          if ($up.phase -eq 'checking' -and $fresh) {
            $status.modUpdateRunning = $true
            $status.modUpdate = "Checking updates: $($up.checked) of $($up.total) installed mods, $($up.found) newer so far."
          } elseif ($up.text) { $status.modUpdate = [string]$up.text }
        }
        $pendingUpdates = @(Get-PendingModUpdates $status.queue).Count
        $available = [IO.FileInfo]::new((Join-Path $Data 'mod-update-available.json'))
        if ($available.Exists) { $status.modUpdatesRevision = "$($available.LastWriteTimeUtc.Ticks)|$($available.Length)" }
        $status.modUpdateCancellable = $status.modUpdateRunning -or $pendingUpdates -gt 0
        if (!$status.modUpdate -and $pendingUpdates) { $status.modUpdate = "$pendingUpdates mod updates pending." }
        $b = [Text.Encoding]::UTF8.GetBytes(($status | ConvertTo-Json -Depth 5 -Compress))
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/available-mod-updates' {
        $available = @{ updates = @((Get-AvailableModUpdates).Values | Sort-Object name) }
        $b = [Text.Encoding]::UTF8.GetBytes(($available | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/completed' {
        # completed mods for the page, fetched only when recentRev changes
        $inv = Get-StatusInventory
        $recent = @(Get-RecentDownloads $inv)
        $rev = Get-RecentRevision $recent
        $b = [Text.Encoding]::UTF8.GetBytes((@{ rev = $rev; recent = $recent } | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/servers' {
        # exact per-server counts: a mod only counts when its own file list matches
        $have = Get-UiHaveIds
        $rows = @($serverList | ForEach-Object {
          $s = $_
          [PSCustomObject]@{ id = $s.id; name = $s.name; mods = $s.mods
                             changed = $s.changed; haveCount = @($s.mods | Where-Object { $have.ContainsKey($_.id) }).Count } })
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = $rows } | ConvertTo-Json -Depth 6 -Compress))
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse' {
        $result = Get-Browse $ctx.Request.QueryString
        $tracked = @($serverList.id)
        foreach ($row in $result.servers) { $row.tracked = $row.id -in $tracked }
        Write-DirectoryJson $ctx.Response $result
      }
      '/browse-server' {
        $s = Get-Detail $ctx.Request.QueryString['id'] -AllowEmpty
        $have = Get-UiHaveIds
        $rows = @(foreach ($mod in $s.mods) {
          $id = Test-ModId $mod.id
          if (!$id) { continue }
          $exp = if ($mod.size -gt 0) { [double]$mod.size }
                 elseif ($sizeMap.ContainsKey($id)) { [double]$sizeMap[$id].bytes } else { 0 }
          @{ id = $id; name = $mod.name; version = $mod.version; expB = $exp; have = $have.ContainsKey($id) }
        })
        $missing = @($rows | Where-Object { -not $_.have })
        $out = Get-ServerPreview $s
        $out.mods = $rows
        $out.hasModList = [bool]($rows.Count -or ($s.online -and !$s.passwordProtected -and $null -ne $s.modCount -and $s.modCount -eq 0))
        $out.tracked = $s.id -in $serverList.id
        $out.haveCount = $rows.Count - $missing.Count
        $out.unknownSizes = @($missing | Where-Object { $_.expB -le 0 }).Count
        $out.missingBytes = [double]($missing | ForEach-Object { $_.expB } | Measure-Object -Sum).Sum
        Write-DirectoryJson $ctx.Response $out
      }
      '/server-history' { Write-DirectoryJson $ctx.Response (Get-ServerHistory $ctx.Request.QueryString['id'] $ctx.Request.QueryString['range']) }
      '/measure-ping' { Write-DirectoryJson $ctx.Response (Measure-ServerRegions) }
      '/start'  { $msg = Invoke-StartQueue;  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/pause'  { $msg = Invoke-PauseQueue; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/verify' { Write-Host (Invoke-Verify); $msg = 'Mods checked.' }
      '/queue-server' { $msg = Invoke-QueueServer $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/resume-all'   { $msg = Invoke-ResumeAll;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/clear-queue'  { $msg = Invoke-ClearQueue;  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/remove-queued-mod' { $msg = Invoke-RemoveQueuedMod $ctx.Request.QueryString['id'] }
      '/requeue-partial-mod' { $msg = Invoke-RequeuePartialMod $ctx.Request.QueryString['id'] }
      '/make-preset' {
        $id = $ctx.Request.QueryString['id']
        if ($ctx.Request.QueryString['background'] -eq '1') {
          $r = Start-PresetJob $id
          $msg = $r.msg; $jobId = $r.job
        } else { $msg = Invoke-MakePreset $id }
      }
      '/search-mods' { Write-DirectoryJson $ctx.Response (Search-Mods $ctx.Request.QueryString) }
      '/mod-details' { Write-DirectoryJson $ctx.Response (Get-WorkshopDetails $ctx.Request.QueryString['id']) }
      '/mod-versions' { Write-DirectoryJson $ctx.Response (Get-WorkshopVersions $ctx.Request.QueryString['id'] $ctx.Request.QueryString['version']) }
      '/add-mod' { $msg = Invoke-AddMod $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/add-server'   { $msg = Invoke-AddServer $ctx.Request.QueryString['id'];   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/cancel-downloads' {
        $msg = Invoke-CancelDownloads
        Stop-ModUpdateCheck
      }
      '/cancel-mod-updates' {
        $msg = Invoke-CancelModUpdates
        Stop-ModUpdateCheck
      }
      '/apply-mod-updates' { $msg = Add-ModUpdateBatch (Get-AvailableModUpdates $ctx.Request.QueryString['id']) }
      '/update-mods' {
        if ($ctx.Request.QueryString['auto'] -eq '1') {
          Write-DashboardError $ctx.Response 400 'Use Check for mod updates in Library to start a check.'
          return
        }
        $scope = [string]$ctx.Request.QueryString['scope']
        $id = [string]$ctx.Request.QueryString['id']
        $checkOnly = $ctx.Request.QueryString['check'] -eq '1'
        $ids = @()
        switch ($scope) {
          'all' {}
          'tracked' { $ids = @($serverList | ForEach-Object { $_.mods.id } | Sort-Object -Unique) }
          'mod' { if (!(Test-ModId $id)) { throw 'Invalid mod ID.' }; $ids = @($id) }
          'server' {
            $server = $serverList | Where-Object id -eq $id | Select-Object -First 1
            if (!$server) { throw 'Unknown server.' }
            $ids = @($server.mods.id)
          }
          default { throw 'Unknown update scope.' }
        }
        if ($modUpdateJob -and $modUpdateJob.State -in 'Running','NotStarted') { throw 'An update check is already running.' }
        if (!$checkOnly -and @(Get-PendingModUpdates (Get-Status).queue).Count) {
          throw 'Mod updates are already queued. Finish or cancel them before checking again.'
        }
        if ($modUpdateJob) { Remove-Job $modUpdateJob }
        Save-Json @{ phase = 'checking'; checked = 0; total = 0; found = 0
          text = 'Checking installed mod versions...'; at = [datetime]::UtcNow.ToString('o') } (Join-Path $Data 'update-progress.json')
        $script:modUpdateJob = Start-Job -ScriptBlock {
          param($scriptPath,$scope,$ids,$root,$data,$api,$agent,$queueRevision,$checkOnly)
          & $scriptPath -Scope $scope -Ids $ids -Root $root -Data $data -ApiBase $api -UserAgent $agent -QueueRevision $queueRevision -CheckOnly:$checkOnly
        } -ArgumentList (Join-Path $PSScriptRoot 'update-mods.ps1'),$scope,$ids,$Root,$Data,$ApiBase,$UserAgent,([string](Get-QueueRevision)),$checkOnly
        $msg = 'Checking installed mod versions...'
      }
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
        $id = [string]$ctx.Request.QueryString['id']
        $r = if ($id.StartsWith('preset-')) { Complete-PresetJob $id } else { Complete-RefreshJob $id }
        $b = [Text.Encoding]::UTF8.GetBytes(($r | ConvertTo-Json -Compress))
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/remove-server'   { $msg = Invoke-RemoveServer  $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      default   {
        $ctx.Response.StatusCode = 404
        $b = [Text.Encoding]::UTF8.GetBytes('{"error":"no such route"}')
        $ctx.Response.ContentType = $JsonType
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
    }
    if ($null -ne $msg) {
      # Log each state-changing request and its source.
      try {
        $src = if ($Desktop) { 'desktop' } elseif ($ctx.Request.UserAgent -match 'PowerShell') { 'api' } else { 'browser' }
        # never write the request token: it is the CSRF guard for these routes
        $what = $ctx.Request.Url.AbsolutePath
        if ($ctx.Request.QueryString['id']) { $what += '?id=' + $ctx.Request.QueryString['id'] }
        Add-Content -LiteralPath (Join-Path $Data 'actions.log') -Encoding UTF8 -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1,7} {2} <- {3}: {4}" -f
          (Get-Date), $src, $what, $ctx.Request.RemoteEndPoint, ($msg -replace '\s+', ' '))
      } catch { }
      $resp = @{ ok = $true; msg = [string]$msg }
      if ($jobId) { $resp.job = [string]$jobId }
      $b = [Text.Encoding]::UTF8.GetBytes(($resp | ConvertTo-Json -Compress))
      $ctx.Response.ContentType = $JsonType
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    }
  } catch {
    Write-Host ("{0}: {1}" -f $path, $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    # Serialize error messages as JSON so paths and other special characters are escaped.
    $b = [Text.Encoding]::UTF8.GetBytes((@{ error = [string]$_.Exception.Message } | ConvertTo-Json -Compress))
    $ctx.Response.StatusCode = 500
    $ctx.Response.ContentType = $JsonType
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
  }
  finally { $ctx.Response.OutputStream.Close() }
}

if ($Desktop) {
  if ($IsLinux) { Add-Type -AssemblyName System.Web.HttpUtility }
  else { Add-Type -AssemblyName System.Web }
  if ($ReadOnly) { $script:inventoryEvery = 15 } elseif (-not $NoHelpers) { Start-DownloadHelpers }
  # One request and one reply per line. Other output is diagnostic text.
  while ($null -ne ($line = [Console]::ReadLine())) {
    try {
      $request = ConvertFrom-Json ($line.TrimStart([char]0xFEFF))
      $url = [uri]::new([uri]'https://reforger.local/', [string]$request.path)
      if ($url.Scheme -ne 'https' -or $url.Authority -ne 'reforger.local') { throw 'Invalid dashboard path.' }
      if ($ReadOnly -and ($request.method -ne 'GET' -or $url.AbsolutePath -notin '/status','/completed')) {
        [Console]::WriteLine('RFMM ' + (@{ status = 403; type = $JsonType; body = '{"error":"read-only worker"}' } | ConvertTo-Json -Compress))
        continue
      }
      $stream = [IO.MemoryStream]::new()
      $reply = [pscustomobject]@{
        Headers = [Net.WebHeaderCollection]::new()
        StatusCode = 200
        ContentType = $JsonType
        ContentLength64 = 0
        Nonce = $null
        OutputStream = $stream
      }
      $ctx = [pscustomobject]@{
        Request = [pscustomobject]@{
          Url = $url
          QueryString = [Web.HttpUtility]::ParseQueryString($url.Query, $utf8)
          HttpMethod = [string]$request.method
          UserAgent = 'Reforger Desktop'
          RemoteEndPoint = 'desktop'
        }
        Response = $reply
      }
      Invoke-DashboardRequest $ctx
      $result = @{
        status = $reply.StatusCode
        type = $reply.ContentType
        body = $utf8.GetString($stream.ToArray())
        nonce = $reply.Nonce
      }
    } catch {
      $result = @{ status = 500; type = $JsonType; body = (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
    }
    [Console]::WriteLine('RFMM ' + ($result | ConvertTo-Json -Compress))
  }
  exit 0
}

function New-LocalDashboardListener {
  $listener = [Net.HttpListener]::new()
  $listener.Prefixes.Add($Url)
  $listener.Prefixes.Add('http://127.0.0.1:8123/')
  $listener
}
$l = New-LocalDashboardListener
try { $l.Start() }
catch {
  # Retry the bind once to allow sockets from a previous dashboard to close.
  Start-Sleep 5
  try { $l.Close(); $l = New-LocalDashboardListener; $l.Start() }
  catch {
    if ($NoHelpers) { throw }
    Write-Host 'dashboard already running - opening browser' -ForegroundColor Cyan
    Start-Process $Url
    exit 0
  }
}
Write-Host '=== Arma Reforger Mods - web dashboard ===' -ForegroundColor White
Write-Host "open: $Url   (keep this window open; closing it only stops the UI, not the download)" -ForegroundColor Cyan
if (-not $NoHelpers) {
  Start-DownloadHelpers
  Start-Process $Url
}
while ($l.IsListening) {
  Invoke-DashboardRequest ($l.GetContext())
}

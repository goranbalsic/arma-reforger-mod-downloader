# Restart the download engine when it stalls and track repeated Workshop refusals.
# The dashboard starts one watchdog per installation.
$ErrorActionPreference = 'Continue'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
. (Join-Path $PSScriptRoot 'state.ps1')
$Cfg = Join-Path $Data 'batch1-serverconfig.json'
$Exe = Get-EngineExecutable $Root
$DsProfile = Join-Path $Root 'serverprofile'
$Addons = Get-ClientAddons $DsProfile
$LogFile = Join-Path $Data 'watchdog.log'
$PauseFlag = Join-Path $Data 'paused.flag'
$SkipFile = Join-Path $Data 'skipped.json'

function Write-Wd([string]$t) { try { "[$(Get-Date -f HH:mm:ss)] $t" | Add-Content $LogFile } catch { } }
function Get-LatestLog {
  Get-ChildItem -LiteralPath (Join-Path $DsProfile 'logs') -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Start-EngineLocked {
  # Acquire the engine lock and check ownership again before restarting.
  $ctl = Lock-Engine
  if (-not $ctl) { return $false }
  try {
    if ((Test-Path -LiteralPath $PauseFlag) -or !((Get-Queued $Cfg).Count)) { return $false }
    $cur = Get-OwnEngine $Cfg
    if ($null -eq $cur) { return $false }   # cannot ask: do not risk a second engine
    if ($cur -or (Get-EngineProcesses)) { return $false }
    Start-DownloadEngine
    return $true
  } finally { $ctl.ReleaseMutex() }
}

function Stop-OwnerlessDownloads {
  $ctl = Lock-Engine
  if (!$ctl) { return $false }
  try {
    $marker = Read-Json (Join-Path $Data 'desktop-owner.json') $null
    if ($marker -and $marker.token -ne $env:RFMM_DESKTOP_OWNER_TOKEN) { return $true }
    New-Item -ItemType File -Force (Join-Path $Data 'paused.flag') | Out-Null
    $engine = Get-OwnEngine $Cfg
    if ($null -eq $engine) { return $false }
    foreach ($process in $engine) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $remaining = Get-OwnEngine $Cfg
    if ($null -eq $remaining -or @($remaining).Count) { return $false }
    Write-Wd 'desktop closed - download engine stopped; queue kept'
    return $true
  } finally { $ctl.ReleaseMutex() }
}

$owner = if ($env:RFMM_DESKTOP_OWNER_PID) {
  Get-Process -Id $env:RFMM_DESKTOP_OWNER_PID -ErrorAction SilentlyContinue
}
$mutexName = 'ReforgerDownloaderWatchdog'
if ($env:RFMM_DESKTOP_OWNER_TOKEN) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $path = [IO.Path]::GetFullPath($Cfg)
    if (!$IsLinux) { $path = $path.ToUpperInvariant() }
    $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))).Replace('-', '')
    $mutexName += "-desktop-$key"
  } finally { $sha.Dispose() }
}
if ($IsLinux) {
  $mutex = Enter-DownloaderFileLock (Get-DownloaderLockPath $mutexName) 5000
  if (!$mutex) { exit 0 }
} else {
  $mutex = [System.Threading.Mutex]::new($false, $mutexName)
  if (-not $mutex.WaitOne(5000)) { exit 0 }
}

$fail = @{}
$scanFile = ''      # log file the failure scan is reading
$scanAt = 0         # lines of that file already counted
$scanCur = $null    # mod id whose outcome is still pending
# Log each of these states once per transition.
$saidEmpty = $false
$saidBlind = $false
$saidPause = $false
$saidUnreadable = $false
$watchedEngine = $null
while ($true) {
  if ($watchedEngine) {
    # Wake on engine exit without polling the process list more often.
    for ($second = 0; $second -lt 15; $second++) {
      if ($owner) {
        if ($owner.WaitForExit(1000)) { break }
      } else { Start-Sleep -Seconds 1 }
      try { if ($watchedEngine.HasExited) { break } }
      catch { } # Recheck ownership on the regular tick if the handle is unavailable.
    }
  } elseif ($owner) {
    $null = $owner.WaitForExit(15000)
  } elseif (!$env:RFMM_DESKTOP_OWNER_PID) { Start-Sleep 15 }
  $watchedEngine = $null
  if ($env:RFMM_DESKTOP_OWNER_PID -and (!$owner -or $owner.HasExited)) {
    if (Stop-OwnerlessDownloads) { break }
    Start-Sleep 2
    continue
  }
  if (-not (Test-Path $Cfg)) { continue }
  if (Test-Path $PauseFlag) {
    if (-not $saidPause) { Write-Wd 'paused - not restarting anything until the queue is started again'; $saidPause = $true }
    continue
  }
  if ($saidPause) { Write-Wd 'pause cleared - watching again'; $saidPause = $false }
  $queued = Get-Queued $Cfg
  # Skip this tick when the queue cannot be read.
  if ($null -eq $queued) {
    if (-not $saidUnreadable) { Write-Wd 'cannot read the queue config right now - waiting for it to become readable'; $saidUnreadable = $true }
    continue
  }
  if ($saidUnreadable) { Write-Wd 'queue config readable again'; $saidUnreadable = $false }
  $ds = Get-OwnEngine $Cfg
  # Log ownership errors once until the next successful query.
  if ($null -eq $ds) {
    if (-not $saidBlind) {
      Write-Wd 'cannot read the process list right now - waiting for it to recover'
      $saidBlind = $true
    }
    continue
  }
  if ($saidBlind) { Write-Wd 'process list readable again'; $saidBlind = $false }

  if (-not $ds.Count) {
    if ($queued.Count -eq 0) {
      # Log the empty queue once and clear refusal counts for the finished batch.
      if (-not $saidEmpty) { Write-Wd 'queue empty - downloader done'; $saidEmpty = $true; $fail = @{} }
      continue
    }
    $saidEmpty = $false

    # Resume reading the previous engine log to count each Workshop refusal once.
    $lg = Get-LatestLog
    if ($lg -and $lg.LastWriteTime -gt (Get-Date).AddMinutes(-20)) {
      if ($scanFile -ne $lg.FullName) { $scanFile = $lg.FullName; $scanAt = 0; $scanCur = $null }
      $lines = @(Get-Content $lg.FullName -ErrorAction SilentlyContinue)
      $scan = Get-WorkshopFailures $lines $scanAt $scanCur
      $scanAt = $scan.next
      $scanCur = $scan.current
      foreach ($k in $scan.counts.Keys) {
        if ($fail.ContainsKey($k)) { $fail[$k] += $scan.counts[$k] } else { $fail[$k] = $scan.counts[$k] }
      }
      if ($fail.Count) {
        $drop = @($fail.Keys | Where-Object { $fail[$_] -ge 3 })
        if ($drop.Count) {
          # serialised read-modify-write; the engine is dead in this branch
          $gone = @()
          try {
            $gone = @(Update-Cfg {
              param($cfg)
              $names = @($cfg.game.mods | Where-Object { $drop -contains $_.modId } | ForEach-Object { $_.name })
              $cfg.game.mods = @($cfg.game.mods | Where-Object { $drop -notcontains $_.modId })
              $names
            } $Cfg)
          } catch {
            Write-Wd "could not rewrite the queue (skipping this tick): $($_.Exception.Message)"
            continue
          }
          $queued = Get-Queued $Cfg
          if ($null -eq $queued) { $queued = ,@() }
          Write-Wd "skipped after 3 Workshop errors: $($gone -join ', ')"
          try {
            $prev = if (Test-Path $SkipFile) { @(Get-Content $SkipFile -Raw | ConvertFrom-Json) } else { @() }
            Save-Json @($prev + $gone | Select-Object -Unique) $SkipFile
          } catch { Write-Wd "could not save the Workshop skip history: $($_.Exception.Message)" }
        }
      }
    }

    try {
      $trim = & (Join-Path $PSScriptRoot 'trim-config.ps1')
      if ($LASTEXITCODE -ne 0) { throw ($trim -join ' ') }
    }
    catch { Write-Wd "trim failed: $($_.Exception.Message)"; continue }   # never start an untrimmed list (1 MB trap)
    $queued = Get-Queued $Cfg
    if ($null -eq $queued) {
      if (-not $saidUnreadable) { Write-Wd 'cannot read the queue config right now - waiting for it to become readable'; $saidUnreadable = $true }
      continue
    }
    if ($queued.Count -eq 0) {
      if (-not $saidEmpty) { Write-Wd 'queue empty - downloader done'; $saidEmpty = $true }
      continue
    }
    if (-not (Start-EngineLocked)) { Write-Wd 'a start/stop is in progress - retrying next tick'; continue }
    Write-Wd "restarted downloader ($(@($queued).Count) mods left)"
    continue
  }

  if ($queued.Count -gt 0) {
    $lg = Get-LatestLog
    $runningEngine = $ds | Select-Object -First 1
    $started = try { $runningEngine.StartTime } catch { $null }
    $lastWrite = if ($lg) { $lg.LastWriteTimeUtc } else { [datetime]::MinValue }
    if ($started -and (Test-EngineTransferStalled $started $lastWrite $Addons $queued (Get-Date))) {
      $ctl = Lock-Engine
      if ($ctl) {
        try {
          $owners = Get-OwnEngine $Cfg
          $sameEngine = $owners | Where-Object { $_.Id -eq $runningEngine.Id }
          if (!$sameEngine -or (Test-Path -LiteralPath $PauseFlag) -or !((Get-Queued $Cfg).Count)) { continue }
          $latest = Get-LatestLog
          if ($latest) { $lastWrite = $latest.LastWriteTimeUtc }
          if (!(Test-EngineTransferStalled $started $lastWrite $Addons $queued (Get-Date))) { continue }
          Write-Wd "downloader inactive 5 min with $($queued.Count) mods queued - restarting it"
          $sameEngine | Stop-Process -Force
        } finally { $ctl.ReleaseMutex() }
      } else {
        Write-Wd 'cannot take the engine lock - not restarting this time'
        continue
      }
      Start-Sleep 2
      # Trim completed mods before restarting to stay within the download-list limit.
      try {
        $trim = & (Join-Path $PSScriptRoot 'trim-config.ps1')
        if ($LASTEXITCODE -ne 0) { throw ($trim -join ' ') }
      }
      catch { Write-Wd "trim failed: $($_.Exception.Message)"; continue }
      $null = Start-EngineLocked
    } elseif ($started -and ((Get-Date) - $started).TotalSeconds -ge 15) {
      # Keep the normal retry delay for engines that fail during startup.
      $watchedEngine = $runningEngine
    }
    continue
  }

  # Wait for 30 seconds of log silence before stopping an engine with an empty queue.
  $lg = Get-LatestLog
  if ($lg -and $lg.LastWriteTime -gt (Get-Date).AddSeconds(-30)) { continue }
  $ctl = Lock-Engine
  try {
    $now = Get-Queued $Cfg   # $null = unreadable; never stop on an unreadable queue
    if ($null -eq $now) { continue }
    if ($ctl -and $now.Count -eq 0) {
      $ds | Stop-Process -Force
      Write-Wd 'queue empty - engine stopped'
    }
  } finally { if ($ctl) { $ctl.ReleaseMutex() } }
}

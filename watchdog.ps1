# Keeps the dedicated server (used as a downloader) alive.
#
# The DS downloads the queued mods, then exits: it cannot create a game world
# while mods are still missing. It can also hang for minutes when the Workshop
# API/CDN fails. This process restarts it, and skips a mod the Workshop keeps
# refusing so one bad mod cannot stall the whole queue.
#
# Started by download-web.ps1. Single instance (named mutex).
$ErrorActionPreference = 'Continue'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
. "$PSScriptRoot\state.ps1"
$Cfg = "$Data\batch1-serverconfig.json"
$Exe = "$Root\armar-server\ArmaReforgerServer.exe"
$DsProfile = "$Root\serverprofile"
$LogFile = "$Data\watchdog.log"
$PauseFlag = "$Data\paused.flag"
$SkipFile = "$Data\skipped.json"

function Write-Wd([string]$t) { try { "[$(Get-Date -f HH:mm:ss)] $t" | Add-Content $LogFile } catch { } }
function Get-LatestLog {
  Get-ChildItem "$DsProfile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Start-EngineLocked {
  # the dashboard can start the engine at the same moment: a named mutex + a
  # re-check means never two processes on one profile
  $ctl = Lock-Engine
  if (-not $ctl) { return $false }
  try {
    $cur = Get-OwnEngine $Cfg
    if ($null -eq $cur) { return $false }   # cannot ask: do not risk a second engine
    if ($cur) { return $false }
    Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$DsProfile`"" `
      -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    return $true
  } finally { $ctl.ReleaseMutex() }
}

$mutex = [System.Threading.Mutex]::new($false, 'ReforgerDownloaderWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }

$fail = @{}
$scanFile = ''      # log file the failure scan is reading
$scanAt = 0         # lines of that file already counted
$scanCur = $null    # mod id whose outcome is still pending
$saidEmpty = $false   # "queue empty" is logged once per transition, not every 15 s
$saidBlind = $false   # same for "cannot read the process list"
$saidPause = $false   # and for "paused": silent skipping looked exactly like a hung watchdog
$saidUnreadable = $false  # and for "config cannot be read": never treat it as "queue empty"
while ($true) {
  Start-Sleep 15
  if (-not (Test-Path $Cfg)) { continue }
  if (Test-Path $PauseFlag) {
    if (-not $saidPause) { Write-Wd 'paused - not restarting anything until the queue is started again'; $saidPause = $true }
    continue
  }
  if ($saidPause) { Write-Wd 'pause cleared - watching again'; $saidPause = $false }
  $queued = Get-Queued $Cfg
  # a read/parse failure is not an empty queue: skipping the tick prevents the
  # "queue empty - done" path from stopping a running engine
  if ($null -eq $queued) {
    if (-not $saidUnreadable) { Write-Wd 'cannot read the queue config right now - waiting for it to become readable'; $saidUnreadable = $true }
    continue
  }
  if ($saidUnreadable) { Write-Wd 'queue config readable again'; $saidUnreadable = $false }
  $ds = Get-OwnEngine $Cfg
  # log the transition, not every tick: a busy machine made this fire 25 times in a
  # row (25 lines that hid the rest of the log) while nothing was being done
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
      # log the transition only: this branch runs every 15 s forever once the
      # batch is done, and used to grow watchdog.log without bound. A finished
      # batch also forgets the strikes, so a mod re-queued later starts clean.
      if (-not $saidEmpty) { Write-Wd 'queue empty - downloader done'; $saidEmpty = $true; $fail = @{} }
      continue
    }
    $saidEmpty = $false

    # remember Workshop refusals from the run that just ended. Walk the WHOLE run
    # log: a refusal follows the "started" line of the mod that caused it, and a
    # run logs ~20 "started" lines, so a last-80-lines window usually held none and
    # the skip almost never fired (the 5-minute stall killer did the work instead).
    # Resumable scan: counting the same lines on every 15 s tick dropped a mod from
    # the queue after ONE real refusal.
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
          } catch { }
        }
      }
    }

    try { & "$PSScriptRoot\trim-config.ps1" | Out-Null }
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

  # running: kill it if it stopped writing its log while mods are still queued.
  # A single fragment takes minutes on a slow line, so allow 5 minutes of silence
  # before declaring it hung - every restart throws away the fragment in flight.
  if ($queued.Count -gt 0) {
    $lg = Get-LatestLog
    if (-not $lg -or $lg.LastWriteTime -lt (Get-Date).AddMinutes(-5)) {
      Write-Wd "downloader silent 5 min with $($queued.Count) mods queued - restarting it"
      # kill only while holding the engine lock: the dashboard starts and stops the
      # same engine, and a kill outside the lock can land in its start sequence
      $ctl = Lock-Engine
      if ($ctl) {
        try { $ds | Stop-Process -Force } finally { $ctl.ReleaseMutex() }
      } else {
        Write-Wd 'cannot take the engine lock - not restarting this time'
        continue
      }
      Start-Sleep 2
      # trim before restarting: a finished mod left in the list pushes the download
      # request over the DS's ~1 MB limit, and the restart would insta-crash
      try { & "$PSScriptRoot\trim-config.ps1" | Out-Null }
      catch { Write-Wd "trim failed: $($_.Exception.Message)" }
      $null = Start-EngineLocked
    }
    continue
  }

  # Nothing queued but the engine is still there: the DS does not exit by itself,
  # so it sat for 6 minutes holding 2 GB, and the next Start found a live engine
  # that keeps reading its old empty list - the mods queued after it never
  # downloaded. 30 s of log silence so an assembly that just emptied the list is
  # never cut off.
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

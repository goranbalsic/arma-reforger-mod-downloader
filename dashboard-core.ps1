# Dashboard functions. Dot-sourced by download-web.ps1; no top-level side effects.
function Get-Cfg {
  Read-EngineConfig $Cfg
}
function Get-QueueRevision {
  $path = Join-Path $Data 'queue-revision.txt'
  if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) }
}
function Reset-QueueRevision {
  # Background checks started before a queue edit cannot undo that edit.
  [IO.File]::WriteAllText((Join-Path $Data 'queue-revision.txt'), [guid]::NewGuid().ToString('N'))
}
function Get-PendingModUpdates($Queue) {
  $batch = Read-Json (Join-Path $Data 'mod-update-batch.json') $null
  $targets = @{}
  foreach ($update in $batch.updates) { $targets[$update.modId] = $update.version }
  $Queue | Where-Object { $_.version -and $targets[$_.id] -eq $_.version }
}
function Invoke-CancelModUpdates {
  $ctl = Lock-Engine
  if (!$ctl) { throw 'The downloader is busy. Try cancelling again.' }
  try {
    Reset-QueueRevision
    $batchPath = Join-Path $Data 'mod-update-batch.json'
    $batch = Read-Json $batchPath $null
    $targets = @{}
    foreach ($update in $batch.updates) { $targets[$update.modId] = $update.version }
    $pending = @((Get-Cfg).game.mods | Where-Object { $_.version -and $targets[$_.modId] -eq $_.version })
    if ($pending.Count) {
      $engine = Get-DS -Fresh
      if ($null -eq $engine) { throw 'Cannot check whether the downloader is running. Try cancelling again.' }
      if (@($engine).Count) { Stop-DS | Out-Null }
      Update-Cfg {
        param($cfg)
        $cfg.game.mods = @($cfg.game.mods | Where-Object { !$_.version -or $targets[$_.modId] -ne $_.version })
      } $Cfg | Out-Null
      if (@($engine).Count -and @((Get-Cfg).game.mods).Count) { Start-DS | Out-Null }
    }
    if (Test-Path -LiteralPath $batchPath) { Remove-Item -LiteralPath $batchPath -Force }
    'Mod updates cancelled.'
  } finally { $ctl.ReleaseMutex() }
}
function Get-SkippedNames {
  # written by watchdog.ps1 when the Workshop refuses a mod three times in a row
  if (((Get-Date) - $script:skippedAt).TotalSeconds -lt 10) { return $script:skipped }
  $p = Join-Path $Data 'skipped.json'
  # Read-Json cannot throw: a corrupt file is moved aside and the default is used,
  # so one bad file cannot take /status down
  $script:skipped = @()
  if (Test-Path $p) {
    $data = Read-Json $p @()
    if ($null -ne $data) { $script:skipped = @($data) }
  }
  $script:skippedAt = Get-Date
  $script:skipped
}
function Get-DS([switch]$Fresh) {
  # Our engine only (state.ps1: Get-OwnEngine), cached 2 s because /status polls
  # often. A caller that is about to write the config MUST pass -Fresh: a cached
  # "nothing running" made add-mod / refresh-servers append while the engine was
  # running, and the engine rewrites that file on exit, so the append vanished.
  # Empty array = none. $null = the query failed - not the same thing.
  if (-not (Get-EngineProcesses)) { return ,@() }
  if (-not $Fresh -and $script:dsAt -and ((Get-Date) - $script:dsAt).TotalSeconds -lt 2) {
    if ($null -eq $script:dsCache) { return $null }
    return ,$script:dsCache
  }
  $found = Get-OwnEngine $Cfg
  $script:dsCache = $found
  $script:dsAt = Get-Date
  if ($null -eq $found) { return $null }
  ,$found
}
function Get-Log {
  # newest console.log; cached 3 s because the DS is writing to disk while we scan
  if ($script:logCache -and ((Get-Date) - $script:logCacheAt).TotalSeconds -lt 3) { return $script:logCache }
  $script:logCache = Get-ChildItem "$DsProfile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $script:logCacheAt = Get-Date
  $script:logCache
}
function Get-AddonsBytes {
  # total size of the game's addons folder. The page shows this as "done", so the
  # number is the folder you can look at in Explorer, not an estimate.
  if (((Get-Date) - $script:clBytesAt).TotalSeconds -lt 15) { return $script:clBytes }
  $sum = [double]0
  $root = [IO.DirectoryInfo]::new((Get-ClientAddons $DsProfile))
  if ($root.Exists) {
    try { foreach ($f in $root.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $sum += $f.Length } } catch { }
  }
  $script:clBytes = $sum; $script:clBytesAt = Get-Date
  $sum
}
function Get-ClientIds {
  # exact rule (the addon's own meta file list), same as Get-HaveIds and verify.
  # The old +/-2 MB folder-size tolerance reported mods as installed when only a
  # fifth of their paks were on disk (WCS_LoadoutEditor: 202 KB there, 921 KB
  # expected), so the dashboard said 980/980 over a broken client copy.
  # Cost is paid once: Test-AddonComplete caches per folder + mtime.
  if (((Get-Date) - $script:clCacheAt).TotalSeconds -lt 10) { return $script:clCache }
  $ids = [Collections.Generic.List[string]]::new()
  $root = [IO.DirectoryInfo]::new((Get-ClientAddons $DsProfile))
  if ($root.Exists) {
    foreach ($d in $root.EnumerateDirectories()) {
      $m = [regex]::Match($d.Name, '_([0-9A-F]{16})$')
      if (-not $m.Success) { continue }
      if (Test-AddonComplete $d.FullName $d.LastWriteTime) { $ids.Add($m.Groups[1].Value) }
    }
  }
  $script:clCache = $ids.ToArray(); $script:clCacheAt = Get-Date
  $script:clCache
}
function Get-DirMap {
  # one .NET enumeration pass, grouped by folder: 111 ms for 6k files where
  # Get-ChildItem -Recurse took 236 ms. mtime = the folder's newest file time:
  # the DS appends to preallocated chunks without touching directory times.
  # 3 s, not 0.5: a cold /status took longer than its own cache TTL, so with the
  # page polling every ~0.4 s the cache never hit and every poll rescanned the disk
  if (((Get-Date) - $script:dirCacheAt).TotalSeconds -lt 3) { return $script:dirCache }
  $map = @{}
  $root = [IO.DirectoryInfo]::new($Addons)
  if ($root.Exists) {
    $baseLen = $root.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1
    try {
      foreach ($f in $root.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
        # first path segment = the mod folder: the DS downloads into <mod>\temp\,
        # so the immediate parent name is not the mod (it would hide all progress)
        $rel = $f.FullName.Substring($baseLen); $cut = $rel.IndexOf([IO.Path]::DirectorySeparatorChar)
        if ($cut -lt 0) { continue }   # file directly in addons\, not a mod
        $dir = $rel.Substring(0, $cut)
        $m = [regex]::Match($dir, '_([0-9A-F]{16})$')
        if (-not $m.Success) { continue }
        $g = $m.Groups[1].Value
        # old pre-batch RHS packs sit in some folders under the same name but a
        # different id. Skip only those: a blanket name filter hid the two RHS
        # packs the queue actually downloads, so they had no progress and no speed.
        if ($dir -match '^RHS-ContentPack0[12]_' -and -not $sizeMap.ContainsKey($g)) { continue }
        $e = $map[$g]
        if (-not $e) {
          $e = $map[$g] = @{ name = $dir -replace '_[0-9A-F]{16}$', ''; bytes = [double]0
                             assembled = 0; mtime = $f.LastWriteTime
                             path = (Join-Path $Addons $dir) }
        }
        $e.bytes += $f.Length
        if ($f.LastWriteTime -gt $e.mtime) { $e.mtime = $f.LastWriteTime }
        if ($f.Name -in 'addon.gproj','meta','resourceDatabase.rdb') { $e.assembled++ }
      }
    } catch { }   # an unreadable folder must not take the dashboard down
  }
  foreach ($e in $map.Values) { $e.assembled = ($e.assembled -eq 3) }
  $script:dirCache = $map; $script:dirCacheAt = Get-Date
  $map
}
function Get-TransferSnapshot($Log, [datetime]$Now, [datetime]$StartedAt) {
  $result = @{ mods = @{}; current = $null; speedB = 0; speedAge = 999 }
  if (!$Log) { return $result }
  $written = [IO.File]::GetLastWriteTimeUtc($Log.FullName)
  if ($written -lt $StartedAt.ToUniversalTime()) { return $result }

  $logRun = "$($Log.FullName)|$($StartedAt.Ticks)"
  $cacheKey = "$logRun|$($written.Ticks)"
  if ($script:transferLogKey -ne $cacheKey) {
    $cached = @{ mods = @{}; current = $null; speedAt = $null; speedB = 0 }
    if ($script:transferLogRun -eq $logRun -and $script:transferLogMetrics) {
      $cached.current = $script:transferLogMetrics.current
    }
    foreach ($line in Get-Content -LiteralPath $Log.FullName -Tail 160 -Encoding UTF8 -ErrorAction SilentlyContinue) {
      $entry = [regex]::Match($line, '^\s*(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+BACKEND(?:\s*\([A-Z]+\))?\s*:\s*(.+)$')
      if (!$entry.Success) { continue }
      $elapsed = [timespan]::Zero
      if (![timespan]::TryParse($entry.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [ref]$elapsed)) { continue }
      $at = $Now.Date.Add($elapsed)
      if ($at -gt $Now.AddSeconds(2)) { $at = $at.AddDays(-1) }
      if ($at -lt $StartedAt) { continue }
      $body = $entry.Groups[2].Value
      if ($body.StartsWith('Server registered')) {
        $cached.current = $null
        $cached.mods.Clear()
        $cached.speedAt = $null
        continue
      }
      if ($body.StartsWith('Failed to fetch addon details') -and $cached.current) {
        $cached.mods.Remove($cached.current.name)
        $cached.current = $null
        $cached.speedAt = $null
        continue
      }
      $start = [regex]::Match($body, '^Addon Download started ([a-fA-F0-9]{16}) - (.+)$')
      if ($start.Success -and (!$cached.current -or $at -ge $cached.current.at)) {
        $cached.current = @{ id = $start.Groups[1].Value; name = $start.Groups[2].Value.Trim(); at = $at }
      }
      $progress = [regex]::Match($body, '^(.+?):\s*\[[^\]]*\]\s*\d+%\s*(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?) MB')
      if ($progress.Success) {
        $name = $progress.Groups[1].Value.Trim()
        $total = [double]$progress.Groups[3].Value * 1MB
        $done = [Math]::Min($total, [double]$progress.Groups[2].Value * 1MB)
        $cached.mods[$name] = @{ name = $name; b = $done; expB = $total; at = $at }
      }
      $speed = [regex]::Match($body, '^Download speed ([0-9.]+) KB/s')
      if ($speed.Success) {
        $cached.speedAt = $at
        $cached.speedB = [Math]::Round([double]$speed.Groups[1].Value * 1KB)
      }
    }
    $script:transferLogRun = $logRun
    $script:transferLogKey = $cacheKey
    $script:transferLogMetrics = $cached
  }

  $result.mods = $script:transferLogMetrics.mods
  $result.current = $script:transferLogMetrics.current
  if ($script:transferLogMetrics.speedAt) {
    $age = [Math]::Max(0.0, ($Now - $script:transferLogMetrics.speedAt).TotalSeconds)
    if ($age -le 30) {
      $result.speedAge = [Math]::Round($age)
      $result.speedB = $script:transferLogMetrics.speedB
    }
  }
  $result
}
function Get-Status {
  $dirs = Get-DirMap
  $engines = Get-DS
  $engine = $engines | Select-Object -First 1
  $runningNow = [bool]$engine
  $now = Get-Date
  $transfer = @{ mods = @{}; current = $null; speedB = 0; speedAge = 999 }
  if ($runningNow) {
    $transfer = Get-TransferSnapshot (Get-Log) $now $engine.StartTime
  }
  $clIds = Get-ClientIds
  $clSet = @{}
  foreach ($i in $clIds) { $clSet[$i] = $true }
  # complete = folder stable (no writes 2 min) AND size matches the Workshop size.
  # The 3 marker files are only used when the size is unknown: many Workshop mods
  # ship without addon.gproj (8-file packs), and requiring it left them unfinished
  # forever - never synced, so the launcher showed them as missing.
  if (![object]::ReferenceEquals($script:completedDirs, $dirs)) {
    $completed = @{}
    foreach ($e in $dirs.GetEnumerator()) {
      $d = $e.Value
      if ($d.mtime -gt $now.AddMinutes(-2)) { continue }
      if (-not (Test-AddonComplete $d.path $d.mtime)) { continue }
      $completed[$e.Key] = $true
    }
    $script:recentDownloads = @($dirs.GetEnumerator() | Where-Object { $completed.ContainsKey($_.Key) } |
      Sort-Object { $_.Value.mtime } -Descending | ForEach-Object {
        @{ id = $_.Key; name = $_.Value.name; b = [double]$_.Value.bytes }
      })
    $script:completedDirs = $dirs
  }
  $recent = $script:recentDownloads

  $queued = @((Get-Cfg).game.mods)
  $batchBytes = [double]0
  $doneBytes = [double]0
  $doneCount = 0
  $unknownSizes = 0
  $estimatedSizes = 0
  $active = @{}
  $queueList = @(foreach ($mod in $queued) {
    $id = Test-ModId $mod.modId
    if (!$id) { continue }
    $dir = $dirs[$id]
    $report = if ($mod.name) { $transfer.mods[[string]$mod.name] }
    if (!$report -and $dir.name) { $report = $transfer.mods[$dir.name] }
    if ($transfer.current.id -eq $id) {
      $report = $transfer.mods[$transfer.current.name]
      if ($report -and $report.at -lt $transfer.current.at) { $report = $null }
    }
    $expected = if ($report -and $report.expB -gt 0) { $report.expB } elseif ($mod.size) { [double]$mod.size } else { [double]$sizeMap[$id].bytes }
    $complete = if ($mod.version) {
      $dir -and (Get-InstalledVersion $dir.path) -eq $mod.version -and (Test-AddonComplete $dir.path $dir.mtime)
    } else {
      $clSet.ContainsKey($id) -or ($dir -and (Test-AddonComplete $dir.path $dir.mtime))
    }
    if ($complete) {
      $doneCount++
      if ($dir -and !$report) { $expected = [double]$dir.bytes }
      $doneBytes += $expected
    } else {
      if ($expected -le 0) { $unknownSizes++ }
      elseif (!$report) { $estimatedSizes++ }
      if ($report) {
        $doneBytes += $report.b
        if (($now - $report.at).TotalSeconds -le 35) {
          $active[$report.name] = @{ id = $id; name = $report.name; b = $report.b; expB = $report.expB
            pct = if ($report.expB) { [Math]::Round(100 * $report.b / $report.expB, 1) } else { 0 } }
        }
      }
      if (!$report -and $transfer.current.id -eq $id -and ($now - $transfer.current.at).TotalSeconds -le 35) {
        $active[$transfer.current.name] = @{ id = $id; name = $transfer.current.name }
      }
      @{ id = $id; name = $mod.name; version = $mod.version }
    }
    $batchBytes += $expected
  })
  # Steam can fetch dependencies which are absent from the configured mod list.
  foreach ($entry in $dirs.GetEnumerator()) {
    $report = $transfer.mods[[string]$entry.Value.name]
    if ($report -and !$active.ContainsKey($report.name) -and
        ($now - $report.at).TotalSeconds -le 35 -and !(Test-AddonComplete $entry.Value.path $entry.Value.mtime)) {
      $active[$report.name] = @{ id = $entry.Key; name = $report.name; b = $report.b; expB = $report.expB
        pct = if ($report.expB) { [Math]::Round(100 * $report.b / $report.expB, 1) } else { 0 } }
    }
  }
  if ($transfer.current -and !$active.ContainsKey($transfer.current.name)) {
    $currentDir = $dirs[$transfer.current.id]
    $latest = $transfer.mods[$transfer.current.name]
    $lastActivity = if ($latest -and $latest.at -ge $transfer.current.at) { $latest.at } else { $transfer.current.at }
    if (($now - $lastActivity).TotalSeconds -le 35 -and
        (!$currentDir -or !(Test-AddonComplete $currentDir.path $currentDir.mtime))) {
      $active[$transfer.current.name] = if ($latest -and $latest.at -ge $transfer.current.at) {
        @{ id = $transfer.current.id; name = $latest.name; b = $latest.b; expB = $latest.expB
          pct = if ($latest.expB) { [Math]::Round(100 * $latest.b / $latest.expB, 1) } else { 0 } }
      } else { @{ id = $transfer.current.id; name = $transfer.current.name } }
    }
  }
  if (!$active.Count) { $transfer.speedB = 0 }
  if (!$queueList.Count) {
    $batchBytes = $doneBytes = $doneCount = $unknownSizes = $estimatedSizes = 0
    $queued = @()
  }
  @{ running = $runningNow; paused = (Test-Path -LiteralPath (Join-Path $Data 'paused.flag'))
     speedB = $transfer.speedB; speedAge = $transfer.speedAge
     doneB = $doneBytes; totalB = $batchBytes; unknownSizes = $unknownSizes; estimatedSizes = $estimatedSizes
     pct = if ($batchBytes -gt 0 -and !$unknownSizes) { [int](100 * $doneBytes / $batchBytes) } else { 0 }
     pctF = if ($batchBytes -gt 0 -and !$unknownSizes) { [Math]::Round(100 * $doneBytes / $batchBytes, 2) } else { 0 }
     doneCount = $doneCount; totalMods = $queued.Count
     addonsB = (Get-AddonsBytes)
     active = @($active.Values); recent = @($recent); cl = $clIds; failed = (Get-SkippedNames)
     queue = @($queueList); queueRevision = (Get-QueueRevision); tok = $token; verify = $verify }
}
function Start-DS {
  $ctl = Lock-Engine
  if (-not $ctl) { return 'another start/stop is in progress - try again' }
  try {
    if (!@((Get-Cfg).game.mods).Count) { return 'nothing to download - the queue is empty' }
    $mine = Get-DS -Fresh
    if ($null -eq $mine) { return 'cannot read the process list right now - press Start again' }
    if (@($mine).Count) { return 'already running' }
    # a server we did not start shares the profile folder the engine writes to:
    # refuse instead of running two of them (and never stop theirs on Pause)
    if (Get-EngineProcesses) {
      return 'another ArmaReforgerServer is already running - close it, then press Start'
    }
    # the 1 MB download-list trap: trimming is lossless (the DS skips done mods
    # anyway); skipping it makes the DS insta-crash ~30 s after a false "started"
    $trim = & "$PSScriptRoot\trim-config.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare the download queue: $($trim -join ' ')" }
    # nothing left after the trim: starting the DS here leaves a game server
    # running a world forever, doing no work
    $left = @((Get-Cfg).game.mods).Count
    if ($left -eq 0) { return 'nothing to download - the queue is empty' }
    Remove-Item (Join-Path $Data 'paused.flag') -Force -ErrorAction SilentlyContinue
    Start-DownloadEngine
    # no 25 s sleep here: it froze the only HTTP thread (and the mirror with it).
    # The watchdog restarts a DS that dies within ~20 s, and /status shows the truth.
    'Downloads started.'
  } finally { $ctl.ReleaseMutex() }
}
function Stop-DS {
  $ctl = Lock-Engine
  if (-not $ctl) { throw 'another start/stop is in progress - try again' }
  try {
    New-Item -ItemType File -Force (Join-Path $Data 'paused.flag') | Out-Null
    # Prove the engine is gone before writing the config: if the process list
    # cannot be read we must not claim "paused" - the callers write right after.
    $p = Get-DS -Fresh
    if ($null -eq $p) { throw 'cannot read the process list right now - nothing was changed, try again in a moment' }
    if (-not $p) { return 'not running' }
    $p | Stop-Process -Force
    # wait for the process to actually die: a 1 s sleep can be too short, and
    # Start-DS would then see the dying process and report "already running"
    foreach ($i in 1..20) {
      $remaining = Get-DS -Fresh
      if ($null -ne $remaining -and !@($remaining).Count) { return 'Downloads paused.' }
      Start-Sleep -Milliseconds 500
    }
    throw 'could not confirm the downloader stopped'
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-Verify {
  # shortcut: verifies only the batch mods against Workshop sizes; dependency
  # mods the DS auto-pulls are outside sizeMap and skipped - upgrade by adding
  # their ids to the sizes file if deps ever need checking
  $dirs = Get-DirMap
  $clSet = @{}
  foreach ($i in (Get-ClientIds)) { $clSet[$i] = $true }
  $queued = @{}
  try { foreach ($m in (Get-Cfg).game.mods) { $queued[$m.modId] = $true } } catch { }
  $ok = 0; $partial = 0; $pending = 0; $suspects = @()
  foreach ($id in $sizeMap.Keys) {
    $sm = $sizeMap[$id]; $exp = [double]$sm.bytes
    $d = $dirs[$id]
    $dsOk = $d -and (Test-AddonComplete $d.path $d.mtime)
    if ($dsOk -or $clSet.ContainsKey($id)) { $ok++; continue }   # installed somewhere is installed
    if (-not $d) { $pending++; continue }
    $partial++
    # a mod that is still queued is downloading, not a re-download candidate
    if (-not $queued.ContainsKey($id)) { $suspects += @{ id = $id; name = $d.name; expB = [double]$exp; actB = [double]$d.bytes } }
  }
  $script:verify = @{ id = [guid]::NewGuid().ToString('N'); at = (Get-Date -f 'HH:mm:ss'); ok = $ok; partial = $partial
                      pending = $pending; suspects = $suspects }
  "verify: $ok ok, $partial partial, $pending pending, $($suspects.Count) suspects"
}
function Invoke-RequeuePartialMod([string]$Id) {
  $Id = Test-ModId $Id
  if (!$Id -or !$sizeMap.ContainsKey($Id)) { throw 'Unknown mod ID.' }
  $script:dirCacheAt = (Get-Date).AddMinutes(-10)
  $dir = (Get-DirMap)[$Id]
  if (!$dir -or (Test-AddonComplete $dir.path $dir.mtime) -or $Id -in (Get-ClientIds)) {
    throw 'This mod no longer has an incomplete download.'
  }
  $queued = Add-QueuedMods @([pscustomobject]@{ modId = $Id; name = $dir.name })
  Invoke-Verify | Out-Null
  if (!$queued.count) { return "'$($dir.name)' is already queued." }
  "Queued '$($dir.name)'$($queued.note)."
}
function Get-HaveIds {
  # on disk = COMPLETED in the DS profile, or present in the client addons folder,
  # by the one exact rule. Cached 3 s: this runs on every /servers and /browse
  # request and parses ~900 mod metadata files, which made /servers take ~1 s.
  if (((Get-Date) - $script:haveAt).TotalSeconds -lt 3) { return $script:haveCache }
  $have = @{}
  foreach ($e in (Get-DirMap).GetEnumerator()) {
    if (Test-AddonComplete $e.Value.path $e.Value.mtime) { $have[$e.Key] = $true }
  }
  # client copies: same exact check (the launcher reads that folder)
  $croot = [IO.DirectoryInfo]::new((Get-ClientAddons $DsProfile))
  if ($croot.Exists) {
    foreach ($d in $croot.EnumerateDirectories()) {
      $m = [regex]::Match($d.Name, '_([0-9A-F]{16})$')   # not $Matches: it does not survive a function call
      if (-not $m.Success) { continue }
      if (Test-AddonComplete $d.FullName $d.LastWriteTime) { $have[$m.Groups[1].Value] = $true }
    }
  }
  $script:haveCache = $have; $script:haveAt = Get-Date
  $have
}
function Invoke-QueueServer([string]$Id) {
  $srv = @($serverList | Where-Object { $_.id -eq $Id })[0]
  if (-not $srv) { throw 'unknown server id' }
  $name = if ($srv.PSObject.Properties['key'] -and $srv.key) { [string]$srv.key } else { ([string]$srv.name -split '\|')[0].Trim() }
  $have = Get-HaveIds
  $first = @($srv.mods | Where-Object { -not $have.ContainsKey($_.id) } |
    ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  if (-not $first) { return "nothing to do - all $($srv.mods.Count) mods of '$name' are already installed" }
  $firstIds = @($first.modId)
  $ctl = Lock-Engine
  if (!$ctl) { throw 'The downloader is busy. Try reordering the queue again.' }
  try {
    $engine = Get-DS -Fresh
    if ($null -eq $engine) { throw 'Cannot check whether the downloader is running. Try again.' }
    Stop-DS | Out-Null
    $restCount = Update-Cfg {
      param($cfg)
      $existing = @{}
      foreach ($mod in $cfg.game.mods) { $existing[$mod.modId] = $mod }
      $priority = @($first | ForEach-Object {
        if ($existing.ContainsKey($_.modId)) { $existing[$_.modId] } else { $_ }
      })
      $rest = @($cfg.game.mods | Where-Object { $_.modId -notin $firstIds })
      $cfg.game.mods = @($priority + $rest)
      $rest.Count
    } $Cfg
    $note = if (@($engine).Count) { " ($(Start-DS))" } else { ' - press Start / Resume' }
    "Queued $($first.Count) missing mods from '$name' ahead of $restCount others$note."
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-StartQueue {
  $script:dirCacheAt = (Get-Date).AddMinutes(-10)
  $script:haveAt = (Get-Date).AddMinutes(-10)
  Start-DS
}
function Invoke-PauseQueue {
  $ctl = Lock-Engine
  if (!$ctl) { throw 'The downloader is busy. Try pausing again.' }
  try {
    $message = Stop-DS
    Reset-QueueRevision
    $message
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-MakePreset([string]$Id) {
  $out = & "$PSScriptRoot\make-preset.ps1" -ServerId $Id -Summary
  Clear-PresetChangedMarker $Id
  ($out | Out-String).Trim()
}
function Start-PresetJob([string]$Id) {
  if ($script:presetJob) {
    if ($script:presetJob.job.State -in 'Running','NotStarted') { throw 'A preset is already being saved.' }
    $null = Complete-PresetJob $script:presetJob.id
  }
  $server = $serverList | Where-Object id -eq $Id | Select-Object -First 1
  if (!$server) { throw 'Server not found.' }
  $jobId = 'preset-' + [guid]::NewGuid().ToString('N')
  $job = Start-Job -ArgumentList (Join-Path $PSScriptRoot 'make-preset.ps1'),$Id,$Data -ScriptBlock {
    param($path,$id,$dataDir)
    $env:RFMM_DATA = $dataDir
    & $path -ServerId $id -Summary
  }
  $script:presetJob = @{ id = $jobId; job = $job; serverId = $Id; modIds = ($server.mods.id -join ',') }
  @{ job = $jobId; msg = 'Saving preset…' }
}
function Complete-PresetJob([string]$Id) {
  $entry = $script:presetJob
  if (!$entry -or $entry.id -ne $Id) { return @{ state = 'failed'; error = 'Preset job not found.' } }
  if ($entry.job.State -in 'Running','NotStarted') { return @{ state = 'running' } }
  try {
    if ($entry.job.State -ne 'Completed') {
      $reason = $entry.job.ChildJobs[0].JobStateInfo.Reason
      return @{ state = 'failed'; error = if ($reason) { $reason.Message } else { 'Could not save the preset.' } }
    }
    $message = (Receive-Job $entry.job -ErrorAction Stop | Out-String).Trim()
    $server = $serverList | Where-Object id -eq $entry.serverId | Select-Object -First 1
    if ($server -and ($server.mods.id -join ',') -eq $entry.modIds) { Clear-PresetChangedMarker $entry.serverId }
    @{ state = 'done'; msg = $message }
  } catch { @{ state = 'failed'; error = $_.Exception.Message } }
  finally { Remove-Job $entry.job -Force; $script:presetJob = $null }
}
function Clear-PresetChangedMarker([string]$Id) {
  # the preset now matches the fresh list: the "modlist changed" marker is done
  $sv = @($serverList | Where-Object { $_.id -eq $Id })[0]
  if ($sv -and $sv.PSObject.Properties['changed'] -and $sv.changed) {
    $sv | Add-Member -NotePropertyName changed -NotePropertyValue $null -Force
    try { Save-Json @{ servers = $serverList } $ServersPath 6 } catch { }
  }
}
function Search-Mods([string]$q, [int]$page) {
  # live Workshop search: the same keys the workshop site uses - name, author, or
  # the 16-character mod id. The search endpoint matches name and author; an id is
  # looked up directly. Cached 15 s per query like Get-Browse.
  if ($q -match '^[0-9A-Fa-f]{16}$') {
    $key = "id:$($q.ToUpper())"
    if ($script:bCache[$key] -and ((Get-Date) - $script:bCacheAt[$key]).TotalSeconds -lt 60) { return $script:bCache[$key] }
    $m = (Invoke-WorkshopApi -Uri "$ApiBase/mods/$($q.ToUpper())" -Headers $ApiH -TimeoutSec 10).mod
    $r = @{ total = 1; page = 1; pages = 1; mods = @($m) }
    $script:bCache[$key] = $r; $script:bCacheAt[$key] = Get-Date
    return $r
  }
  if (-not $q) { return @{ total = 0; page = 1; pages = 0; mods = @() } }
  if ($page -lt 1) { $page = 1 }
  $key = "s:$($q.ToLower()):$page"
  if ($script:bCache[$key] -and ((Get-Date) - $script:bCacheAt[$key]).TotalSeconds -lt 15) { return $script:bCache[$key] }
  $r = Invoke-WorkshopApi -Uri "$ApiBase/mods?search=$([uri]::EscapeDataString($q))&limit=24&page=$page" -Headers $ApiH -TimeoutSec 10
  $res = @{ total = [int]$r.meta.totalMods; page = $page
            pages = $(if ($r.meta.totalPages) { [int]$r.meta.totalPages } else { 1 })
            mods = @($r.data) }
  $script:bCache[$key] = $res; $script:bCacheAt[$key] = Get-Date
  $res
}
function Get-ModDeps([string]$Id) {
  # dependencies of one mod (ids, names, sizes). The DS pulls them by itself, but
  # then the queue and the total size would hide them.
  try { @((Invoke-WorkshopApi -Uri "$ApiBase/mods/$Id/dependencies" -Headers $ApiH -TimeoutSec 10).data.dependencies) }
  catch { @() }
}
function Add-QueuedMods($Mods) {
  $ctl = Lock-Engine
  if (!$ctl) { throw 'The downloader is busy. Try adding the mods again.' }
  try {
    $engine = Get-DS -Fresh
    if ($null -eq $engine) { throw 'Cannot check whether the downloader is running. Try again.' }
    $wasRunning = @($engine).Count -gt 0
    # The watchdog and the dedicated server both use the same config.
    # Keep an idle queue paused until the user presses Start.
    if ($wasRunning) { Stop-DS | Out-Null }
    else { New-Item -ItemType File -Force (Join-Path $Data 'paused.flag') | Out-Null }
    $count = Update-Cfg {
      param($cfg)
      $queued = @{}
      foreach ($mod in $cfg.game.mods) { $queued[$mod.modId] = $true }
      $new = @(foreach ($mod in $Mods) {
        if (!$queued.ContainsKey($mod.modId)) {
          $queued[$mod.modId] = $true
          $mod
        }
      })
      $cfg.game.mods = @($cfg.game.mods) + $new
      $new.Count
    } $Cfg
    $note = if ($wasRunning) { " ($(Start-DS))" } else { ' - press Start / Resume' }
    @{ count = $count; note = $note }
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-AddMod([string]$Id) {
  # add ONE workshop mod (plus its dependencies) to the download queue, at the end
  if ($Id -notmatch '^[0-9A-Fa-f]{16}$') { throw 'not a mod id' }
  $Id = $Id.ToUpper()
  # a mod deleted in Explorer still looked installed for 3 s (cached scan), so Add
  # answered "already installed" and nothing happened
  $script:haveAt = (Get-Date).AddMinutes(-10)
  $script:dirCacheAt = (Get-Date).AddMinutes(-10)
  $have = Get-HaveIds
  $j = Get-Cfg
  $queued = @{}
  foreach ($m in $j.game.mods) { $queued[$m.modId] = $true }
  if ($queued.ContainsKey($Id) -or $have.ContainsKey($Id)) { return "already $(if ($have.ContainsKey($Id)) { 'installed' } else { 'queued' }) - nothing to add" }
  $m = (Invoke-WorkshopApi -Uri "$ApiBase/mods/$Id" -Headers $ApiH -TimeoutSec 10).mod
  $add = @([PSCustomObject]@{ modId = $Id; name = [string]$m.name; size = [double]$m.size })
  $depNames = @()
  $seen = @{}; $seen[$Id] = $true
  $queue2 = @(@{ id = $Id; depth = 0 })
  # a malicious or broken dependency graph must not keep the request thread busy:
  # 20 s and 200 mods, then queue what was found and say so
  $budget = (Get-Date).AddSeconds(20)
  $cap = 200
  $cut = $false
  while ($queue2.Count) {
    if ((Get-Date) -gt $budget -or $add.Count -ge $cap) { $cut = $true; break }
    $cur = $queue2[0]; $queue2 = @($queue2 | Select-Object -Skip 1)
    if ($cur.depth -ge 3) { continue }
    foreach ($d in (Get-ModDeps $cur.id)) {
      if ($add.Count -ge $cap) { $cut = $true; break }
      if ($d.id -notmatch '^[0-9A-Fa-f]{16}$') { continue }
      $did = $d.id.ToUpper()
      if ($seen[$did] -or $queued.ContainsKey($did) -or $have.ContainsKey($did)) { continue }
      $seen[$did] = $true
      $add += [PSCustomObject]@{ modId = $did; name = [string]$d.name; size = [double]$d.size }
      $depNames += [string]$d.name
      $queue2 += @{ id = $did; depth = $cur.depth + 1 }
    }
    if ($cut) { break }
  }
  $queueChange = Add-QueuedMods @($add | ForEach-Object { [PSCustomObject]@{ modId = $_.modId; name = $_.name } })
  # merge the sizes (merge-only: a replace would destroy the rest of the map)
  $sz = Read-Json $Sizes ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json)
  foreach ($a in $add) {
    if ($script:sizeMap.ContainsKey($a.modId)) { continue }
    $script:sizeMap[$a.modId] = @{ name = $a.name; bytes = [double]$a.size; exact = [bool]($a.size -gt 0) }
    $sz.mods | Add-Member -MemberType NoteProperty -Name $a.modId `
      -Value ([PSCustomObject]@{ name = $a.name; bytes = [double]$a.size; exact = [bool]($a.size -gt 0) }) -Force
  }
  $script:TotalBytes = ($script:sizeMap.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
  $sz.totalBytes = [double]$script:TotalBytes
  Save-Json $sz $Sizes 4
  $msg = "Queued '$($m.name)'"
  if ($depNames.Count) { $msg += " and $($depNames.Count) dependencies" }
  if ($cut) { $msg += '. Dependency search reached its limit' }
  $msg + $queueChange.note
}
function Get-Browse([string]$q) {
  # live server list from the public reforgermods API, cached 15 s per query
  $key = $q.ToLower()
  if ($script:bCache[$key] -and ((Get-Date) - $script:bCacheAt[$key]).TotalSeconds -lt 15) { return $script:bCache[$key] }
  $u = "$ApiBase/servers?includeOffline=true"
  if ($q) { $u += "&search=$([uri]::EscapeDataString($q))" }
  $r = Invoke-WorkshopApi -Uri $u -Headers $ApiH -TimeoutSec 10
  $list = @($r.data | Sort-Object online, players -Descending |
    Select-Object -First 60 | ForEach-Object {
      [PSCustomObject]@{ id = $_.id; name = $_.name; players = $_.players; maxPlayers = $_.maxPlayers
                         region = $_.region; online = [bool]$_.online; modCount = $_.modCount
                         scenarioName = $_.scenarioName } })
  $script:bCache[$key] = $list; $script:bCacheAt[$key] = Get-Date
  $list
}
function Get-Detail([string]$Id) {
  # one server with its full modlist (the API sends exact Workshop sizes), cached 30 s
  # the id is pasted into an API url: only a server guid may get there, so a request
  # from the page cannot steer it at another endpoint
  if ($Id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'bad server id' }
  if ($script:dCache[$Id] -and ((Get-Date) - $script:dCacheAt[$Id]).TotalSeconds -lt 30) { return $script:dCache[$Id] }
  $d = Invoke-WorkshopApi -Uri "$ApiBase/servers/$Id" -Headers $ApiH -TimeoutSec 10
  if (-not $d.server -or -not @($d.server.mods).Count) { throw 'server has no modlist (offline or password protected)' }
  $script:dCache[$Id] = $d.server; $script:dCacheAt[$Id] = Get-Date
  $d.server
}
function Invoke-AddServer([string]$Id) {
  # add a server from the live browser: queue its missing mods at the END of the
  # batch (adding must not jump the queue), with real sizes from the API
  $s = Get-Detail $Id
  if ($s.passwordProtected) { return 'server is password protected - its modlist is not public' }
  $name = ([string]$s.name -split '\|')[0].Trim()
  if ($name.Length -gt 60) { $name = $name.Substring(0, 60).Trim() }
  $have = Get-HaveIds
  foreach ($m in (Get-Cfg).game.mods) { $have[$m.modId] = $true }
  $want = @($s.mods | ForEach-Object {
    $mid = Test-ModId $_.id
    if (-not $mid) { Write-Host "ignoring a mod with an invalid id from the API: $($_.id)" -ForegroundColor Yellow; return }
    [PSCustomObject]@{ id = $mid; name = $_.name; size = [double]$_.size; sizeKnown = [bool]$_.sizeKnown }
  })
  $new = @($want | Where-Object { -not $have.ContainsKey($_.id) })

  # list the server first: re-adding a removed server must work even when every
  # mod is already on disk, and an existing entry is replaced with the fresh list
  $script:serverList = @($serverList | Where-Object { $_.id -ne $Id }) + @([PSCustomObject]@{
    id = $Id; name = $s.name; mods = @($want | ForEach-Object {
      [PSCustomObject]@{ id = $_.id; name = $_.name; e = [double]$_.size } }) })
  Save-Json @{ servers = $serverList } $ServersPath 6
  if (-not $new) { return "'$name' is in the list - all $(@($want).Count) mods are on disk or queued, nothing to download" }

  $queueChange = Add-QueuedMods @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  # merge the real sizes into the sizes file (merge-only: never replace it)
  $sz = Read-Json $Sizes ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json)
  foreach ($m in $new) {
    if (-not $sizeMap.ContainsKey($m.id)) {
      $sizeMap[$m.id] = @{ name = $m.name; bytes = [double]$m.size; exact = [bool]$m.sizeKnown }
      $sz.mods | Add-Member -MemberType NoteProperty -Name $m.id -Value ([PSCustomObject]@{ name = $m.name; bytes = [double]$m.size; exact = [bool]$m.sizeKnown }) -Force
    }
  }
  $script:TotalBytes = ($sizeMap.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
  $sz.totalBytes = [double]$script:TotalBytes
  Save-Json $sz $Sizes 4

  # show the new server in the Servers card immediately, and remember it.
  # (one assignment only: the list is replaced above, so a second append here put
  # the same server in memory and in batch1-servers.json twice)
  $gb = [Math]::Round(($new | ForEach-Object { [double]$_.size } | Measure-Object -Sum).Sum / 1GB, 2)
  "Queued $($new.Count) mods for '$name' (~$gb GB)$($queueChange.note)."
}
function Merge-ServerMods($sv, $mods, $sz) {
  # apply a modlist that a background job fetched: sizes, then the "changed"
  # marker the page shows. No network here, and it runs on the single request
  # thread, so two refreshes cannot interleave. Ids are validated here as well:
  # a payload is data from the internet, not something to trust.
  $mods = @(foreach ($m in $mods) {
    $mid = Test-ModId $m.id
    if (-not $mid) { Write-Host "refresh: ignoring a mod with an invalid id: $($m.id)" -ForegroundColor Yellow; continue }
    [PSCustomObject]@{ id = $mid; name = $m.name; size = [double]$m.size; sizeKnown = [bool]$m.sizeKnown }
  })
  foreach ($m in $mods) {
    if (-not $sizeMap.ContainsKey($m.id) -and $m.sizeKnown -and $m.size) {
      $sizeMap[$m.id] = @{ name = $m.name; bytes = [double]$m.size; exact = $true }
      $sz.mods | Add-Member -MemberType NoteProperty -Name $m.id -Value ([PSCustomObject]@{ name = $m.name; bytes = [double]$m.size; exact = $true }) -Force
    }
  }
  $oldIds = @($sv.mods | ForEach-Object { $_.id })
  $sv.mods = @($mods | ForEach-Object {
    $sm = $sizeMap[$_.id]
    [PSCustomObject]@{ id = $_.id; name = $_.name; e = $(if ($sm) { [double]$sm.bytes } else { [double]0 }) }
  })
  $newIds = @($sv.mods | ForEach-Object { $_.id })
  $addN = @($newIds | Where-Object { $oldIds -notcontains $_ }).Count
  $remN = @($oldIds | Where-Object { $newIds -notcontains $_ }).Count
  if ($oldIds.Count -and ($addN + $remN)) {
    $sv | Add-Member -NotePropertyName changed -NotePropertyValue ([PSCustomObject]@{ added = $addN; removed = $remN; at = (Get-Date -f 'yyyy-MM-dd HH:mm') }) -Force
  } elseif ($oldIds.Count) {
    $sv | Add-Member -NotePropertyName changed -NotePropertyValue $null -Force
  }
}
function Start-RefreshJob([string[]]$Ids) {
  # Network work (modlists + sizes) runs in a separate PowerShell process and the
  # result is applied later on the request thread. One job at a time, so there is
  # never more than one background process.
  $ids = @($Ids | Where-Object { $_ })
  if (-not $ids.Count) { return @{ job = $null; msg = 'no servers to refresh' } }
  if ($script:refreshJob) {
    $state = [string]$script:refreshJob.job.State
    if ($state -eq 'Running' -or $state -eq 'NotStarted') {
      return @{ job = $script:refreshJob.id; msg = "Servers are already refreshing." }
    }
    # finished but never collected: discard it and start clean
    Remove-Job $script:refreshJob.job -Force -ErrorAction SilentlyContinue
    Remove-Item $script:refreshJob.out -Force -ErrorAction SilentlyContinue
    $script:refreshJob = $null
  }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $out = Join-Path $Data "job-$id.json"
  $known = @($sizeMap.Keys)
  $job = Start-Job -ArgumentList $id, $ids, $out, $ApiBase, $known, $UserAgent, (Join-Path $PSScriptRoot 'workshop-api.ps1') -ScriptBlock {
    param($jobId, $serverIds, $out, $base, $known, $ua, $stateScript)
    . $stateScript
    $h = @{ 'User-Agent' = $ua }
    $servers = @()
    $need = @{}
    foreach ($sid in $serverIds) {
      try {
        $d = Invoke-WorkshopApi -Uri "$base/servers/$sid" -Headers $h -TimeoutSec 30
        if (-not $d.server -or -not @($d.server.mods).Count) { throw 'no modlist (offline or password protected)' }
        $mods = @()
        foreach ($m in @($d.server.mods)) {
          $mods += [PSCustomObject]@{ id = $m.id; name = $m.name; size = [double]$m.size; sizeKnown = [bool]$m.sizeKnown }
          if ($known -notcontains $m.id -and -not ($m.sizeKnown -and $m.size)) { $need[$m.id] = $true }
        }
        $servers += [PSCustomObject]@{ id = $sid; name = $d.server.name; mods = $mods }
      } catch {
        $servers += [PSCustomObject]@{ id = $sid; name = ''; error = $_.Exception.Message; mods = @() }
      }
    }
    $sizes = @{}
    if ($need.Count) {
      try {
        $body = @{ mode = 'replace'; desired = @($need.Keys | ForEach-Object { @{ id = $_ } }) } | ConvertTo-Json -Depth 5
        $plan = Invoke-WorkshopApi -Uri "$base/tools/storage-plan" -Method Post -Body $body -Headers $h -ContentType 'application/json' -TimeoutSec 120
        foreach ($x in $plan.data.downloads) { $sizes[$x.id] = @{ bytes = [double]$x.bytes; exact = [bool]$x.exact } }
      } catch { }
    }
    @{ servers = $servers; sizes = $sizes } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding UTF8
  }
  $script:refreshJob = @{ id = $id; out = $out; job = $job; queueRevision = (Get-QueueRevision) }
  @{ job = $id; msg = "Refreshing $($ids.Count) servers." }
}
function Complete-RefreshJob([string]$Id) {
  # Called by /job. Returns { state = running|done|failed }; applies the result
  # exactly once, on the request thread, then cleans the job up.
  $rj = $script:refreshJob
  if (-not $rj) { return @{ state = 'failed'; error = 'no refresh job is running' } }
  if ($Id -and $Id -ne $rj.id) { return @{ state = 'failed'; error = "unknown job $Id" } }
  $state = [string]$rj.job.State
  if ($state -eq 'Running' -or $state -eq 'NotStarted') { return @{ state = 'running'; id = $rj.id } }

  $err = ''
  if ($state -eq 'Failed') { $err = [string]$rj.job.ChildJobs[0].JobStateInfo.Reason.Message }
  $payload = $null
  if (-not $err) {
    if (Test-Path $rj.out) {
      try { $payload = Get-Content $rj.out -Raw | ConvertFrom-Json }
      catch { $err = "unreadable refresh result: $($_.Exception.Message)" }
    } else { $err = 'the refresh produced no result' }
  }

  $result = $null
  try {
    if ($err) {
      $result = @{ state = 'failed'; error = $err }
    } else {
      $script:bCache = @{}; $script:bCacheAt = @{}
      $script:dCache = @{}; $script:dCacheAt = @{}
      $script:dirCacheAt = (Get-Date).AddMinutes(-10)
      $script:clCacheAt = (Get-Date).AddMinutes(-10)
      $sz = Read-Json $Sizes ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json)
      foreach ($p in $sz.mods.PSObject.Properties) { $sizeMap[$p.Name] = $p.Value }
      foreach ($p in @($payload.sizes.PSObject.Properties)) {
        $sid = Test-ModId $p.Name
        if (-not $sid) { Write-Host "refresh: ignoring a size entry with an invalid id: $($p.Name)" -ForegroundColor Yellow; continue }
        $sizeMap[$sid] = @{ name = ''; bytes = [double]$p.Value.bytes; exact = [bool]$p.Value.exact }
        $sz.mods | Add-Member -MemberType NoteProperty -Name $sid -Value ([PSCustomObject]@{ name = ''; bytes = [double]$p.Value.bytes; exact = [bool]$p.Value.exact }) -Force
      }
      $ok = 0; $fail = 0; $changed = @()
      $want = [ordered]@{}
      foreach ($sp in @($payload.servers)) {
        $sv = @($serverList | Where-Object { $_.id -eq $sp.id })[0]
        if (-not $sv) { continue }            # removed while the job was running
        if ($sp.PSObject.Properties['error'] -and $sp.error) { $fail++; continue }
        if ($sp.name) { $sv.name = $sp.name }
        $previous = @($sv.mods.id)
        Merge-ServerMods $sv @($sp.mods) $sz
        foreach ($mod in $sv.mods) {
          if ($mod.id -notin $previous) { $want[$mod.id] = $mod.name }
        }
        $c = $sv.PSObject.Properties['changed']
        if ($c -and $c.Value) { $changed += $sv.id }
        $ok++
      }
      $script:TotalBytes = ($sizeMap.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
      $sz.totalBytes = [double]$script:TotalBytes
      Save-Json $sz $Sizes 4
      Save-Json @{ servers = $serverList } $ServersPath 6
      $q = if ($rj.queueRevision -eq (Get-QueueRevision)) { Add-MissingToQueue $want }
        else { @{ count = 0; note = ' - queue changed during refresh' } }
      $summary = "Refreshed $ok of $(@($payload.servers).Count) servers."
      if ($q.count) { $summary += " Queued $($q.count) mods$($q.note)." }
      if ($changed.Count) { $summary += " $($changed.Count) mod lists changed." }
      $result = @{ state = 'done'; msg = $summary }
    }
  } catch {
    $result = @{ state = 'failed'; error = $_.Exception.Message }
  } finally {
    Remove-Job $rj.job -Force -ErrorAction SilentlyContinue
    Remove-Item $rj.out -Force -ErrorAction SilentlyContinue
    $script:refreshJob = $null
  }
  $result
}
function Add-MissingToQueue($want) {
  # $want: ordered id -> name. Append only: installed and already-queued mods are
  # never downloaded twice. Returns @{ count; note }.
  $have = Get-HaveIds
  $j = Get-Cfg
  $queued = @{}
  foreach ($m in $j.game.mods) { $queued[$m.modId] = $true }
  $new = @($want.Keys | Where-Object { -not $have.ContainsKey($_) -and -not $queued.ContainsKey($_) })
  if (!$new.Count) { return @{ count = 0; note = '' } }
  Add-QueuedMods @($new | ForEach-Object { [PSCustomObject]@{ modId = $_; name = [string]$want[$_] } })
}
function Invoke-RemoveServer([string]$Id) {
  # drop the server from the list only: its mods stay on disk and in the queue
  $sv = @($serverList | Where-Object { $_.id -eq $Id })[0]
  if (-not $sv) { throw 'server is not in the list' }
  $script:serverList = @($serverList | Where-Object { $_.id -ne $Id })
  Save-Json @{ servers = $serverList } $ServersPath 6
  "Removed '$($sv.name)' from tracked servers."
}
function Invoke-RemoveQueuedMod([string]$Id) {
  $Id = Test-ModId $Id
  if (!$Id) { throw 'Invalid mod ID.' }
  $ctl = Lock-Engine
  if (!$ctl) { throw 'another start/stop is in progress - the queue was not changed' }
  try {
    $mod = (Get-Cfg).game.mods | Where-Object modId -eq $Id | Select-Object -First 1
    if (!$mod) { return 'mod is no longer queued' }
    $engine = Get-DS -Fresh
    if ($null -eq $engine) { throw 'cannot read the process list right now - the queue was not changed' }
    $restart = @($engine).Count -gt 0
    if ($restart) { Stop-DS | Out-Null }
    Update-Cfg {
      param($cfg)
      $cfg.game.mods = @($cfg.game.mods | Where-Object modId -ne $Id)
    } $Cfg | Out-Null
    Reset-QueueRevision
    $message = "removed '$($mod.name)' from the queue"
    if ($restart -and @((Get-Cfg).game.mods).Count) { $message += " ($(Start-DS))" }
    $message
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-ClearQueue {
  $ctl = Lock-Engine
  if (!$ctl) { throw 'another start/stop is in progress - the queue was not changed' }
  try {
    Stop-DS | Out-Null
    $n = Update-Cfg {
      param($cfg)
      @($cfg.game.mods).Count
      $cfg.game.mods = @()
    } $Cfg
    Reset-QueueRevision
    "queue cleared ($n mods removed)"
  } finally { $ctl.ReleaseMutex() }
}
function Test-PartialDeleteTree([IO.DirectoryInfo]$Directory) {
  if ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
  foreach ($child in $Directory.EnumerateFileSystemInfos()) {
    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    if ($child -is [IO.DirectoryInfo] -and !(Test-PartialDeleteTree $child)) { return $false }
  }
  $true
}

function Invoke-CancelDownloads {
  $ctl = Lock-Engine
  if (!$ctl) { throw 'The downloader is busy. Try cancelling again.' }
  try {
    $tracked = @{}
    $preservePackages = @{}
    foreach ($id in $sizeMap.Keys) { $tracked[$id] = $true }
    foreach ($mod in (Get-Cfg).game.mods) {
      $id = Test-ModId $mod.modId
      if (!$id) { continue }
      $tracked[$id] = $true
      if ($mod.version) { $preservePackages[$id] = $true }
    }
    $updates = Read-Json (Join-Path $Data 'mod-update-batch.json') $null
    foreach ($update in $updates.updates) {
      $id = Test-ModId $update.modId
      if ($id) { $tracked[$id] = $true; $preservePackages[$id] = $true }
    }

    # The game and the downloader may share the same addons directory.
    $game = Get-Process -Name 'ArmaReforger*' -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessName -notlike 'ArmaReforgerSer*' }
    if ($game) { throw 'Close Arma Reforger before deleting partial downloads.' }
    Stop-DS | Out-Null
    if (Get-EngineProcesses) { throw 'Close the other dedicated server before deleting partial downloads.' }

    Update-Cfg { param($cfg) $cfg.game.mods = @() } $Cfg | Out-Null
    Reset-QueueRevision
    $root = Get-Item -LiteralPath $Addons -Force -ErrorAction SilentlyContinue
    if (!$root) { return 'Downloads cancelled.' }
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      $client = Get-ClientAddons $DsProfile
      $target = $root.Target | Select-Object -First 1
      if (!$target -or ![IO.Path]::IsPathRooted($target) -or
          [IO.Path]::GetFullPath($target) -ne [IO.Path]::GetFullPath($client)) {
        return 'Downloads cancelled. Partial files stayed on disk because the addons folder is linked elsewhere.'
      }
      $root = Get-Item -LiteralPath $target -Force -ErrorAction Stop
      if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return 'Downloads cancelled. Partial files stayed on disk because the addons folder is linked elsewhere.'
      }
    }
    $removed = 0
    $failed = 0
    $script:exactCache = @{}
    foreach ($folder in Get-ChildItem -LiteralPath $root.FullName -Directory -Force) {
      if ($folder.Name -notmatch '_([a-fA-F0-9]{16})$') { continue }
      $id = $Matches[1]
      if (!$tracked.ContainsKey($id) -or $folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      $keepPackage = $preservePackages.ContainsKey($id) -or (Test-AddonComplete $folder.FullName $folder.LastWriteTime)
      $metadata = Join-Path $folder.FullName 'meta'
      if (!$keepPackage -and (Test-Path -LiteralPath $metadata)) {
        try {
          $previous = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
          $keepPackage = !$previous.meta -or @($previous.meta.versions).Count -gt 1
        } catch { $keepPackage = $true }
      }
      $candidate = if ($keepPackage) { Get-Item -LiteralPath (Join-Path $folder.FullName 'temp') -Force -ErrorAction SilentlyContinue } else { $folder }
      if ($candidate -isnot [IO.DirectoryInfo]) { continue }
      try {
        if (($candidate.Parent.FullName -ne $root.FullName -and $candidate.Parent.FullName -ne $folder.FullName) -or
            !(Test-PartialDeleteTree $candidate)) { throw 'The partial download contains a link.' }
        Remove-Item -LiteralPath $candidate.FullName -Recurse -Force -ErrorAction Stop
        $removed++
      } catch { $failed++ }
    }
    $script:dirCacheAt = (Get-Date).AddMinutes(-10)
    $script:haveAt = (Get-Date).AddMinutes(-10)
    $script:clCacheAt = (Get-Date).AddMinutes(-10)
    $script:clBytesAt = (Get-Date).AddMinutes(-10)
    $script:verify = $null
    $message = if ($removed) { "Downloads cancelled. Removed $removed partial downloads." } else { 'Downloads cancelled.' }
    if ($failed) { $message += " Couldn't remove $failed partial downloads." }
    $message
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-ResumeAll {
  $want = [ordered]@{}
  foreach ($sv in $serverList) { foreach ($m in $sv.mods) { $want[$m.id] = $m.name } }
  $result = Add-MissingToQueue $want
  "Queued $($result.count) more missing server mods$($result.note)."
}

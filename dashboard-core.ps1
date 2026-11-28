# Dashboard functions. Dot-sourced by download-web.ps1; no top-level side effects.
function Get-Cfg {
  if (!$ReadOnly) { return Read-EngineConfig $Cfg }
  $file = [IO.FileInfo]::new($Cfg)
  $now = [datetime]::UtcNow
  $stamp = if ($file.Exists) { "$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)|$($file.Length)" }
  if ($stamp -and $stamp -ceq $script:statusConfigStamp -and $now -lt $script:statusConfigUntil) {
    return $script:statusConfig
  }
  $config = Read-EngineConfig $Cfg
  $script:statusConfig = $config
  $script:statusConfigStamp = $stamp
  # An overwrite can preserve length and timestamp on filesystems with coarse timestamps.
  $script:statusConfigUntil = $now.AddSeconds(2)
  $config
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
function Get-InstalledModsForUpdate([string[]]$Ids, [switch]$All) {
  $installed = @{}
  $wanted = @{}
  foreach ($id in $Ids) { $wanted[$id] = $true }
  foreach ($dir in (Get-AddonDirectories (Get-ClientAddons $DsProfile))) {
    if ($dir.Name -notmatch '_([a-f0-9]{16})$') { continue }
    $id = $Matches[1].ToUpperInvariant()
    if (($All -or $wanted.ContainsKey($id)) -and !$installed.ContainsKey($id) -and
        (Test-AddonComplete $dir.FullName $dir.LastWriteTime)) { $installed[$id] = $dir.FullName }
  }
  $installed
}
function Add-ModUpdateBatch([hashtable]$Updates, [string]$QueueRevision) {
  if (!$Updates.Count) { return 'No newer versions to queue.' }
  $lock = Lock-Engine
  if (!$lock) { throw 'Engine busy. Try again.' }
  try {
    if ($PSBoundParameters.ContainsKey('QueueRevision') -and $QueueRevision -ne [string](Get-QueueRevision)) {
      return 'The queue changed during the check. No updates were queued.'
    }
    $queue = @((Get-Cfg).game.mods)
    $queuedIds = @{}
    foreach ($mod in $queue) { if ($mod.modId) { $queuedIds[$mod.modId] = $mod.version } }
    $newUpdates = @($Updates.Values | Where-Object { !$queuedIds.ContainsKey($_.modId) })
    if (!$newUpdates.Count) { return 'Those mods are already in the queue.' }
    $engine = Get-DS -Fresh
    if ($null -eq $engine) { throw 'Cannot inspect the download engine.' }
    if (@($engine).Count) { Stop-DS | Out-Null }
    $batchPath = Join-Path $Data 'mod-update-batch.json'
    $batch = Read-Json $batchPath $null
    $previous = @($batch.updates | Where-Object { $_.version -and $queuedIds[$_.modId] -eq $_.version })
    Save-Json @{ updates = @($previous + $newUpdates) } $batchPath
    Update-Cfg {
      param($cfg)
      $cfg.game.mods = @($cfg.game.mods) + $newUpdates
    } $Cfg | Out-Null
    $startText = try { Start-DS } catch { "Could not start: $($_.Exception.Message)" }
    "Queued $($newUpdates.Count) updates. $startText"
  } finally { $lock.ReleaseMutex() }
}
function Get-AvailableModUpdates([string]$Id) {
  if ($Id -and !(Test-ModId $Id)) { throw 'Invalid mod ID.' }
  $snapshot = Read-Json (Join-Path $Data 'mod-update-available.json') $null
  $selected = @($snapshot.updates | Where-Object { (Test-ModId $_.modId) -and (!$Id -or $_.modId -eq $Id) })
  if (!$selected.Count) { return @{} }
  $installed = Get-InstalledModsForUpdate $selected.modId
  $updates = @{}
  foreach ($update in $selected) {
    if (!$installed.ContainsKey($update.modId)) { continue }
    $local = Get-InstalledVersion $installed[$update.modId]
    try {
      if ($local -and (Compare-WorkshopVersion $update.version $local) -gt 0) { $updates[$update.modId] = $update }
    } catch { continue }
  }
  $updates
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
  $p = Join-Path $Data 'skipped.json'
  $written = [IO.File]::GetLastWriteTimeUtc($p)
  if ($script:skippedAt -eq $written) { return $script:skipped }
  # Read-Json supplies defaults after moving malformed state aside.
  $script:skipped = @()
  if (Test-Path $p) {
    $data = Read-Json $p @()
    if ($null -ne $data) { $script:skipped = @($data) }
  }
  $script:skippedAt = $written
  $script:skipped
}
function Get-DS([switch]$Fresh) {
  # Use -Fresh before editing the engine config. An empty array means no match. $null means the ownership query failed.
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
  # Cache the newest console.log path for three seconds.
  if ($script:logCache -and ((Get-Date) - $script:logCacheAt).TotalSeconds -lt 3) { return $script:logCache }
  $script:logCache = Get-ChildItem -LiteralPath (Join-Path $DsProfile 'logs') -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $script:logCacheAt = Get-Date
  $script:logCache
}
function Get-AddonsBytes {
  # Report the measured size of the game addons folder.
  if (((Get-Date) - $script:clBytesAt).TotalSeconds -lt 15) { return $script:clBytes }
  $sum = [double]0
  $root = [IO.DirectoryInfo]::new((Get-ClientAddons $DsProfile))
  if ($root.Exists) {
    try { foreach ($f in $root.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $sum += $f.Length } } catch { }
  }
  $script:clBytes = $sum; $script:clBytesAt = Get-Date
  $sum
}
function Get-AddonDirectories([string]$Path, [string]$Pattern = '*') {
  $root = [IO.DirectoryInfo]::new($Path)
  if (!$root.Exists) { return }
  try { $root.EnumerateDirectories($Pattern) }
  catch [IO.DirectoryNotFoundException] { } # The game profile can be removed between polls.
}
function Get-ClientIds {
  # Count an addon only when every file matches its metadata. Test-AddonComplete caches the result.
  if (((Get-Date) - $script:clCacheAt).TotalSeconds -lt 10) { return $script:clCache }
  $ids = [Collections.Generic.List[string]]::new()
  foreach ($d in (Get-AddonDirectories (Get-ClientAddons $DsProfile))) {
    $m = [regex]::Match($d.Name, '_([0-9A-F]{16})$')
    if (-not $m.Success) { continue }
    if (Test-AddonComplete $d.FullName $d.LastWriteTime) { $ids.Add($m.Groups[1].Value) }
  }
  $script:clCache = $ids.ToArray(); $script:clCacheAt = Get-Date
  $script:clCache
}
function Get-DirMap {
  # Reuse older folder totals until the directory changes. Recheck active folders because the engine can append without changing the directory time.
  if (((Get-Date) - $script:dirCacheAt).TotalSeconds -lt 3) { return $script:dirCache }
  $map = @{}
  $root = [IO.DirectoryInfo]::new($Addons)
  if (-not $script:dirFolderCache) { $script:dirFolderCache = @{} }
  if ($root.Exists) {
    $now = Get-Date
    $cutoff = $now.AddMinutes(-2)
    $seen = @{}
    try {
      foreach ($d in $root.EnumerateDirectories()) {
        $m = [regex]::Match($d.Name, '_([0-9A-F]{16})$')
        if (-not $m.Success) { continue }
        $g = $m.Groups[1].Value
        $seen[$d.Name] = $true
        $dirTime = $d.LastWriteTimeUtc.Ticks
        $cached = $script:dirFolderCache[$d.Name]
        # A recently written folder may be appended to without its directory time
        # changing, so it is always re-read; older folders only when they changed.
        if ($cached -and $d.LastWriteTime -le $cutoff -and $cached.dirTime -eq $dirTime) {
          $map[$g] = @{ name = $cached.name; bytes = [double]$cached.bytes
                        assembled = [bool]$cached.assembled; mtime = $cached.mtime
                        path = $d.FullName }
          continue
        }
        $bytes = [double]0; $newest = [datetime]::MinValue; $assembled = 0
        try {
          foreach ($f in $d.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
            $bytes += $f.Length
            if ($f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime }
            if ($f.Name -in 'addon.gproj','meta','resourceDatabase.rdb') { $assembled++ }
          }
        } catch { }   # an unreadable folder must not take the dashboard down
        $name = $d.Name -replace '_[0-9A-F]{16}$', ''
        $map[$g] = @{ name = $name; bytes = $bytes; assembled = ($assembled -eq 3)
                      mtime = $newest; path = $d.FullName }
        $script:dirFolderCache[$d.Name] = @{ name = $name; bytes = $bytes; assembled = ($assembled -eq 3)
                                             mtime = $newest; dirTime = $dirTime }
      }
    } catch { }
    foreach ($name in @($script:dirFolderCache.Keys)) {
      if (-not $seen.ContainsKey($name)) { $script:dirFolderCache.Remove($name) }
    }
  }
  $script:dirCache = $map; $script:dirCacheAt = Get-Date
  $map
}
function Get-TransferSnapshot($Log, [datetime]$Now, [datetime]$StartedAt) {
  $result = @{ mods = @{}; current = $null; speedB = 0; speedAge = 999; registered = $false }
  if (!$Log) { return $result }
  $file = [IO.FileInfo]::new($Log.FullName)
  if (!$file.Exists -or $file.LastWriteTimeUtc -lt $StartedAt.ToUniversalTime()) { return $result }
  $run = "$($file.FullName)|$($StartedAt.Ticks)"
  if ($script:transferLogRun -ne $run -or $file.Length -lt $script:transferOffset -or
      ($file.Length -eq $script:transferOffset -and $file.LastWriteTimeUtc -ne $script:transferWritten)) {
    $script:transferLogRun = $run
    $script:transferOffset = [long]0
    $script:transferCheckpoint = $null
    $script:transferLogMetrics = @{ mods = @{}; candidates = @{}; current = $null; speedAt = $null; speedB = 0 }
  }
  $cached = $script:transferLogMetrics
  if ($file.Length -gt $script:transferOffset) {
    $stream = $null
    try {
      $stream = [IO.File]::Open($file.FullName, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
      $reader = [IO.BinaryReader]::new($stream)
      if ($script:transferCheckpoint) {
        $count = $script:transferCheckpointSize
        $stream.Position = $script:transferOffset - $count
        if ([Convert]::ToBase64String($reader.ReadBytes($count)) -cne $script:transferCheckpoint) {
          $script:transferOffset = [long]0
          $cached = $script:transferLogMetrics = @{ mods = @{}; candidates = @{}; current = $null; speedAt = $null; speedB = 0 }
        }
      }
      # Keep partial UTF-8 lines for the next poll, including split multibyte names.
      while ($script:transferOffset -lt $file.Length) {
        $stream.Position = $script:transferOffset
        $bytes = $reader.ReadBytes([int][Math]::Min([long]262144, $file.Length - $stream.Position))
        $end = [Array]::LastIndexOf($bytes, [byte]10)
        if ($end -lt 0) {
          if ($bytes.Length -lt 262144) { break }
          # A single engine diagnostic can exceed a whole buffer. Skip to its newline.
          while ($stream.Position -lt $file.Length) {
            if ($stream.ReadByte() -eq 10) { $script:transferOffset = $stream.Position; break }
          }
          if ($stream.Position -ge $file.Length) { break }
          continue
        }
        foreach ($line in ([Text.Encoding]::UTF8.GetString($bytes, 0, $end + 1) -split '\r?\n')) {
          if (!$line.Contains('BACKEND')) { continue }
          $entry = [regex]::Match($line, '^\s*(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+BACKEND(?:\s*\([A-Z]+\))?\s*:\s*(.+)$')
          if (!$entry.Success) { continue }
          $elapsed = [timespan]::Zero
          if (![timespan]::TryParse($entry.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [ref]$elapsed)) { continue }
          $at = $Now.Date.Add($elapsed)
          if ($at -gt $Now.AddSeconds(2)) { $at = $at.AddDays(-1) }
          if ($at -lt $StartedAt) { continue }
          $body = $entry.Groups[2].Value
          if ($body.StartsWith('Server registered')) {
            if ($cached.current) { $cached.current.until = $at.AddSeconds(15) }
            $cached.current = $null
            $cached.mods.Clear()
            $cached.speedAt = $null
            $cached.registered = $true
            continue
          }
          if ($body.StartsWith('Failed to fetch addon details') -and $cached.current) {
            $cached.mods.Remove($cached.current.name)
            $cached.candidates.Remove($cached.current.id)
            $cached.current = $null
            $cached.speedAt = $null
            continue
          }
          $start = [regex]::Match($body, '^Addon Download started ([a-fA-F0-9]{16}) - (.+)$')
          if ($start.Success -and (!$cached.current -or $at -ge $cached.current.at)) {
            if ($cached.current) { $cached.current.until = $at.AddSeconds(15) }
            $cached.speedAt = $null
            $cached.mods.Remove($start.Groups[2].Value.Trim())
            $cached.current = @{ id = $start.Groups[1].Value.ToUpperInvariant(); name = $start.Groups[2].Value.Trim(); at = $at; until = $null }
            $cached.candidates[$cached.current.id] = $cached.current
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
        $script:transferOffset += $end + 1
      }
      $script:transferCheckpointSize = [int][Math]::Min([long]64, $script:transferOffset)
      $stream.Position = $script:transferOffset - $script:transferCheckpointSize
      $script:transferCheckpoint = [Convert]::ToBase64String($reader.ReadBytes($script:transferCheckpointSize))
      $script:transferWritten = $file.LastWriteTimeUtc
    } catch [IO.IOException] {
      # Retry when the engine has finished rotating or opening the log.
    } finally {
      if ($stream) { $stream.Dispose() }
    }
  }
  $result.mods = $script:transferLogMetrics.mods
  $result.current = $script:transferLogMetrics.current
  $result.registered = [bool]$script:transferLogMetrics.registered
  if ($script:transferLogMetrics.speedAt) {
    $age = [Math]::Max(0.0, ($Now - $script:transferLogMetrics.speedAt).TotalSeconds)
    if ($age -le 30) {
      $result.speedAge = [Math]::Round($age)
      $result.speedB = $script:transferLogMetrics.speedB
    }
  }
  $result
}
function Get-TransferCacheBytes($Directory) {
  if (!$Directory) { return $null }
  $temp = [IO.DirectoryInfo]::new([IO.Path]::Combine($Directory, 'temp'))
  if (!$temp.Exists) { return $null }
  $bytes = [double]0
  try {
    foreach ($chunk in $temp.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $bytes += $chunk.Length }
    $bytes
  } catch [IO.IOException] { } catch [UnauthorizedAccessException] { }
}
function Get-TransferOutputProgress([string]$Directory, [datetime]$StartedAt) {
  if (!$Directory) { return $null }
  $meta = [IO.FileInfo]::new((Join-Path $Directory 'meta'))
  if (!$meta.Exists -or $meta.Length -gt 4MB -or $meta.LastWriteTimeUtc -lt $StartedAt.ToUniversalTime().AddSeconds(-2)) {
    return $null
  }
  $key = "$Directory|$($StartedAt.Ticks)|$($meta.LastWriteTimeUtc.Ticks)|$($meta.Length)"
  $progress = $script:transferOutputProgress
  if (!$progress -or $progress.key -ne $key) {
    $files = @{}
    $total = [double]0
    try {
      foreach ($entry in (Get-AddonPackageFiles $Directory)) {
        $path = Get-AddonPayloadPath $Directory $entry.name
        $size = [long]0
        if (!$path -or ![long]::TryParse([string]$entry.size, [ref]$size) -or $size -lt 0 -or $files.ContainsKey($path)) { return $null }
        $files[$path] = $size
        $total += $size
      }
    } catch { return $null }
    if (!$total) { return $null }
    $progress = @{ key = $key; files = $files; total = $total; observedPartial = @{} }
    $script:transferOutputProgress = $progress
  }
  $written = [double]0
  $recent = $StartedAt.ToUniversalTime().AddSeconds(-2)
  foreach ($path in $progress.files.Keys) {
    $file = [IO.FileInfo]::new($path)
    try {
      if (!$file.Exists -or $file.LastWriteTimeUtc -lt $recent) { continue }
      $size = $file.Length
      $expected = $progress.files[$path]
      if ($size -gt 0 -and $size -lt $expected) { $progress.observedPartial[$path] = $true }
      # An output file that appears at full size can have been preallocated.
      if ($size -lt $expected -or $progress.observedPartial[$path]) { $written += [Math]::Min($size, $expected) }
    } catch [IO.IOException] { continue }
  }
  @{ b = $written; total = $progress.total }
}
function Read-StatusInventory {
  $scannedAt = Get-Date
  $dirs = Get-DirMap
  $client = [string[]]@(Get-ClientIds | Where-Object { $_ })
  $installed = @{}
  $versions = @{}
  foreach ($entry in $dirs.GetEnumerator()) {
    $dir = $entry.Value
    if (!(Test-AddonComplete $dir.path $dir.mtime)) { continue }
    $installed[$entry.Key] = $true
    $versions[$entry.Key] = Get-InstalledVersion $dir.path
  }
  $recent = @(foreach ($id in ($installed.Keys | Sort-Object { $dirs[$_].mtime } -Descending)) {
    if ([IO.Directory]::Exists((Join-Path $dirs[$id].path 'temp'))) { continue }
    @{ id = $id; name = $dirs[$id].name; b = [double]$dirs[$id].bytes }
  })
  @{ dirs = $dirs; client = $client; installed = $installed; versions = $versions
     recent = $recent; bytes = (Get-AddonsBytes); scannedAt = $scannedAt }
}
function Get-StatusInventory {
  if (!$script:backgroundInventory) { return Read-StatusInventory }
  if ($script:inventoryTask -and $script:inventoryTask.IsCompleted) {
    try {
      $next = $script:inventoryShell.EndInvoke($script:inventoryTask)
      if ($next.Count -eq 1 -and $next[0].dirs -is [hashtable]) { $script:inventory = $next[0] }
    }
    catch {
      # Keep the last inventory snapshot after a failed scan and rebuild the runspace on the next attempt.
      if (!$script:inventoryError) {
        Write-Host ("library scan failed: " + $_.Exception.Message) -ForegroundColor Yellow
        $script:inventoryError = $true
      }
      try { $script:inventoryShell.Dispose() } catch { }
      $script:inventoryShell = $null
    }
    finally { $script:inventoryTask = $null; $script:inventoryAt = Get-Date }
  }
  $every = if ($script:inventoryEvery) { [double]$script:inventoryEvery } else { 3 }
  if (!$script:inventoryTask -and (!$script:inventoryAt -or ((Get-Date) - $script:inventoryAt).TotalSeconds -ge $every)) {
    if (!$script:inventoryShell) {
      $script:inventoryShell = [PowerShell]::Create()
      $null = $script:inventoryShell.AddScript({
        param($Code, $ProfileRoot, $EngineAddons)
        $script:DsProfile = $ProfileRoot
        $script:Addons = $EngineAddons
        $script:exactCache = @{}
        $script:dirCacheAt = $script:clCacheAt = $script:clBytesAt = [datetime]::MinValue
        . (Join-Path $Code 'state.ps1')
        . (Join-Path $Code 'dashboard-core.ps1')
      }, $false).AddArgument($PSScriptRoot).AddArgument($DsProfile).AddArgument($Addons)
      $null = $script:inventoryShell.Invoke()
      $script:inventoryShell.Commands.Clear()
      $null = $script:inventoryShell.AddCommand('Read-StatusInventory')
    }
    $script:inventoryTask = $script:inventoryShell.BeginInvoke()
  }
  if ($script:inventory) { return $script:inventory }
  @{ dirs = @{}; client = @(); installed = @{}; versions = @{}; recent = @(); bytes = 0; pending = $true }
}
function Update-StatusCompletions($Inventory, $Queued, [datetime]$Now, [bool]$Running) {
  if (!$script:fastCompleted) { $script:fastCompleted = @{} }
  foreach ($id in @($script:fastCompleted.Keys)) {
    if ($Inventory.scannedAt -ge $script:fastCompleted[$id].at) { $script:fastCompleted.Remove($id) }
  }
  $candidates = $script:transferLogMetrics.candidates
  if (!$candidates.Count) { return }
  $wantedVersions = @{}
  foreach ($mod in $Queued) {
    if ($mod.modId -and $mod.version) { $wantedVersions[$mod.modId] = [string]$mod.version }
  }
  foreach ($id in @($candidates.Keys)) {
    $candidate = $candidates[$id]
    if (!$Running -and !$candidate.until) { $candidate.until = $Now.AddSeconds(15) }
    if ($candidate.until -and $Now -gt $candidate.until) {
      $candidates.Remove($id)
      continue
    }
    $folder = $Inventory.dirs[$id].path
    try {
      if (!$folder -or ![IO.Directory]::Exists($folder)) {
        if (![IO.Directory]::Exists($Addons)) { continue }
        $folder = [IO.Directory]::EnumerateDirectories($Addons, "*_$id") | Select-Object -First 1
      }
      # The engine may fill files to their final length before it finishes unpacking.
      if (!$folder -or [IO.Directory]::Exists((Join-Path $folder 'temp')) -or !(Test-AddonComplete $folder $null -Fresh)) { continue }
      $version = Get-InstalledVersion $folder
      if ($wantedVersions[$id] -and $wantedVersions[$id] -ne $version) { continue }
      $bytes = [double]0
      foreach ($file in [IO.DirectoryInfo]::new($folder).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $bytes += $file.Length }
      $script:fastCompleted[$id] = @{ id = $id; name = $candidate.name; b = $bytes; version = $version; at = $Now }
      $candidates.Remove($id)
    } catch [IO.IOException] {
      # The engine can rename files during the check. The next poll can try again.
    } catch [UnauthorizedAccessException] {
      # Unreadable files cannot be confirmed as installed.
    }
  }
}
function Get-RecentDownloads($Inventory) {
  $pending = $script:transferLogMetrics.candidates
  if ($script:fastCompleted.Count) {
    foreach ($entry in ($script:fastCompleted.Values | Sort-Object at -Descending)) {
      @{ id = $entry.id; name = $entry.name; b = $entry.b }
    }
  }
  foreach ($entry in $Inventory.recent) {
    if ($pending -and $pending.ContainsKey($entry.id)) { continue }
    if (!$script:fastCompleted -or !$script:fastCompleted.ContainsKey($entry.id)) { $entry }
  }
}
function Get-RecentRevision($Recent) {
  $revision = "$($Recent.Count)|"
  if ($Recent.Count) { $revision += "$($Recent[0].id)@$([long]$Recent[0].b)" }
  $revision
}
function Resolve-TransferBytes($Reported, $Cached, [double]$Expected) {
  # Report the greater of the engine's progress and the bytes measured in the mod's download cache.
  $b = $null
  $fromCache = $false
  if ($null -ne $Reported) { $b = [double]$Reported }
  if ($null -ne $Cached) {
    if ($null -eq $b -or [double]$Cached -gt $b) { $b = [double]$Cached; $fromCache = $true }
  }
  if ($null -eq $b) { return $null }
  if ($Expected -gt 0 -and $b -gt $Expected) { $b = $Expected }
  $pct = $null
  if ($Expected -gt 0) { $pct = [Math]::Round(100 * $b / $Expected, 1) }
  @{ b = $b; pct = $pct; fromCache = $fromCache }
}

function Sync-SizeMapFromDisk {
  # Reload the size map when it changes. Both workers use it.
  if (-not $Sizes) { return }
  $file = [IO.FileInfo]::new($Sizes)
  if (-not $file.Exists) { return }
  $stamp = "$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
  if ($script:sizeFileStamp -eq $stamp) { return }
  Set-WorkshopSizeCache (Read-WorkshopSizes)
  $script:sizeFileStamp = $stamp
}
function Read-WorkshopSizes {
  Read-Json $Sizes ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json)
}
function Set-WorkshopSizeCache($Document) {
  $map = @{}
  foreach ($entry in $Document.mods.PSObject.Properties) { $map[$entry.Name] = $entry.Value }
  $script:sizeMap = $map
  $script:TotalBytes = [double]$Document.totalBytes
}
function Set-WorkshopSize($Document, [string]$Id, [string]$Name, [double]$Bytes, [bool]$Exact) {
  $entry = [pscustomobject]@{ name = $Name; bytes = $Bytes; exact = $Exact }
  $Document.mods | Add-Member -MemberType NoteProperty -Name $Id -Value $entry -Force
  $script:sizeMap[$Id] = $entry
}
function Save-WorkshopSizes($Document) {
  $Document.totalBytes = [double]($Document.mods.PSObject.Properties | ForEach-Object { [double]$_.Value.bytes } | Measure-Object -Sum).Sum
  Save-Json $Document $Sizes 4
  Set-WorkshopSizeCache $Document
}
function Merge-NewWorkshopSizes($Mods) {
  $mutex = Lock-WorkshopState $Data
  try {
    $document = Read-WorkshopSizes
    foreach ($mod in $Mods) {
      if (!$document.mods.PSObject.Properties[$mod.id]) {
        Set-WorkshopSize $document $mod.id $mod.name $mod.size $mod.sizeKnown
      }
    }
    Save-WorkshopSizes $document
  } finally { Unlock-WorkshopState $mutex }
}
function Read-TrackedServers {
  (Read-Json $ServersPath ([pscustomobject]@{ servers = @() })).servers
}
function Save-TrackedServers($ServerRows) {
  Save-Json @{ servers = @($ServerRows) } $ServersPath 6
  $script:serverList = @($ServerRows)
}

function Get-Status {
  Sync-SizeMapFromDisk
  $engines = Get-DS
  $engine = $engines | Select-Object -First 1
  $runningNow = [bool]$engine
  $now = Get-Date
  $transfer = @{ mods = @{}; current = $null; speedB = 0; speedAge = 999 }
  if ($runningNow) {
    # Reading StartTime can fail after an engine exits.
    $startedAt = $null
    try { $startedAt = $engine.StartTime } catch { }
    if ($startedAt) { $transfer = Get-TransferSnapshot (Get-Log) $now $startedAt }
  }
  $inventory = Get-StatusInventory
  $dirs = $inventory.dirs
  $queued = @((Get-Cfg).game.mods)
  Update-StatusCompletions $inventory $queued $now $runningNow
  $pending = $script:transferLogMetrics.candidates
  $clIds = $inventory.client
  $installedIds = @($inventory.installed.Keys)
  $hidePending = $false
  foreach ($id in $pending.Keys) {
    if ($inventory.installed.ContainsKey($id) -or $id -in $clIds) { $hidePending = $true; break }
  }
  if ($hidePending) {
    $clIds = @($clIds | Where-Object { !$pending.ContainsKey($_) })
    $installedIds = @($installedIds | Where-Object { !$pending.ContainsKey($_) })
  }
  $clSet = @{}
  foreach ($i in $clIds) { $clSet[$i] = $true }
  $recent = @(if ($script:fastCompleted.Count -or $hidePending) { Get-RecentDownloads $inventory } else { $inventory.recent })
  if ($script:fastCompleted.Count) {
    $installedIds += @($script:fastCompleted.Keys | Where-Object { !$inventory.installed.ContainsKey($_) })
  }
  # Keep batch progress steady when the engine removes temporary files during assembly.
  $qrev = [string](Get-QueueRevision)
  if ($null -eq $script:modHigh -or $script:batchRev -ne $qrev) {
    $script:batchRev = $qrev
    $script:batchHighB = [double]0
    $script:batchHighPct = [double]0
    $script:batchTotalHighB = [double]0
    $script:modHigh = @{}
  }
  $batchBytes = [double]0
  $doneBytes = [double]0
  $doneCount = 0
  $unknownSizes = 0
  $estimatedSizes = 0
  $active = @{}
  $credited = @{}
  $currentExpected = [double]0
  $currentComplete = $currentQueued = $false
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
    $finished = if ($script:fastCompleted) { $script:fastCompleted[$id] }
    $complete = if ($pending -and $pending.ContainsKey($id)) {
      $false
    } elseif ($finished) {
      !$mod.version -or $finished.version -eq $mod.version
    } elseif ($mod.version) {
      $inventory.versions[$id] -eq $mod.version
    } else {
      $clSet.ContainsKey($id) -or $inventory.installed.ContainsKey($id)
    }
    if ($transfer.current.id -eq $id) {
      $currentQueued = $true
      $currentExpected = $expected
      $currentComplete = $complete
    }
    if ($complete) {
      $doneCount++
      if ($finished -and !$report) { $expected = [double]$finished.b }
      elseif ($dir -and !$report) { $expected = [double]$dir.bytes }
      $doneBytes += $expected
    } else {
      $credited[$id] = [double]0
      if ($expected -le 0) { $unknownSizes++ }
      elseif (!$report) { $estimatedSizes++ }
      if ($report) {
        $doneBytes += $report.b
        $credited[$id] = [double]$report.b
        if (!$transfer.current -and ($now - $report.at).TotalSeconds -le 35) {
          $active[$report.name] = @{ id = $id; name = $report.name; b = $report.b; expB = $report.expB
            pct = if ($report.expB) { [Math]::Round(100 * $report.b / $report.expB, 1) } else { 0 } }
        }
      }
      @{ id = $id; name = $mod.name; version = $mod.version }
    }
    $batchBytes += $expected
  })
  # Steam can fetch dependencies which are absent from the configured mod list.
  if (!$transfer.current -and $transfer.mods.Count) {
    foreach ($entry in $dirs.GetEnumerator()) {
      $report = $transfer.mods[[string]$entry.Value.name]
      if ($report -and !$active.ContainsKey($report.name) -and
          ($now - $report.at).TotalSeconds -le 35 -and !$inventory.installed.ContainsKey($entry.Key)) {
        $active[$report.name] = @{ id = $entry.Key; name = $report.name; b = $report.b; expB = $report.expB
          pct = if ($report.expB) { [Math]::Round(100 * $report.b / $report.expB, 1) } else { 0 } }
      }
    }
  }
  if ($transfer.current) {
    $id = $transfer.current.id
    $name = $transfer.current.name
    $dir = $dirs[$id]
    if (!$currentComplete -and ($currentQueued -or $id -notin $installedIds)) {
      $latest = $transfer.mods[$name]
      $expected = if ($latest -and $latest.expB -gt 0) { $latest.expB }
        elseif ($currentExpected -gt 0) { $currentExpected } else { [double]$sizeMap[$id].bytes }
      $row = @{ id = $id; name = $name; expB = $expected }
      if ($latest) {
        $row.b = $latest.b
        if ($expected -gt 0) { $row.pct = [Math]::Round(100 * $latest.b / $expected, 1) }
      }
      $path = $dir.path
      if (!$path) {
        # A mod can start before the background library scan reaches its folder.
        $path = Get-AddonDirectories $Addons "*_$id" | Select-Object -First 1 -ExpandProperty FullName
      }
      $row.cachedB = Get-TransferCacheBytes $path
      if ($null -ne $row.cachedB) {
        if ($script:cacheTransferId -ne $id -or $script:cacheTransferRun -ne $script:transferLogRun) {
          $script:cacheGrowthAt = $null
        } elseif ($row.cachedB -gt $script:lastCacheBytes) { $script:cacheGrowthAt = $now }
        $script:cacheTransferId = $id
        $script:cacheTransferRun = $script:transferLogRun
        $script:lastCacheBytes = $row.cachedB
        $row.cacheGrowing = $script:cacheGrowthAt -and ($now - $script:cacheGrowthAt).TotalSeconds -lt 2
      }
      $last = if ($latest) { $latest.at } else { $transfer.current.at }
      $row.age = [Math]::Max(0.0, [Math]::Floor(($now - $last).TotalSeconds))
      # Use cache bytes when they exceed the engine's latest report.
      $output = Get-TransferOutputProgress $path $transfer.current.at
      $outputBytes = $null
      if ($output -and $output.total -gt 0) {
        if ($expected -le 0) {
          $expected = $output.total
          $row.expB = $expected
          if ($currentQueued) {
            $batchBytes += $expected
            $unknownSizes--
            $estimatedSizes++
          }
        }
        $outputBytes = $expected * ($output.b / $output.total)
      }
      $localBytes = $row.cachedB
      if ($null -ne $outputBytes -and ($null -eq $localBytes -or $outputBytes -gt $localBytes)) {
        $localBytes = $outputBytes
      }
      $bytes = Resolve-TransferBytes $(if ($latest) { $latest.b } else { $null }) $localBytes $expected
      if ($bytes) { $row.b = $bytes.b; $row.pct = $bytes.pct; $row.fromCache = $bytes.fromCache }
      $active[$name] = $row
    }
  }
  # Show queued mods with filesystem activity before the engine logs the start of a download.
  if ($runningNow -and !$transfer.current -and !$active.Count -and !$transfer.registered) {
    foreach ($mod in $queued) {
      $id = Test-ModId $mod.modId
      if (!$id -or $inventory.installed.ContainsKey($id)) { continue }
      $dir = $dirs[$id]
      if (!$dir -or ($now - $dir.mtime).TotalSeconds -gt 120) { continue }
      $expected = if ($mod.size) { [double]$mod.size } elseif ($sizeMap[$id]) { [double]$sizeMap[$id].bytes } else { [double]0 }
      $cached = Get-TransferCacheBytes $dir.path
      $bytes = Resolve-TransferBytes $null $cached $expected
      $row = @{ id = $id; name = $mod.name; expB = $expected
                age = [Math]::Max(0.0, [Math]::Floor(($now - $dir.mtime).TotalSeconds)) }
      if ($bytes) { $row.b = $bytes.b; $row.pct = $bytes.pct; $row.fromCache = $bytes.fromCache }
      $active[$mod.name] = $row
    }
  }
  if (!$active.Count) { $transfer.speedB = 0 }
  foreach ($row in $active.Values) {
    $id = [string]$row.id
    if ($credited.ContainsKey($id) -and $null -ne $row.b -and $row.b -gt $credited[$id]) {
      $doneBytes += $row.b - $credited[$id]
      $credited[$id] = $row.b
    }
  }
  if (!$queueList.Count) {
    $batchBytes = $doneBytes = $doneCount = $unknownSizes = $estimatedSizes = 0
    $queued = @()
  }
  if ($batchBytes -gt 0) {
    if ($doneBytes -gt $script:batchHighB) { $script:batchHighB = $doneBytes }
    # Keep the batch byte count monotonic if an expected size shrinks. Cap the percentage at 100.
    $doneBytes = [Math]::Max($doneBytes, $script:batchHighB)
    if ($batchBytes -gt $script:batchTotalHighB) { $script:batchTotalHighB = $batchBytes }
    $batchBytes = $script:batchTotalHighB   # a known size must not shrink either
    foreach ($row in @($active.Values)) {
      $id = [string]$row.id
      if (-not $id) { continue }
      $high = if ($script:modHigh.ContainsKey($id)) { [double]$script:modHigh[$id] } else { [double]0 }
      if ($null -ne $row.b) {
        if ([double]$row.b -ge $high) { $script:modHigh[$id] = [double]$row.b } else { $row.b = $high }
      } elseif ($high -gt 0) { $row.b = $high }
      if ($row.expB -gt 0 -and $null -ne $row.b) { $row.pct = [Math]::Round([Math]::Min(100.0, 100.0 * [double]$row.b / [double]$row.expB), 1) }
    }
  } else { $script:batchHighB = [double]0; $script:batchHighPct = [double]0; $script:batchTotalHighB = [double]0 }
  # Keep the last known percentage while a queued mod has an unknown size.
  $pctRaw = if ($batchBytes -gt 0) {
    if ($unknownSizes) { $script:batchHighPct } else { [Math]::Min(100.0, 100 * $doneBytes / $batchBytes) }
  } else { 0 }
  if ($batchBytes -gt 0 -and $pctRaw -lt $script:batchHighPct) { $pctRaw = $script:batchHighPct }
  elseif ($batchBytes -gt 0) { $script:batchHighPct = $pctRaw }
  $verify = $null
  $vf = [IO.FileInfo]::new((Join-Path $Data 'verify.json'))
  if ($vf.Exists) {
    $vstamp = "$($vf.LastWriteTimeUtc.Ticks)|$($vf.Length)"
    if ($script:verifyStamp -ne $vstamp) { $script:verifyFile = Read-Json $vf.FullName $null; $script:verifyStamp = $vstamp }
    $verify = $script:verifyFile
  }
  # The page fetches /completed when the inventory revision changes.
  $recentRev = Get-RecentRevision $recent
  @{ running = $runningNow; paused = (Test-Path -LiteralPath (Join-Path $Data 'paused.flag'))
     speedB = $transfer.speedB; speedAge = $transfer.speedAge
     doneB = $doneBytes; totalB = $batchBytes; unknownSizes = $unknownSizes; estimatedSizes = $estimatedSizes
     pct = [int][Math]::Floor($pctRaw)
     pctF = [Math]::Round($pctRaw, 2)
     doneCount = $doneCount; totalMods = $queued.Count
     addonsB = $inventory.bytes; inventoryPending = [bool]$inventory.pending
     active = @($active.Values); cl = $clIds; installedIds = $installedIds; failed = @(Get-SkippedNames)
     queue = @($queueList); queueRevision = $qrev; recentRev = $recentRev; tok = $token; verify = $verify }
}
function Start-DS {
  $ctl = Lock-Engine
  if (-not $ctl) { return 'another start/stop is in progress - try again' }
  try {
    if (!@((Get-Cfg).game.mods).Count) { return 'nothing to download - the queue is empty' }
    $mine = Get-DS -Fresh
    if ($null -eq $mine) { return 'cannot read the process list right now - press Start again' }
    if (@($mine).Count) { return 'already running' }
    # Refuse to share a profile with a server the downloader does not own.
    if (Get-EngineProcesses) {
      return 'another ArmaReforgerServer is already running - close it, then press Start'
    }
    # Trim completed mods before start to stay below the engine's 1 MB download-list limit.
    $trim = & (Join-Path $PSScriptRoot 'trim-config.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare the download queue: $($trim -join ' ')" }
    # Start the engine only when mods remain after trimming.
    $left = @((Get-Cfg).game.mods).Count
    if ($left -eq 0) { return 'nothing to download - the queue is empty' }
    Remove-Item (Join-Path $Data 'paused.flag') -Force -ErrorAction SilentlyContinue
    Start-DownloadEngine
    # Return without waiting for startup. The watchdog handles early exits.
    'Downloads started.'
  } finally { $ctl.ReleaseMutex() }
}
function Stop-DS {
  $ctl = Lock-Engine
  if (-not $ctl) { throw 'another start/stop is in progress - try again' }
  try {
    New-Item -ItemType File -Force (Join-Path $Data 'paused.flag') | Out-Null
    # Verify that the engine stopped before the caller edits its config.
    $p = Get-DS -Fresh
    if ($null -eq $p) { throw 'cannot read the process list right now - nothing was changed, try again in a moment' }
    if (-not $p) { return 'not running' }
    $p | Stop-Process -Force
    # Wait for the old engine to exit before allowing a restart.
    foreach ($i in 1..20) {
      $remaining = Get-DS -Fresh
      if ($null -ne $remaining -and !@($remaining).Count) { return 'Downloads paused.' }
      Start-Sleep -Milliseconds 500
    }
    throw 'could not confirm the downloader stopped'
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-Verify {
  # Verify only mods tracked in the Workshop size map.
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
  # the status reply may come from another worker process: keep the result on disk
  Save-Json $script:verify (Join-Path $Data 'verify.json') 5
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
  # Cache the validated engine and client addon IDs for three seconds.
  if (((Get-Date) - $script:haveAt).TotalSeconds -lt 3) { return $script:haveCache }
  $have = @{}
  foreach ($e in (Get-DirMap).GetEnumerator()) {
    if (Test-AddonComplete $e.Value.path $e.Value.mtime) { $have[$e.Key] = $true }
  }
  # client copies: same exact check (the launcher reads that folder)
  foreach ($d in (Get-AddonDirectories (Get-ClientAddons $DsProfile))) {
    $m = [regex]::Match($d.Name, '_([0-9A-F]{16})$')
    if (-not $m.Success) { continue }
    if (Test-AddonComplete $d.FullName $d.LastWriteTime) { $have[$m.Groups[1].Value] = $true }
  }
  $script:haveCache = $have; $script:haveAt = Get-Date
  $have
}
function Get-UiHaveIds {
  # Use the background inventory for display. Queue decisions use Get-HaveIds to check the files.
  $inv = Get-StatusInventory
  if ($inv.pending) { return Get-HaveIds }
  $have = @{}
  foreach ($id in $inv.installed.Keys) { $have[$id] = $true }
  foreach ($id in $inv.client) { $have[$id] = $true }
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
    $note = Get-StartNote
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
  $out = & (Join-Path $PSScriptRoot 'make-preset.ps1') -ServerId $Id -Summary
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
  @{ job = $jobId; msg = 'Saving preset...' }
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
  $mutex = Lock-WorkshopState $Data
  try {
    $current = @(Read-TrackedServers)
    $server = $current | Where-Object id -eq $Id | Select-Object -First 1
    if ($server -and $server.changed) {
      $server.changed = $null
      Save-TrackedServers $current
    }
  } finally { Unlock-WorkshopState $mutex }
}
function Get-DirectoryResponse([string]$Resource, [int]$Ttl = 30, [switch]$Refresh) {
  $now = [DateTime]::UtcNow
  $entry = $script:directoryCache[$Resource]
  if (!$Refresh -and $entry -and $entry.expires -gt $now) { return $entry.response }
  $response = Invoke-WorkshopApi -Uri "$ApiBase/$Resource" -Headers $ApiH -TimeoutSec 10
  if ($response.status -and $response.status -ne 'success') { throw 'The directory could not complete this request.' }
  if ($script:directoryCache.Count -ge 64) { $script:directoryCache.Clear() }
  $script:directoryCache[$Resource] = @{ expires = $now.AddSeconds($Ttl); response = $response }
  $response
}
function Get-DirectoryPage($Query) {
  $page = 0
  if ([int]::TryParse($Query['page'], [ref]$page)) { return [Math]::Max(1, [Math]::Min(100000, $page)) }
  1
}
function Search-Mods($Query) {
  $search = ([string]$Query['q']).Trim()
  $id = Test-ModId $search
  if ($id) {
    $m = (Get-DirectoryResponse "mods/$id" 90).mod
    if ($m.id -eq $id -and !$m.private) {
      return @{ total = 1; page = 1; pages = 1; mods = @((Get-WorkshopPreview $m)) }
    }
    return @{ total = 0; page = 1; pages = 0; mods = @() }
  }
  $page = Get-DirectoryPage $Query
  $sort = [string]$Query['sort']
  if ($sort -notin 'popularity','most-rated','newest','created','recently-updated','highest-rated','subscribers','version_size','largest','name') { $sort = 'popularity' }
  $resource = "mods?page=$page&sort=$sort"
  if ($search) { $resource += "&search=$([uri]::EscapeDataString($search.Substring(0, [Math]::Min($search.Length, 120))))" }
  foreach ($tag in @(([string]$Query['tags'] -split ',') | Select-Object -First 5)) {
    if ($tag -match '^[A-Z0-9_ -]{1,32}$') { $resource += "&tags=$([uri]::EscapeDataString($tag.ToUpperInvariant()))" }
  }
  $r = Get-DirectoryResponse $resource 90
  @{ total = [int]$r.meta.totalMods; page = if ($r.meta.currentPage) { [int]$r.meta.currentPage } else { $page }
     pages = [int]$r.meta.totalPages
     mods = @($r.data | Where-Object { (Test-ModId $_.id) -and !$_.private } | ForEach-Object { Get-WorkshopPreview $_ }) }
}
function Get-WorkshopPreview($Mod) {
  @{
    id = Test-ModId $Mod.id; name = [string]$Mod.name; author = [string]$Mod.author
    summary = [string]$Mod.summary; size = [double]$Mod.size; version = [string]$Mod.version
    gameVersion = [string]$Mod.gameVersion; subscribers = $Mod.subscriberCount
    rating = $Mod.rating; ratingCount = $Mod.ratingCount; updatedAt = $Mod.updatedAt; deployments = $Mod.analytics.totalDeployments
    tags = @($Mod.tags | Where-Object { $_ -is [string] }); image = [string]$Mod.imageUrl
  }
}
function Get-WorkshopDetails([string]$Id) {
  $id = Test-ModId $Id
  if (!$id) { throw 'Invalid Workshop ID.' }
  $mod = (Get-DirectoryResponse "mods/$id" 90).mod
  if ($mod.id -ne $id -or $mod.private) { throw 'This Workshop item is unavailable.' }
  $preview = Get-WorkshopPreview $mod
  $preview.description = [string]$mod.description
  $preview.images = @((@($mod.previewImages) + @($mod.screenshots)) | Where-Object { $_ -is [string] } | Select-Object -Unique -First 8)
  $preview.dependencies = @($mod.dependencies | Where-Object { Test-ModId $_.id } |
    Select-Object id, name, version, size)
  $preview.scenarios = @($mod.scenarios | Where-Object { $_ } | Select-Object name, id)
  $preview.totalSize = [double]$mod.totalSize
  $preview.obsolete = [bool]$mod.obsolete
  $preview.license = [string]$mod.license
  $preview
}
function Get-WorkshopVersions([string]$Id, [string]$Version) {
  $id = Test-ModId $Id
  if (!$id) { throw 'Invalid Workshop ID.' }
  if ($Version) {
    if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$') { throw 'Invalid Workshop version.' }
    $row = (Get-DirectoryResponse "mods/$id/versions/$([uri]::EscapeDataString($Version))" 300).data
    if (!$row -or $row.version -cne $Version) { throw 'This Workshop version is unavailable.' }
    return @{ changelog = [string]$row.changelog }
  }
  $rows = (Get-DirectoryResponse "mods/$id/versions" 90).data.versions
  @{ versions = @($rows | Where-Object { $_ -and $_.published -ne $false } | Select-Object version, gameVersion, size, createdAt) }
}
function Get-ModDeps([string]$Id) {
  # Include dependencies in the queue and size estimate.
  try { @((Invoke-WorkshopApi -Uri "$ApiBase/mods/$Id/dependencies" -Headers $ApiH -TimeoutSec 10).data.dependencies) }
  catch { @() }
}
function Get-StartNote {
  # Starting can fail (no engine installed, another server running). The queue change
  # itself already succeeded, so report the failure instead of failing the action.
  try { " ($(Start-DS))" } catch { " (could not start: $($_.Exception.Message))" }
}

function Add-QueuedMods($Mods) {
  $ctl = Lock-Engine
  if (!$ctl) { throw 'The downloader is busy. Try adding the mods again.' }
  try {
    $existing = @{}
    foreach ($mod in (Get-Cfg).game.mods) { $existing[$mod.modId] = $true }
    if (!($Mods | Where-Object { !$existing.ContainsKey($_.modId) } | Select-Object -First 1)) {
      return @{ count = 0; note = '' }
    }
    $engine = Get-DS -Fresh
    if ($null -eq $engine) { throw 'Cannot check whether the downloader is running. Try again.' }
    $wasRunning = @($engine).Count -gt 0
    # Stop the current engine before appending so it cannot overwrite the updated queue on exit.
    if ($wasRunning) { Stop-DS | Out-Null }
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
    $note = if ($count -gt 0 -or $wasRunning) { Get-StartNote } else { '' }
    @{ count = $count; note = $note }
  } finally { $ctl.ReleaseMutex() }
}
function Invoke-AddMod([string]$Id) {
  # Append the mod and its dependencies to the queue.
  if ($Id -notmatch '^[0-9A-Fa-f]{16}$') { throw 'not a mod id' }
  $Id = $Id.ToUpper()
  # Check the disk again in case a cached addon has been removed.
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
  # Cap the dependency scan at 20 seconds and 200 mods. Queue the results found so far.
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
  Merge-NewWorkshopSizes @($add | ForEach-Object { @{ id = $_.modId; name = $_.name; size = $_.size; sizeKnown = $_.size -gt 0 } })
  $msg = "Queued '$($m.name)'"
  if ($depNames.Count) { $msg += " and $($depNames.Count) dependencies" }
  if ($cut) { $msg += '. Dependency search reached its limit' }
  $msg + $queueChange.note
}
function Test-DirectoryServerId([string]$Id) {
  $Id -match '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
}
function Get-ServerPreview($Server) {
  @{
    id = $Server.id; name = $Server.name; players = $Server.players; maxPlayers = $Server.maxPlayers
    region = $Server.region; online = [bool]$Server.online; modCount = $Server.modCount
    scenarioName = $Server.scenarioName; platforms = @($Server.platforms | Where-Object { $_ })
    platform = $Server.platform; official = $Server.official; locked = $Server.passwordProtected
    battleye = $Server.battlEye; queue = $Server.queue; queueMax = $Server.queueMax
    gameVersion = $Server.gameVersion; lastSeen = $Server.lastSeen; image = $Server.scenarioThumbnailUrl
    joinable = [bool]($Server.online -and $Server.joinable -ne $false -and $Server.joinUrl)
  }
}
function Get-Browse($Query) {
  $page = Get-DirectoryPage $Query
  $sort = [string]$Query['sort']
  if ($sort -notin 'players','name','newest','lastSeen') { $sort = 'players' }
  $resource = "servers?perPage=24&page=$page&sort=$sort"
  $online = [string]$Query['online']
  if ($online -eq 'false') { $resource += '&includeOffline=true&online=false' }
  elseif ($online -eq 'all') { $resource += '&includeOffline=true' }
  else { $resource += '&includeOffline=false&online=true' }
  $search = ([string]$Query['q']).Trim()
  if ($search) { $resource += "&search=$([uri]::EscapeDataString($search.Substring(0, [Math]::Min($search.Length, 120))))" }
  $region = [string]$Query['region']
  if ($region -match '^[a-z0-9_-]{1,32}$') { $resource += "&region=$region" }
  $platform = [string]$Query['platform']
  if ($platform -in 'pc','xbox','psn') { $resource += "&platform=$platform" }
  foreach ($filter in 'official','hasMods','battleye','locked') {
    if ($Query[$filter] -in 'true','false') { $resource += "&$filter=$($Query[$filter].ToLowerInvariant())" }
  }
  $r = Get-DirectoryResponse $resource -Refresh:($Query['refresh'] -eq '1')
  $rows = @(foreach ($server in $r.data) {
    if (!(Test-DirectoryServerId $server.id)) { continue }
    $script:browserServers[$server.id] = [DateTime]::UtcNow.AddMinutes(30)
    Get-ServerPreview $server
  })
  if ($script:browserServers.Count -gt 750) {
    $recent = @($script:browserServers.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 500)
    $script:browserServers = @{}
    foreach ($server in $recent) { $script:browserServers[$server.Key] = $server.Value }
  }
  @{ servers = $rows; total = [int]$r.meta.totalServers; pages = [int]$r.meta.totalPages
     page = if ($r.meta.currentPage) { [int]$r.meta.currentPage } else { $page }
     dataset = $r.dataset | Select-Object warming, stale, lastCollectionAt, snapshotAgeSeconds }
}
function Get-Detail([string]$Id, [switch]$AllowEmpty) {
  if (!(Test-DirectoryServerId $Id)) { throw 'Invalid server ID.' }
  $server = (Get-DirectoryResponse "servers/$Id").server
  if ($server.id -ne $Id) { throw 'This server is unavailable.' }
  if (!$AllowEmpty -and !($server.mods | Select-Object -First 1)) { throw 'This server has no public mod list.' }
  $server
}
function Get-ServerHistory([string]$Id, [string]$Range) {
  if (!(Test-DirectoryServerId $Id)) { throw 'Invalid server ID.' }
  if ($Range -notin '6h','24h','7d','30d') { $Range = '24h' }
  $r = Get-DirectoryResponse "servers/$Id/history?range=$Range" 90
  @{ points = @($r.points | Where-Object { $_.t -and $null -ne $_.avg } | Select-Object t, avg, min, max, cap) }
}
function Measure-ServerRegions {
  $now = [DateTime]::UtcNow
  if ($script:regionLatency -and $script:regionLatency.expires -gt $now) { return $script:regionLatency.response }
  # These are the directory's regional ping sites. Server-list addresses never participate.
  $sites = @{
    frankfurt = 'de'; london = 'ukln'; los_angeles = 'usla'; miami = 'usmi'
    new_york = 'usny'; singapore = 'sg'; sydney = 'ausy'; tokyo = 'jpto'
  }
  $pending = @{}
  $results = @{}
  $timer = [Diagnostics.Stopwatch]::StartNew()
  try {
    foreach ($site in $sites.GetEnumerator()) {
      $probe = [Net.NetworkInformation.Ping]::new()
      try {
        $pending[$site.Key] = @{ probe = $probe; task = $probe.SendPingAsync("ping-location-$($site.Value).nitrado.net", 1400) }
      } catch {
        Write-Host "Ping could not start for $($site.Key): $($_.Exception.Message)"
        $probe.Dispose()
      }
    }
    foreach ($entry in $pending.GetEnumerator()) {
      $remaining = [int][Math]::Max(0, 2300 - $timer.ElapsedMilliseconds)
      try {
        if ($entry.Value.task.Wait($remaining) -and $entry.Value.task.Result.Status -eq 'Success') {
          $results[$entry.Key] = [long]$entry.Value.task.Result.RoundtripTime
        }
      } catch { Write-Host "Ping unavailable for $($entry.Key): $($_.Exception.Message)" }
    }
  } finally {
    foreach ($entry in $pending.Values) { $entry.probe.Dispose() }
  }
  $response = @{ regions = $results }
  $script:regionLatency = @{ expires = $now.AddSeconds(45); response = $response }
  $response
}
function Get-LibraryJoinUrl([string]$Id, [switch]$Browser) {
  if (!(Test-DirectoryServerId $Id) -or
      ($Id -notin $serverList.id -and (!$Browser -or $script:browserServers[$Id] -lt [DateTime]::UtcNow))) {
    throw 'This server is not in your Library.'
  }
  $server = (Invoke-WorkshopApi "$ApiBase/servers/$Id" -Headers $ApiH -TimeoutSec 10).server
  if ($server.id -ne $Id -or !$server.online -or !$server.joinable) { throw 'This server is unavailable. Try again later.' }
  $url = [string]$server.joinUrl
  if ($url -cnotmatch '^steam://run/1874880//([A-Za-z0-9_-]{16,2048})={0,2}/$') {
    throw 'The server directory did not provide a valid Steam invite.'
  }
  $tokenText = $Matches[1].Replace('-', '+').Replace('_', '/')
  $padded = $tokenText.PadRight([int](4 * [Math]::Ceiling($tokenText.Length / 4.0)), '=')
  try { $invite = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded)) | ConvertFrom-Json }
  catch { throw 'The Steam invite could not be read.' }
  if ($invite.id -ne $Id -or $invite.inviteToken -isnot [string]) { throw 'The Steam invite does not match this server.' }
  $url
}
function Invoke-AddServer([string]$Id) {
  # Append missing server mods with their Workshop sizes.
  $s = Get-Detail $Id -AllowEmpty
  if ($s.passwordProtected) { return 'server is password protected - its modlist is not public' }
  if (!($s.mods | Select-Object -First 1) -and (!$s.online -or $null -eq $s.modCount -or $s.modCount -ne 0)) {
    throw 'This server has no public mod list.'
  }
  $name = ([string]$s.name -split '\|')[0].Trim()
  if ($name.Length -gt 60) { $name = $name.Substring(0, 60).Trim() }
  $have = (Get-HaveIds).Clone()
  foreach ($m in (Get-Cfg).game.mods) { $have[$m.modId] = $true }
  $want = @($s.mods | ForEach-Object {
    $mid = Test-ModId $_.id
    if (-not $mid) { Write-Host "ignoring a mod with an invalid id from the API: $($_.id)" -ForegroundColor Yellow; return }
    [PSCustomObject]@{ id = $mid; name = $_.name; size = [double]$_.size; sizeKnown = [bool]$_.sizeKnown }
  })
  $new = @($want | Where-Object { -not $have.ContainsKey($_.id) })

  $server = [PSCustomObject]@{
    id = $Id; name = $s.name; mods = @($want | ForEach-Object {
      [PSCustomObject]@{ id = $_.id; name = $_.name; e = [double]$_.size } }) }
  $mutex = Lock-WorkshopState $Data
  try {
    $current = @(Read-TrackedServers | Where-Object id -ne $Id)
    Save-TrackedServers ($current + $server)
  } finally { Unlock-WorkshopState $mutex }
  if (-not $new) { return "'$name' is in the list - all $(@($want).Count) mods are on disk or queued, nothing to download" }

  $queueChange = Add-QueuedMods @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  Merge-NewWorkshopSizes $new
  $gb = [Math]::Round(($new | ForEach-Object { [double]$_.size } | Measure-Object -Sum).Sum / 1GB, 2)
  "Queued $($new.Count) mods for '$name' (~$gb GB)$($queueChange.note)."
}
function Merge-ServerMods($sv, $mods, $sz) {
  # Validate and apply the refreshed server lists and sizes on the request thread.
  $mods = @(foreach ($m in $mods) {
    $mid = Test-ModId $m.id
    if (-not $mid) { Write-Host "refresh: ignoring a mod with an invalid id: $($m.id)" -ForegroundColor Yellow; continue }
    [PSCustomObject]@{ id = $mid; name = $m.name; size = [double]$m.size; sizeKnown = [bool]$m.sizeKnown }
  })
  foreach ($m in $mods) {
    if (-not $sizeMap.ContainsKey($m.id) -and $m.sizeKnown -and $m.size) {
      Set-WorkshopSize $sz $m.id $m.name $m.size $true
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
  # Fetch server lists and sizes in one background job at a time. Apply the result on the request thread.
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
function Save-RefreshState($Payload) {
  $mutex = Lock-WorkshopState $Data
  try {
    $document = Read-WorkshopSizes
    Set-WorkshopSizeCache $document
    foreach ($entry in $Payload.sizes.PSObject.Properties) {
      $modId = Test-ModId $entry.Name
      if (!$modId) { Write-Host "refresh: ignoring a size entry with an invalid id: $($entry.Name)" -ForegroundColor Yellow; continue }
      $existing = $sizeMap[$modId]
      if (!$existing.exact -or $entry.Value.exact) {
        Set-WorkshopSize $document $modId $existing.name $entry.Value.bytes $entry.Value.exact
      }
    }
    $servers = @(Read-TrackedServers)
    $ok = 0
    $changed = 0
    $want = [ordered]@{}
    foreach ($incoming in $Payload.servers) {
      $server = $servers | Where-Object id -eq $incoming.id | Select-Object -First 1
      if (!$server -or $incoming.error) { continue }
      if ($incoming.name) { $server.name = $incoming.name }
      $previous = @($server.mods.id)
      Merge-ServerMods $server @($incoming.mods) $document
      foreach ($mod in $server.mods) {
        if ($mod.id -notin $previous) { $want[$mod.id] = $mod.name }
      }
      if ($server.changed) { $changed++ }
      $ok++
    }
    Save-WorkshopSizes $document
    Save-TrackedServers $servers
    @{ ok = $ok; changed = $changed; want = $want }
  } finally { Unlock-WorkshopState $mutex }
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
      try { $payload = Get-Content -LiteralPath $rj.out -Raw -Encoding UTF8 | ConvertFrom-Json }
      catch { $err = "unreadable refresh result: $($_.Exception.Message)" }
    } else { $err = 'the refresh produced no result' }
  }

  $result = $null
  try {
    if ($err) {
      $result = @{ state = 'failed'; error = $err }
    } else {
      $script:directoryCache.Clear()
      $script:dirCacheAt = (Get-Date).AddMinutes(-10)
      $script:clCacheAt = (Get-Date).AddMinutes(-10)
      $saved = Save-RefreshState $payload
      $q = if ($rj.queueRevision -eq (Get-QueueRevision)) { Add-MissingToQueue $saved.want }
        else { @{ count = 0; note = ' - queue changed during refresh' } }
      $summary = "Refreshed $($saved.ok) of $(@($payload.servers).Count) servers."
      if ($q.count) { $summary += " Queued $($q.count) mods$($q.note)." }
      if ($saved.changed) { $summary += " $($saved.changed) mod lists changed." }
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
  $mutex = Lock-WorkshopState $Data
  try {
    $current = @(Read-TrackedServers)
    $server = $current | Where-Object id -eq $Id | Select-Object -First 1
    if (!$server) { throw 'server is not in the list' }
    Save-TrackedServers @($current | Where-Object id -ne $Id)
    "Removed '$($server.name)' from tracked servers."
  } finally { Unlock-WorkshopState $mutex }
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

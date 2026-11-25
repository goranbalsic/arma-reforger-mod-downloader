# Shared state helpers. Dot-source this; do not copy it.
#
# these helpers were pasted into five scripts and drifted: the File.Replace
# null-argument bug had to be fixed five times, and test-rules asserted its own
# copy of the completion rule. One copy, one rule.
$script:exactCache = @{}

# The engine validates its config before it does anything and refuses to start
# without these two ("required params are missing: name scenarioId"). A fresh
# install had a config with only "mods", so the engine exited in under a second
# and the watchdog restarted it forever. It never loads a world - the scenario
# only has to be one that ships with the game.
$script:CfgStub = '{"bindAddress":"127.0.0.1","game":{"name":"Reforger Mod Downloader","scenarioId":"{59AD59368755F41A}Missions/21_GM_Eden.conf","visible":false,"maxPlayers":1,"mods":[]}}'

function Get-ProjectRepository {
  $entries = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'repository.txt'))
  if ($entries.Count -ne 2 -or $entries[0] -cnotmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$' -or $entries[1] -notmatch '^[1-9][0-9]*$') {
    throw 'Invalid GitHub repository configuration.'
  }
  @{ name = $entries[0]; id = [long]$entries[1] }
}

function Expand-ProjectArchive([string]$Archive, [string]$Destination) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $root = (Get-NormalizedFilePath $Destination) + [IO.Path]::DirectorySeparatorChar
  $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if (!$name -or $name.StartsWith('/') -or $name -match '[:\x00-\x1f]') {
        throw 'The update contains an invalid archive path.'
      }
      $path = [IO.Path]::GetFullPath((Join-Path $root $name))
      if (!$path.StartsWith($root, $comparison)) { throw 'The update contains a file outside the extraction folder.' }
      if ($name.EndsWith('/')) { $null = [IO.Directory]::CreateDirectory($path) }
      else {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
      }
    }
  } finally {
    $zip.Dispose()
  }
}

function Repair-Cfg($j) {
  # one repair for configs written before the stub had name/scenarioId, used by the
  # app and by the trim, so the engine is never started from a config it rejects.
  # Add-Member -Force: an object read from JSON cannot gain a property by assignment.
  if ($null -eq $j -or $null -eq $j.game) { return $CfgStub | ConvertFrom-Json }
  if (!$j.bindAddress) { $j | Add-Member -NotePropertyName bindAddress -NotePropertyValue '127.0.0.1' -Force }
  if (-not $j.game.name) { $j.game | Add-Member -NotePropertyName name -NotePropertyValue 'Reforger Mod Downloader' -Force }
  if (-not $j.game.scenarioId) { $j.game | Add-Member -NotePropertyName scenarioId -NotePropertyValue '{59AD59368755F41A}Missions/21_GM_Eden.conf' -Force }
  if ($null -eq $j.game.visible) { $j.game | Add-Member -NotePropertyName visible -NotePropertyValue $false -Force }
  if (!$j.game.maxPlayers) { $j.game | Add-Member -NotePropertyName maxPlayers -NotePropertyValue 1 -Force }
  # the DS writes "mods": null on shutdown, and @($null).Count is 1 - so every
  # caller believed one mod was still queued when the queue was empty
  if ($null -eq $j.game.mods) { $j.game | Add-Member -NotePropertyName mods -NotePropertyValue @() -Force }
  $j
}

function Get-GameProfile {
  if ($env:RFMM_GAME_PROFILE) { return $env:RFMM_GAME_PROFILE }
  if ($IsLinux) { return $null }
  Join-Path $env:USERPROFILE 'Documents\\My Games\\ArmaReforger'
}
function Get-ClientAddons([string]$EngineProfile) {
  $game = Get-GameProfile
  if ($game) { return (Join-Path $game 'addons') }
  Join-Path $EngineProfile 'addons'
}
function Get-EngineExecutable([string]$InstallRoot) {
  if ($env:RFMM_ENGINE_EXE) { return $env:RFMM_ENGINE_EXE }
  $name = if ($IsLinux) { 'ArmaReforgerServer' } else { 'ArmaReforgerServer.exe' }
  Join-Path (Join-Path $InstallRoot 'armar-server') $name
}
function Start-DownloadEngine {
  if ($IsLinux) {
    Start-Process -FilePath $Exe -ArgumentList ('-config "{0}" -profile "{1}"' -f $Cfg,$DsProfile) -WorkingDirectory (Split-Path $Exe -Parent) -RedirectStandardInput '/dev/null' -RedirectStandardOutput (Join-Path $Data 'engine-output.log') -RedirectStandardError (Join-Path $Data 'engine-error.log')
  } else {
    Start-Process -FilePath $Exe -ArgumentList ('-config "{0}" -profile "{1}"' -f $Cfg,$DsProfile) -WorkingDirectory (Split-Path $Exe -Parent) -WindowStyle Hidden
  }
}
function Get-EngineProcesses {
  $name = if ($IsLinux) { 'ArmaReforgerSer*' } else { 'ArmaReforgerServer' }
  Get-Process -Name $name -ErrorAction SilentlyContinue
}

function Test-EngineTransferStalled([datetime]$StartedAt, [datetime]$LogWrite, [string]$Addons, $Queued, [datetime]$Now) {
  $cutoff = $Now.ToUniversalTime().AddMinutes(-5)
  if ($StartedAt.ToUniversalTime() -ge $cutoff -or $LogWrite.ToUniversalTime() -ge $cutoff) { return $false }
  $ids = @{}
  foreach ($mod in $Queued) {
    $id = Test-ModId $mod.modId
    if ($id) { $ids[$id] = $true }
  }
  $root = [IO.DirectoryInfo]::new($Addons)
  if (!$root.Exists) { return $true }
  try {
    foreach ($directory in $root.EnumerateDirectories()) {
      $match = [regex]::Match($directory.Name, '_([0-9A-Fa-f]{16})$')
      if (!$match.Success -or !$ids.ContainsKey($match.Groups[1].Value)) { continue }
      foreach ($file in $directory.EnumerateFiles()) {
        if ($file.Length -gt 0 -and $file.LastWriteTimeUtc -ge $cutoff) { return $false }
      }
      $cache = [IO.DirectoryInfo]::new([IO.Path]::Combine($directory.FullName, 'temp'))
      if ($cache.Exists) {
        foreach ($chunk in $cache.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
          if ($chunk.Length -gt 0 -and $chunk.LastWriteTimeUtc -ge $cutoff) { return $false }
        }
      }
    }
  } catch [IO.IOException], [UnauthorizedAccessException] {
    # A file scan racing with assembly is insufficient evidence to stop an engine.
    return $false
  }
  $true
}

function Get-NormalizedFilePath([string]$Path) {
  if ($IsLinux) { $Path = $Path.Replace('\', '/') }
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.Length -gt ([IO.Path]::GetPathRoot($full)).Length) {
    return $full.TrimEnd([char[]]'\/')
  }
  $full
}

function Test-EngineConfigArgument([string[]]$Arguments, [string]$ConfigPath) {
  $option = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
  $positions = @(for ($i = 1; $i -lt $Arguments.Count; $i++) {
    if ([string]::Equals($Arguments[$i], '-config', $option)) { $i }
  })
  if ($positions.Count -ne 1 -or $positions[0] + 1 -ge $Arguments.Count) { return $false }
  $candidate = $Arguments[$positions[0] + 1]
  if (!$candidate -or !$ConfigPath) { return $false }
  try {
    [string]::Equals((Get-NormalizedFilePath $candidate), (Get-NormalizedFilePath $ConfigPath), $option)
  } catch [ArgumentException] { $false }
  catch [NotSupportedException] { $false }
}

function Test-EngineCommandLine([string]$CommandLine, [string]$ConfigPath) {
  $tokens = @([regex]::Matches($CommandLine, '"[^"]*"|[^\s"]+') | ForEach-Object { $_.Value.Trim('"') })
  Test-EngineConfigArgument $tokens $ConfigPath
}

function Get-OwnEngine([string]$ConfigPath) {
  # ONLY an engine this tool launched: its command line must carry our config path.
  # Matching the process name alone killed a community server the user runs
  # themselves. Empty array = none; $null = the query itself failed, which must
  # never read as "not running" or a second engine starts on the same profile.
  # No path means no rule: matching on '' would claim every engine on the box.
  if (-not $ConfigPath) { return $null }
  if ($IsLinux) {
    $found = @(foreach ($process in Get-Process -Name 'ArmaReforgerSer*' -ErrorAction SilentlyContinue) {
      try { $argsOnDisk = [IO.File]::ReadAllText("/proc/$($process.Id)/cmdline").TrimEnd([char]0).Split([char]0) }
      catch [IO.FileNotFoundException] { continue }
      catch [IO.DirectoryNotFoundException] { continue }
      catch { return $null }
      if ($argsOnDisk.Length -gt 1 -and [IO.Path]::GetFileName($argsOnDisk[0]) -ceq 'ArmaReforgerServer' -and
          (Test-EngineConfigArgument $argsOnDisk $ConfigPath)) {
        $process
      }
    })
    return ,$found
  }
  # WMI does fail on a busy machine: it errored for 2.5 minutes straight while the
  # audit ran, and a blind watchdog cannot restart a dead engine. One retry makes a
  # single hiccup invisible; a real outage still reports "unknown" and is skipped.
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $found = @(Get-CimInstance Win32_Process -Filter "Name='ArmaReforgerServer.exe'" `
        -OperationTimeoutSec 5 -ErrorAction Stop |
        Where-Object { $_.CommandLine -and (Test-EngineCommandLine $_.CommandLine $ConfigPath) } |
        ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
      return ,$found   # the comma keeps an empty result an array, not $null
    } catch {
      if ($attempt -eq 2) { return $null }
      Start-Sleep -Milliseconds 500
    }
  }
}

function Enter-DownloaderFileLock([string]$Path, [int]$Milliseconds) {
  $timer = [Diagnostics.Stopwatch]::StartNew()
  do {
    try { return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
      if ($timer.ElapsedMilliseconds -ge $Milliseconds) { return $null }
      Start-Sleep -Milliseconds 25
    }
  } while ($true)
}

function Get-DownloaderLockPath([string]$Name) {
  $user = [Environment]::UserName -replace '[^A-Za-z0-9_.-]', '_'
  Join-Path ([IO.Path]::GetTempPath()) "rfmm-$user-$Name.lock"
}

function Lock-Engine([int]$Milliseconds = 20000) {
  # the dashboard and the watchdog both start/stop the engine. A named mutex
  # removes the check-then-act race that could put two DS processes on one profile
  # (both write <mod>\temp\, so an assembled pak can be a mix of two downloads).
  # $null means the lock was not acquired: the caller must NOT continue.
  if ($IsLinux) {
    if ($global:RFMMEngineFileLock) {
      $global:RFMMEngineFileLock.Depth++
      return $global:RFMMEngineFileLock
    }
    $stream = Enter-DownloaderFileLock (Get-DownloaderLockPath 'engine') $Milliseconds
    if (!$stream) { return $null }
    $lock = [pscustomobject]@{ Stream = $stream; Depth = 1 }
    $lock | Add-Member -MemberType ScriptMethod -Name ReleaseMutex -Value {
      $this.Depth--
      if (!$this.Depth) {
        $this.Stream.Dispose()
        $global:RFMMEngineFileLock = $null
      }
    }
    $global:RFMMEngineFileLock = $lock
    return $lock
  }
  $m = [Threading.Mutex]::new($false, 'ReforgerEngineCtl')
  try {
    if (-not $m.WaitOne($Milliseconds)) { $m.Dispose(); return $null }
  } catch [System.Threading.AbandonedMutexException] {
    # the previous holder died inside the critical section. WaitOne takes ownership
    # anyway, but it throws instead of returning - without this the engine could
    # never be started again for the life of this process.
    return $m
  }
  $m
}

function Save-Json($obj, [string]$Path, [int]$Depth = 5) {
  # atomic: closing the console kills the process, Set-Content truncates in place,
  # so a half-written state file would be unrecoverable. A path that is not a path
  # means a shadowed variable upstream - fail loudly instead of writing a file
  # named after a .NET type.
  if ($Path -notmatch '[\\/]') { throw "Save-Json: refusing to write to '$Path'" }
  $Path = Get-NormalizedFilePath $Path
  $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $obj | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
    for ($attempt = 0; ; $attempt++) {
      try {
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
        break
      } catch [IO.IOException] {
        # Another writer can create the file between Exists and Move. On Windows a reader
        # can also briefly hold the destination open without sharing deletion.
        if ($attempt -ge 9 -or ![IO.File]::Exists($tmp)) { throw }
        Start-Sleep -Milliseconds 25
      }
    }
  } finally {
    if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
  }
}

function Lock-WorkshopState([string]$Directory) {
  $path = Get-NormalizedFilePath $Directory
  if ($IsLinux) {
    # A file lock works across graphical and headless sessions without a session runtime directory.
    $file = Join-Path $path '.workshop-state.lock'
    $lock = Enter-DownloaderFileLock $file 20000
    if ($lock) { return $lock }
    throw 'Workshop state is busy. Try again.'
  }
  $path = $path.ToUpperInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))).Replace('-', '') }
  finally { $sha.Dispose() }
  $mutex = [Threading.Mutex]::new($false, "ReforgerWorkshopState-$key")
  try {
    if ($mutex.WaitOne(20000)) { return $mutex }
  } catch [Threading.AbandonedMutexException] { return $mutex }
  catch {
    $mutex.Dispose()
    throw
  }
  $mutex.Dispose()
  throw 'Workshop state is busy. Try again.'
}
function Unlock-WorkshopState($Lock) {
  try {
    if ($Lock -is [Threading.Mutex]) { $Lock.ReleaseMutex() }
  } finally { $Lock.Dispose() }
}

function Read-Json([string]$Path, $Default) {
  # an unreadable state file must never stop the program: a parse failure moves it
  # aside (never deletes it) so the next step can run on defaults. An IO error is
  # not a parse error - leave the file alone and try again later.
  if (-not (Test-Path -LiteralPath $Path)) { return $Default }
  try { $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop } catch { return $Default }
  if (-not $raw) { return $Default }
  try { return ($raw | ConvertFrom-Json) }
  catch {
    $bad = "$Path.corrupt-$(Get-Date -f yyyyMMdd-HHmmss)"
    Move-Item -LiteralPath $Path -Destination $bad -Force -ErrorAction SilentlyContinue
    Write-Host "WARNING: $([IO.Path]::GetFileName($Path)) was unreadable - moved to $(Split-Path $bad -Leaf), using defaults" -ForegroundColor Red
    return $Default
  }
}

function Read-EngineConfig([string]$Path) {
  try {
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($json -isnot [pscustomobject] -or $json.game -isnot [pscustomobject]) { throw 'Missing game configuration.' }
    if ($null -ne $json.game.mods -and $json.game.mods -isnot [array]) { throw 'The mod list is not an array.' }
    Repair-Cfg $json
  } catch {
    throw "Could not read the download queue at '$Path': $($_.Exception.Message)"
  }
}

function Update-Cfg([scriptblock]$Change, [string]$ConfigPath, [int]$LockMs = 20000) {
  # Serialised read-modify-write of the engine config. $Change receives the parsed
  # config, may mutate it, and its output is returned. Throws when the engine lock
  # is not available: a protected write must never continue without it.
  # Do NOT call Start-DS / Stop-DS from inside $Change: they take the same lock
  # themselves. Call them before/after this function.
  if (-not $ConfigPath) { throw 'Update-Cfg: no config path' }
  $ctl = Lock-Engine $LockMs
  if (-not $ctl) { throw 'another start/stop is in progress - the queue was not changed' }
  try {
    $j = Read-EngineConfig $ConfigPath
    $out = & $Change $j
    Save-Json $j $ConfigPath
    $out
  } finally { $ctl.ReleaseMutex() }
}

function Get-Queued([string]$ConfigPath) {
  # Mods in the engine config, or $null when the file cannot be read or parsed.
  # $null must never be read as "no mods queued": the watchdog used to treat a
  # read error as an empty queue and could stop a running engine. The comma keeps
  # a successfully parsed empty list an array (a bare @() unrolls to $null).
  if (-not $ConfigPath) { return $null }
  $raw = $null
  try { $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop } catch { return $null }
  if (-not $raw) { return $null }
  $j = $null
  try { $j = $raw | ConvertFrom-Json } catch { return $null }
  if ($null -eq $j -or $null -eq $j.game) { return $null }
  $m = $j.game.mods
  # the DS writes "mods": null on shutdown: a real, empty queue
  if ($null -eq $m) { return ,@() }
  return ,@($m)
}

function Test-ModId([string]$Id) {
  # Canonical (upper-case) 16-hex mod id, or $null. Called at every API boundary:
  # an id that came from the internet must never reach a file name, a filter or the
  # queue. Case-insensitive on the way in.
  if (-not $Id) { return $null }
  if ($Id -notmatch '^[0-9A-Fa-f]{16}$') { return $null }
  $Id.ToUpper()
}

function Test-Sha256([string]$Path, [string]$Expected) {
  # $Expected is "sha256:<hex>" from the GitHub release asset. $null = nothing to
  # compare against (old release), $true/$false otherwise. This detects a truncated
  # or altered download; it is NOT a signature - the digest comes from the same
  # origin, so a compromised release would carry a matching digest.
  if (-not $Expected) { return $null }
  $m = [regex]::Match($Expected, '^sha256:([0-9a-fA-F]{64})$')
  if (-not $m.Success) { return $null }
  (Get-FileHash $Path -Algorithm SHA256).Hash.ToLower() -eq $m.Groups[1].Value.ToLower()
}

function Get-WorkshopFailures($Lines, [int]$From = 0, $Current = $null) {
  # Workshop refusals per mod id in a dedicated-server log: a refusal follows the
  # "started" line of the mod that caused it. Pure and resumable, because the
  # watchdog re-reads the same file every 15 s - counting the same lines again used
  # to drop a mod after one real failure. Returns the next offset and the id that
  # is still waiting for its outcome.
  $all = @($Lines)
  $counts = @{}
  for ($i = $From; $i -lt $all.Count; $i++) {
    $ln = $all[$i]
    if ($ln -match 'Addon Download started ([0-9A-F]{16})') { $Current = $Matches[1]; continue }
    if ($Current -and $ln -match 'Failed to fetch addon details') {
      if ($counts.ContainsKey($Current)) { $counts[$Current]++ } else { $counts[$Current] = 1 }
      $Current = $null
    }
  }
  @{ counts = $counts; current = $Current; next = $all.Count }
}

function Get-AddonPackageFiles([string]$Path) {
  $metadata = [IO.File]::ReadAllText([IO.Path]::Combine($Path, 'meta')) | ConvertFrom-Json -ErrorAction Stop
  $versions = @($metadata.meta.versions)
  $selected = [int]$metadata.meta.selectedRev
  if ($selected -ge 0 -and $selected -lt $versions.Count) { $versions[$selected].package.files }
}

function Get-AddonPayloadPath([string]$Folder, [string]$Name) {
  if (!$Name -or [IO.Path]::IsPathRooted($Name) -or $Name -match ':' -or $Name -match '^[\\/]') { return $null }
  $segments = @($Name -split '[\\/]')
  if ($segments -contains '..') { return $null }
  [IO.Path]::Combine($Folder, ($segments -join [IO.Path]::DirectorySeparatorChar))
}

function Test-AddonComplete([string]$Path, $Mtime, [switch]$Fresh) {
  # THE completion rule: the addon's own meta lists every file with its exact
  # size, and the game itself reads it that way. Never use a folder total.
  # The cache also keys on the folder's own write time: removing a file changes
  # that, while the newest-file time (Mtime) stays the same - so a mod that lost
  # an old file kept its cached "complete".
  $dirTime = [IO.Directory]::GetLastWriteTimeUtc($Path).Ticks
  $c = $script:exactCache[$Path]
  if (!$Fresh -and $c -and $c.mtime -eq $Mtime -and $c.dir -eq $dirTime) { return $c.ok }
  $ok = $false
  $metaPath = [IO.Path]::Combine($Path, 'meta')
  if ([IO.File]::Exists($metaPath)) {
    try {
      $files = @(Get-AddonPackageFiles $Path)
      # @($null).Count is 1: a meta with no file list used to enter the success
      # branch, skip every nameless entry and report the addon as complete
      if ($files.Count -gt 0 -and $files[0] -and $files[0].name -and $null -ne $files[0].size) {
        $ok = $true
        foreach ($f in $files) {
          if (-not $f -or -not $f.name -or $null -eq $f.size) { $ok = $false; break }
          $localPath = Get-AddonPayloadPath $Path $f.name
          if (!$localPath) { $ok = $false; break }
          $file = [IO.FileInfo]::new($localPath)
          if (!$file.Exists -or $file.Length -ne [long]$f.size) { $ok = $false; break }
        }
      }
    } catch { $ok = $false }
  }
  $script:exactCache[$Path] = @{ mtime = $Mtime; dir = $dirTime; ok = $ok }
  $ok
}

function Initialize-AddonsLink([string]$Addons, [string]$ClientAddons, [string]$ConfigPath) {
  # One folder for mods: the engine writes into its own profile, the game reads its
  # own addons folder, and a junction makes those the same folder. Lives here so the
  # migration can be tested without starting the dashboard.
  $item = Get-Item $Addons -Force -ErrorAction SilentlyContinue
  if ($item -and $item.LinkType) { return $true }   # already one folder
  $own = Get-OwnEngine $ConfigPath
  if ($null -eq $own) { return $false }             # cannot ask: never move files blindly
  if (@($own).Count) { return $false }              # never move files under a live engine
  if (-not (Test-Path $ClientAddons)) { New-Item -ItemType Directory -Force $ClientAddons | Out-Null }
  New-Item -ItemType Directory -Force (Split-Path $Addons -Parent) | Out-Null
  if ($item) {
    # move an older install's copies in (same volume = instant). A name that already
    # exists in the game folder stays as the game's copy. Never delete what was not
    # moved: a locked file made Move-Item fail and the old code removed the folder,
    # losing everything that had not been moved. A failed move can leave an EMPTY
    # destination folder behind, so success is judged by the source being gone.
    $had = @{}
    foreach ($d in @(Get-ChildItem $Addons -Force -ErrorAction SilentlyContinue)) {
      $had[$d.Name] = Test-Path (Join-Path $ClientAddons $d.Name)
    }
    $failed = @()
    foreach ($d in @(Get-ChildItem $Addons -Force -ErrorAction SilentlyContinue)) {
      $target = Join-Path $ClientAddons $d.Name
      if (-not $had[$d.Name]) {
        Move-Item -LiteralPath $d.FullName -Destination $target -Force -ErrorAction SilentlyContinue
        if (Test-Path $d.FullName) {
          if (-not @(Get-ChildItem $target -Force -ErrorAction SilentlyContinue).Count) {
            Remove-Item $target -Force -ErrorAction SilentlyContinue
          }
          $failed += $d.Name
        }
      }
    }
    if ($failed.Count) {
      Write-Host "could not move $($failed.Count) item(s) into the game addons folder - nothing was deleted: $($failed -join ', ')" -ForegroundColor Yellow
      return $false
    }
    if (@(Get-ChildItem -LiteralPath $Addons -Force -ErrorAction Stop).Count) {
      Write-Host 'Existing addon copies were kept. Completed downloads will be synced separately.' -ForegroundColor Yellow
      return $false
    }
    Remove-Item -LiteralPath $Addons -Force -ErrorAction SilentlyContinue
    if (Test-Path $Addons) {
      Write-Host 'the old engine addons folder could not be removed - not linking' -ForegroundColor Yellow
      return $false
    }
  }
  New-Item -ItemType Junction -Path $Addons -Target $ClientAddons -ErrorAction SilentlyContinue | Out-Null
  [bool](Get-Item $Addons -Force -ErrorAction SilentlyContinue).LinkType
}

function Get-InstalledVersion([string]$Directory) {
  # Called for every installed mod on each library scan (650 mods on the reference
  # library, every few seconds). Reading and parsing every meta each pass kept the
  # background scan hot; cache by the meta file's own stamp so a rewritten meta (an
  # update) invalidates only that mod.
  if (-not $script:versionCache) { $script:versionCache = @{} }
  $metaPath = Join-Path $Directory 'meta'
  $file = [IO.FileInfo]::new($metaPath)
  if (-not $file.Exists) { return $null }
  $stamp = "$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
  $hit = $script:versionCache[$Directory]
  if ($hit -and $hit.stamp -eq $stamp) { return $hit.version }
  $version = $null
  try {
    $meta = ([IO.File]::ReadAllText($metaPath) | ConvertFrom-Json).meta
    $index = [int]$meta.selectedRev
    if ($index -ge 0 -and $index -lt $meta.versions.Count) { $version = [string]$meta.versions[$index].version }
  } catch { }
  $script:versionCache[$Directory] = @{ stamp = $stamp; version = $version }
  $version
}

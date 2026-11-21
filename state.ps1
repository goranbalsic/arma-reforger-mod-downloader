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
$script:CfgStub = '{"game":{"name":"Reforger Mod Downloader","scenarioId":"{59AD59368755F41A}Missions/21_GM_Eden.conf","mods":[]}}'

function Repair-Cfg($j) {
  # one repair for configs written before the stub had name/scenarioId, used by the
  # app and by the trim, so the engine is never started from a config it rejects.
  # Add-Member -Force: an object read from JSON cannot gain a property by assignment.
  if ($null -eq $j -or $null -eq $j.game) { return $CfgStub | ConvertFrom-Json }
  if (-not $j.game.name) { $j.game | Add-Member -NotePropertyName name -NotePropertyValue 'Reforger Mod Downloader' -Force }
  if (-not $j.game.scenarioId) { $j.game | Add-Member -NotePropertyName scenarioId -NotePropertyValue '{59AD59368755F41A}Missions/21_GM_Eden.conf' -Force }
  # the DS writes "mods": null on shutdown, and @($null).Count is 1 - so every
  # caller believed one mod was still queued when the queue was empty
  if ($null -eq $j.game.mods) { $j.game | Add-Member -NotePropertyName mods -NotePropertyValue @() -Force }
  $j
}

function Get-OwnEngine([string]$ConfigPath) {
  # ONLY an engine this tool launched: its command line must carry our config path.
  # Matching the process name alone killed a community server the user runs
  # themselves. Empty array = none; $null = the query itself failed, which must
  # never read as "not running" or a second engine starts on the same profile.
  # No path means no rule: matching on '' would claim every engine on the box.
  if (-not $ConfigPath) { return $null }
  # WMI does fail on a busy machine: it errored for 2.5 minutes straight while the
  # audit ran, and a blind watchdog cannot restart a dead engine. One retry makes a
  # single hiccup invisible; a real outage still reports "unknown" and is skipped.
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $found = @(Get-CimInstance Win32_Process -Filter "Name='ArmaReforgerServer.exe'" `
        -OperationTimeoutSec 5 -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($ConfigPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
      return ,$found   # the comma keeps an empty result an array, not $null
    } catch {
      if ($attempt -eq 2) { return $null }
      Start-Sleep -Milliseconds 500
    }
  }
}

function Lock-Engine {
  # the dashboard and the watchdog both start/stop the engine. A named mutex
  # removes the check-then-act race that could put two DS processes on one profile
  # (both write <mod>\temp\, so an assembled pak can be a mix of two downloads).
  $m = [Threading.Mutex]::new($false, 'ReforgerEngineCtl')
  try {
    if (-not $m.WaitOne(20000)) { return $null }
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
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth $Depth | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}

function Read-Json([string]$Path, $Default) {
  # an unreadable state file must never stop the program: a parse failure moves it
  # aside (never deletes it) so the next step can run on defaults. An IO error is
  # not a parse error - leave the file alone and try again later.
  if (-not (Test-Path $Path)) { return $Default }
  try { $raw = Get-Content $Path -Raw -ErrorAction Stop } catch { return $Default }
  if (-not $raw) { return $Default }
  try { return ($raw | ConvertFrom-Json) }
  catch {
    $bad = "$Path.corrupt-$(Get-Date -f yyyyMMdd-HHmmss)"
    Move-Item $Path $bad -Force -ErrorAction SilentlyContinue
    Write-Host "WARNING: $([IO.Path]::GetFileName($Path)) was unreadable - moved to $(Split-Path $bad -Leaf), using defaults" -ForegroundColor Red
    return $Default
  }
}

function Test-AddonComplete([string]$Path, $Mtime) {
  # THE completion rule: the addon's own meta lists every file with its exact
  # size, and the game itself reads it that way. Never use a folder total.
  # The cache also keys on the folder's own write time: removing a file changes
  # that, while the newest-file time (Mtime) stays the same - so a mod that lost
  # an old file kept its cached "complete".
  $dirTime = (Get-Item $Path -Force -ErrorAction SilentlyContinue).LastWriteTimeUtc.Ticks
  $c = $script:exactCache[$Path]
  if ($c -and $c.mtime -eq $Mtime -and $c.dir -eq $dirTime) { return $c.ok }
  $ok = $false
  $metaPath = Join-Path $Path 'meta'
  if (Test-Path $metaPath) {
    try {
      $j = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json
      $versions = @($j.meta.versions)
      $files = @()
      if ($versions.Count -and $versions[0].package) { $files = @($versions[0].package.files) }
      # @($null).Count is 1: a meta with no file list used to enter the success
      # branch, skip every nameless entry and report the addon as complete
      if ($files.Count -gt 0 -and $files[0] -and $files[0].name -and $null -ne $files[0].size) {
        $ok = $true
        foreach ($f in $files) {
          if (-not $f -or -not $f.name -or $null -eq $f.size) { $ok = $false; break }
          $p = Join-Path $Path $f.name
          if (-not (Test-Path $p)) { $ok = $false; break }
          if ((Get-Item $p).Length -ne [long]$f.size) { $ok = $false; break }
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
        Move-Item $d.FullName $target -Force -ErrorAction SilentlyContinue
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
    Remove-Item $Addons -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $Addons) {
      Write-Host 'the old engine addons folder could not be removed - not linking' -ForegroundColor Yellow
      return $false
    }
  }
  New-Item -ItemType Junction -Path $Addons -Target $ClientAddons -ErrorAction SilentlyContinue | Out-Null
  [bool](Get-Item $Addons -Force -ErrorAction SilentlyContinue).LinkType
}

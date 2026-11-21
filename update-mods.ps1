# Runs in a background job so a library check does not block the dashboard.
param(
  [string]$Scope, [string[]]$Ids, [string]$Root, [string]$Data,
  [string]$ApiBase, [string]$UserAgent, [string]$QueueRevision
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\state.ps1"
. "$PSScriptRoot\dashboard-core.ps1"
$env:RFMM_HOME = $Root
$env:RFMM_DATA = $Data
$Cfg = Join-Path $Data 'batch1-serverconfig.json'
$DsProfile = Join-Path $Root 'serverprofile'
$Exe = Join-Path $Root 'armar-server\ArmaReforgerServer.exe'
if (!$PSBoundParameters.ContainsKey('QueueRevision')) { $QueueRevision = [string](Get-QueueRevision) }
$installed = @{}
foreach ($folder in @("$DsProfile\addons", "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons")) {
  foreach ($dir in Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue) {
    if ($dir.Name -notmatch '_([a-f0-9]{16})$') { continue }
    $id = $Matches[1].ToUpperInvariant()
    if (($Scope -eq 'all' -or $id -in $Ids) -and !$installed.ContainsKey($id) -and
        (Test-AddonComplete $dir.FullName $dir.LastWriteTime)) { $installed[$id] = $dir.FullName }
  }
}
if ($Scope -eq 'mod' -and !$installed.Count) { throw 'That mod is not installed.' }
$updates = @{}
$failed = @()
$checked = 0
foreach ($id in $installed.Keys) {
  try {
    $local = Get-InstalledVersion $installed[$id]
    if (!$local) { throw 'unreadable installed version' }
    $remote = (Invoke-RestMethod "$ApiBase/mods/$id" -UserAgent $UserAgent -TimeoutSec 12).mod
    if ($remote.id -ne $id -or !$remote.version) { throw 'missing Workshop version' }
    if ([version]$remote.version -gt [version]$local) {
      $updates[$id] = [pscustomobject]@{ modId=$id; name=$remote.name; version=$remote.version; size=[double]$remote.size }
    }
  } catch { $failed += $id }
  $checked++
  Write-Output "Checked $checked of $($installed.Count); $($updates.Count) updates found."
  if ($checked -lt $installed.Count) { Start-Sleep -Milliseconds 1050 }
}
$result = "Checked $checked installed mods. $($updates.Count) newer versions."
if ($failed.Count) { $result += " Could not check $($failed.Count): $($failed -join ', ')." }
if ($updates.Count) {
  $lock = Lock-Engine
  if (!$lock) { throw 'Engine busy. Retry the update check.' }
  try {
    if ($QueueRevision -ne [string](Get-QueueRevision)) {
      Write-Output "$result The queue changed during the check. No updates were queued."
      return
    }
    # Preserve any existing queue entries so cancelling this batch cannot
    # remove a download the user queued before the update check.
    foreach ($mod in (Get-Cfg).game.mods) { $updates.Remove([string]$mod.modId) }
    if (!$updates.Count) {
      Write-Output "$result The updates are already represented in the queue."
      return
    }
    $engine = Get-DS -Fresh
    if ($null -eq $engine) { throw 'Cannot inspect the download engine.' }
    if (@($engine).Count) { Stop-DS | Out-Null }
    Save-Json @{ updates = @($updates.Values) } (Join-Path $Data 'mod-update-batch.json')
    Update-Cfg {
      param($cfg)
      $cfg.game.mods = @($cfg.game.mods | Where-Object { !$updates.ContainsKey($_.modId) }) + @($updates.Values)
    } $Cfg | Out-Null
    $result += " Queued $($updates.Count) updates. Downloader: $(Start-DS)."
  } finally { $lock.ReleaseMutex() }
}
Write-Output $result

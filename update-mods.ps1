# Runs in a background job so a library check does not block the dashboard.
param(
  [string]$Scope, [string[]]$Ids, [string]$Root, [string]$Data,
  [string]$ApiBase, [string]$UserAgent, [string]$QueueRevision, [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'state.ps1')
. (Join-Path $PSScriptRoot 'workshop-api.ps1')
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')
$env:RFMM_HOME = $Root
$env:RFMM_DATA = $Data
$Cfg = Join-Path $Data 'batch1-serverconfig.json'
$DsProfile = Join-Path $Root 'serverprofile'
$Exe = Get-EngineExecutable $Root
if (!$PSBoundParameters.ContainsKey('QueueRevision')) { $QueueRevision = [string](Get-QueueRevision) }
function Write-UpdateProgress([string]$Phase, [string]$Text) {
  Save-Json @{ phase = $Phase; checked = $checked; total = $installed.Count; found = $updates.Count
    text = $Text; at = [datetime]::UtcNow.ToString('o') } (Join-Path $Data 'update-progress.json') 4
}
function Publish-AvailableUpdates {
  Save-Json @{ updates = @($updates.Values | Sort-Object name) } (Join-Path $Data 'mod-update-available.json') 4
}
function Add-FoundUpdate([string]$Id, $Remote) {
  if ($Remote.id -ne $Id -or !$Remote.version) { throw 'Missing Workshop version.' }
  $local = Get-InstalledVersion $installed[$Id]
  if (!$local) { throw 'Unreadable installed version.' }
  if ((Compare-WorkshopVersion $Remote.version $local) -gt 0) {
    $updates[$Id] = [pscustomobject]@{ modId=$Id; name=$Remote.name; version=$Remote.version; size=[double]$Remote.size }
  }
}
$installed = @{}
$updates = @{}
$failed = 0
$checked = 0
$result = 'Could not check for updates.'
try {
  $installed = Get-InstalledModsForUpdate $Ids -All:($Scope -eq 'all')
  if ($Scope -eq 'mod' -and !$installed.Count) { throw 'That mod is not installed.' }
  Write-UpdateProgress 'checking' 'Checking installed mod versions...'
  if ($CheckOnly -and $installed.Count) {
    # The recent catalog can reveal several updates in one request. It does not cover unlisted or older changes.
    for ($page = 1; $page -le 5; $page++) {
      try {
        $catalog = Invoke-WorkshopApi "$ApiBase/mods?sort=recently-updated&page=$page" -UserAgent $UserAgent -TimeoutSec 5
      } catch { break }
      $before = $updates.Count
      foreach ($remote in $catalog.data) {
        $id = Test-ModId $remote.id
        if (!$id -or !$installed.ContainsKey($id) -or $updates.ContainsKey($id)) { continue }
        try { Add-FoundUpdate $id $remote } catch { continue }
      }
      if ($updates.Count -ne $before) {
        $checked = $updates.Count
        Publish-AvailableUpdates
        Write-UpdateProgress 'checking' 'Checking installed mod versions...'
      }
      if ([int]$catalog.meta.totalPages -le $page -or $updates.Count -eq $installed.Count) { break }
    }
  }
  foreach ($id in $installed.Keys) {
    if ($updates.ContainsKey($id)) { continue }
    $before = $updates.Count
    try {
      $remote = (Invoke-WorkshopApi "$ApiBase/mods/$id" -UserAgent $UserAgent -TimeoutSec 12).mod
      Add-FoundUpdate $id $remote
    } catch {
      if ($_.Exception.Message -match '\b429\b') { break }
      $failed++
    }
    $checked++
    if ($CheckOnly -and $updates.Count -ne $before) { Publish-AvailableUpdates }
    Write-UpdateProgress 'checking' 'Checking installed mod versions...'
    if ($checked -lt $installed.Count) { Start-Sleep -Milliseconds 1200 }
  }
  $result = "Checked $($checked - $failed) of $($installed.Count) installed mods. $($updates.Count) newer versions."
  if ($checked -lt $installed.Count) { $result += ' Workshop rate limit reached. Try again later.' }
  elseif ($failed) { $result += " Could not check $failed mods." }
  if ($CheckOnly) { Publish-AvailableUpdates }
  elseif ($updates.Count) { $result += " $(Add-ModUpdateBatch $updates -QueueRevision $QueueRevision)" }
} catch {
  $result = "Update check failed: $($_.Exception.Message)"
  throw
} finally {
  Write-UpdateProgress 'done' $result
}
Write-Output $result

# Filesystem and process ownership checks shared by Windows and Linux CI.
$ErrorActionPreference = 'Stop'
$state = Join-Path (Split-Path $PSScriptRoot -Parent) 'state.ps1'
. $state
$temp = Join-Path ([IO.Path]::GetTempPath()) ('rfmm-state-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temp)
$jobs = @()
$failures = 0

function Check([string]$Name, [bool]$Passed) {
  if ($Passed) { "  ok   $Name" }
  else { "  FAIL $Name"; $script:failures++ }
}

try {
  $config = Join-Path $temp 'queue.json'
  $alternate = $temp + '\queue.json'
  Save-Json @{ value = 'initial' } $config
  try {
    Save-Json @{ value = 'backslash' } $alternate
    Check 'a backslash path can replace existing JSON' ((Read-Json $config $null).value -eq 'backslash')
  } catch { Check 'a backslash path can replace existing JSON' $false }
  Check 'engine config matches its normalized path' (Test-EngineCommandLine "server -config `"$alternate`"" $config)
  Check 'engine config matches without a trailing separator' (Test-EngineCommandLine "server -config `"$config/`"" $config)
  Check 'engine config ignores a different path' (-not (Test-EngineCommandLine "server -config `"$config-other`"" $config))

  $blocked = Join-Path $temp 'blocked.json'
  $null = [IO.Directory]::CreateDirectory($blocked)
  $failed = $false
  try { Save-Json @{ value = 'blocked' } $blocked } catch { $failed = $true }
  Check 'the swap errors when the destination is a directory' $failed
  Check 'the failed swap removes its temporary file' (-not @(Get-ChildItem -LiteralPath $temp -Filter 'blocked.json*.tmp').Count)

  $concurrent = Join-Path $temp 'concurrent.json'
  $merged = Join-Path $temp 'merged.json'
  Save-Json @{ writer1 = 0; writer2 = 0 } $merged
  foreach ($writer in 1, 2) {
    $jobs += Start-Job -ArgumentList $state,$temp,$concurrent,$writer -ScriptBlock {
      param($StatePath, $Root, $Destination, $Writer)
      $ErrorActionPreference = 'Stop'
      . $StatePath
      [IO.File]::WriteAllText((Join-Path $Root "ready-$Writer"), '')
      $deadline = [datetime]::UtcNow.AddSeconds(15)
      while (!(Test-Path -LiteralPath (Join-Path $Root 'start'))) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'Writer did not get the start signal.' }
        Start-Sleep -Milliseconds 10
      }
      foreach ($revision in 1..200) {
        Save-Json @{ writer = $Writer; revision = $revision } $Destination
        $mutex = Lock-WorkshopState $Root
        try {
          $path = Join-Path $Root 'merged.json'
          $document = Read-Json $path $null
          $property = "writer$Writer"
          $document.$property++
          Save-Json $document $path
        } finally { Unlock-WorkshopState $mutex }
      }
    }
  }
  $deadline = [datetime]::UtcNow.AddSeconds(15)
  while (!(Test-Path -LiteralPath (Join-Path $temp 'ready-1')) -or !(Test-Path -LiteralPath (Join-Path $temp 'ready-2'))) {
    if ([datetime]::UtcNow -ge $deadline) { throw 'Writers did not start.' }
    Start-Sleep -Milliseconds 20
  }
  [IO.File]::WriteAllText((Join-Path $temp 'start'), '')
  $null = Wait-Job -Job $jobs -Timeout 60
  foreach ($job in $jobs) {
    if ($job.State -ne 'Completed') {
      Write-Host $job.ChildJobs[0].JobStateInfo.Reason
    }
  }
  Check 'both writers complete all 200 swaps' (@($jobs | Where-Object State -EQ 'Completed').Count -eq 2)
  $latest = Read-Json $concurrent $null
  Check 'the concurrent destination contains valid JSON' ($latest.writer -in 1, 2 -and $latest.revision -eq 200)
  Check 'the concurrent swaps leave no temporary files' (-not @(Get-ChildItem -LiteralPath $temp -Filter 'concurrent.json*.tmp').Count)
  $shared = Read-Json $merged $null
  Check 'overlapping read-modify-writes preserve both writers' ($shared.writer1 -eq 200 -and $shared.writer2 -eq 200)
} finally {
  foreach ($job in $jobs) { Remove-Job -Job $job -Force }
  Remove-Item -LiteralPath $temp -Recurse -Force
}
if ($failures) { exit 1 }

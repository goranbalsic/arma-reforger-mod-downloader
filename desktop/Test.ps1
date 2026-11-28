# Offline smoke test for the same transport used by the desktop window.
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $env:TEMP ("rfmm-desktop-test-" + [guid]::NewGuid())
$data = Join-Path $fixture 'data'
$profile = Join-Path $fixture 'serverprofile'
$client = Join-Path $fixture 'Documents\My Games\ArmaReforger\addons'
New-Item -ItemType Directory -Path $data,$profile,$client -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $profile 'addons') -Target $client | Out-Null
New-Item -ItemType File -Path (Join-Path $data 'paused.flag') | Out-Null
$cfg = Join-Path $data 'batch1-serverconfig.json'
@'
{"game":{"name":"Test","scenarioId":"fixture","mods":[{"modId":"ABCDEF0123456789","name":"Sample","size":1048576}]}}
'@ | Set-Content -LiteralPath $cfg -Encoding UTF8
$partial = Join-Path $client 'Sample_ABCDEF0123456789'
New-Item -ItemType Directory $partial | Out-Null
Set-Content -Path (Join-Path $partial 'partial.pak') -Value 'unfinished'
'{"totalBytes":1048576,"mods":{"ABCDEF0123456789":{"name":"Sample","bytes":1048576}}}' |
  Set-Content -LiteralPath (Join-Path $data 'batch1-sizes.json') -Encoding UTF8
$serverId = 'aaaaaaaa-0000-0000-0000-000000000000'
$serverName = 'Caf' + [char]0xE9 + ' ' + [char]0x2605
$serversJson = @{ servers = @(@{ id = $serverId; name = $serverName; mods = @() }) } | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $data 'batch1-servers.json'), $serversJson, [Text.UTF8Encoding]::new($false))

$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\download-web.ps1" -Desktop' -f $source
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.StandardOutputEncoding = [Text.Encoding]::UTF8
$info.EnvironmentVariables['RFMM_HOME'] = $fixture
$info.EnvironmentVariables['RFMM_DATA'] = $data
$info.EnvironmentVariables['USERPROFILE'] = $fixture
$info.EnvironmentVariables['RFMM_GAME_PROFILE'] = Split-Path -Parent $client

function Send-Request([string]$Path, [string]$Method = 'GET') {
  $backend.StandardInput.WriteLine((@{ path = $Path; method = $Method } | ConvertTo-Json -Compress))
  do {
    $read = $backend.StandardOutput.ReadLineAsync()
    if (!$read.Wait(15000)) { throw "Desktop request timed out for $Path." }
    $line = $read.Result
    if ($null -eq $line) { throw 'Desktop worker closed the connection.' }
  } until ($line.StartsWith('RFMM '))
  $line.Substring(5) | ConvertFrom-Json
}

# Exercise a UTF-8 writer that emits a byte-order mark on its first write.
$inputEncoding = [Console]::InputEncoding
[Console]::InputEncoding = [Text.UTF8Encoding]::new($true)
$backend = [Diagnostics.Process]::Start($info)
try {
  $page = Send-Request '/'
  if ($page.status -ne 200) { throw "The dashboard returned $($page.status): $($page.body)" }
  if ($page.nonce -cnotmatch '^[0-9a-f]{32}$' -or !$page.body.Contains(('nonce="{0}"' -f $page.nonce))) {
    throw 'The dashboard HTML and desktop response must carry the same script nonce.'
  }
  if ($page.body -notmatch 'Remove') { throw 'The dashboard did not return the expected page.' }
  foreach ($id in 'failedNotice','vresNotice','modUpdateNotice','cancelModUpdates') {
    if (!$page.body.Contains(('id="{0}"' -f $id))) { throw "The dashboard is missing $id." }
  }
  $before = (Send-Request '/status').body | ConvertFrom-Json
  if ($before.queue.Count -ne 1 -or $before.totalB -ne 1048576 -or $before.running) { throw 'Unexpected initial queue.' }
  $preset = Send-Request "/make-preset?id=$serverId&background=1&t=$($before.tok)" 'POST'
  $presetReply = $preset.body | ConvertFrom-Json
  if ($preset.status -ne 200 -or !$presetReply.job -or $presetReply.msg -cne 'Saving preset...') {
    throw "The preset progress message was corrupted: $($preset.body)"
  }
  $tracked = (Send-Request '/servers').body | ConvertFrom-Json
  if ($tracked.servers[0].name -cne $serverName) { throw 'A UTF-8 server name did not survive the Windows worker.' }
  $deadline = [datetime]::UtcNow.AddSeconds(15)
  $indexed = $before
  while ($indexed.inventoryPending -and [datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $indexed = (Send-Request '/status').body | ConvertFrom-Json
  }
  if ($indexed.inventoryPending -or $indexed.addonsB -le 0 -or $indexed.queue.Count -ne 1) {
    throw 'The background library scan did not finish or lost the partial download.'
  }
  if ((Send-Request '/clear-queue').status -ne 405) { throw 'Queue controls should require POST.' }
  if ((Send-Request '/clear-queue' 'POST').status -ne 403) { throw 'Queue controls should require the session token.' }
  $removed = Send-Request "/remove-queued-mod?id=ABCDEF0123456789&t=$($before.tok)" 'POST'
  if ($removed.status -ne 200 -or $removed.body -notmatch 'removed') { throw "Remove failed: $($removed.body)" }
  $start = Send-Request "/start?t=$($before.tok)" 'POST'
  if ($start.status -ne 200 -or $start.body -notmatch 'queue is empty') { throw "Start failed: $($start.body)" }
  $after = (Send-Request '/status').body | ConvertFrom-Json
  if ($after.queue.Count -or $after.totalB -or $after.doneB -or $after.pct -or !(Test-Path $partial)) {
    throw 'The queue or progress did not reset, or the partial files were removed.'
  }
  '["Workshop fixture"]' | Set-Content -LiteralPath (Join-Path $data 'skipped.json') -Encoding UTF8
  $skipped = (Send-Request '/status').body | ConvertFrom-Json
  if ($skipped.failed -isnot [array] -or $skipped.failed.Count -ne 1 -or $skipped.failed[0] -ne 'Workshop fixture') {
    throw 'A single Workshop refusal must reach the dashboard as a list on the next poll.'
  }
  $verified = Send-Request "/verify?t=$($before.tok)" 'POST'
  $repairOptions = (Send-Request '/status').body | ConvertFrom-Json
  if ($verified.status -ne 200 -or $repairOptions.verify.suspects[0].id -ne 'ABCDEF0123456789') {
    throw 'Verify did not offer the incomplete download.'
  }
  $repair = Send-Request "/requeue-partial-mod?id=ABCDEF0123456789&t=$($before.tok)" 'POST'
  $repairStatus = (Send-Request '/status').body | ConvertFrom-Json
if ($repair.status -ne 200 -or $repairStatus.queue.Count -ne 1) {
  throw "Requeue: status=$($repair.status) queue=$($repairStatus.queue.Count) paused=$($repairStatus.paused) body=$($repair.body)"
  }
  '{"game":{"name":"Test","scenarioId":"fixture","mods":[{"modId":"ABCDEF0123456789","name":"Sample","version":"2.0.0"},{"modId":"0011223344556677","name":"Other"}]}}' |
    Set-Content -LiteralPath $cfg -Encoding UTF8
  '{"updates":[{"modId":"ABCDEF0123456789","version":"2.0.0"}]}' |
    Set-Content -LiteralPath (Join-Path $data 'mod-update-batch.json') -Encoding UTF8
  $updating = (Send-Request '/status').body | ConvertFrom-Json
  if (!$updating.modUpdateCancellable) { throw 'Pending updates could not be cancelled.' }
  $cancelled = Send-Request "/cancel-mod-updates?t=$($before.tok)" 'POST'
  $afterCancel = (Send-Request '/status').body | ConvertFrom-Json
  if ($cancelled.status -ne 200 -or $afterCancel.modUpdateCancellable -or
      $afterCancel.queue.Count -ne 1 -or $afterCancel.queue[0].id -ne '0011223344556677' -or
      $afterCancel.queueRevision -eq $updating.queueRevision -or !(Test-Path $partial)) {
    throw "Cancelling updates changed unrelated downloads, removed files, or left the batch active: $($cancelled.body)"
  }
  Remove-Item -LiteralPath (Join-Path $data 'paused.flag') -ErrorAction SilentlyContinue
  $shutdownInfo = [Diagnostics.ProcessStartInfo]::new()
  $shutdownInfo.FileName = $info.FileName
  $shutdownInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\download-web.ps1" -DesktopStop' -f $source
  $shutdownInfo.UseShellExecute = $false
  $shutdownInfo.CreateNoWindow = $true
  foreach ($key in 'RFMM_HOME','RFMM_DATA','USERPROFILE','RFMM_GAME_PROFILE') {
    $shutdownInfo.EnvironmentVariables[$key] = $info.EnvironmentVariables[$key]
  }
  $shutdown = [Diagnostics.Process]::Start($shutdownInfo)
  try {
    if (!$shutdown.WaitForExit(15000) -or $shutdown.ExitCode -ne 0) { throw 'Closing the desktop did not stop its engine.' }
    $onClose = (Send-Request '/status').body | ConvertFrom-Json
    if (!$onClose.paused -or $onClose.queue.Count -ne 1 -or !(Test-Path -LiteralPath $partial)) {
      throw 'Closing the desktop did not pause and preserve the queue.'
    }
  } finally { $shutdown.Dispose() }
  'Desktop transport, UTF-8 text, queue, and shutdown checks passed.'
} finally {
  $backend.StandardInput.Close()
  if (!$backend.WaitForExit(5000)) { $backend.Kill() }
  $backend.Dispose()
  [Console]::InputEncoding = $inputEncoding
}

Write-Host 'forced desktop close stops only the owned engine'
$forced = Join-Path $fixture 'forced-close'
$ownedData = Join-Path $forced 'owned'
$otherData = Join-Path $forced 'other'
New-Item -ItemType Directory -Path $ownedData,$otherData -Force | Out-Null
$ownedCfg = Join-Path $ownedData 'batch1-serverconfig.json'
$otherCfg = Join-Path $otherData 'batch1-serverconfig.json'
$queue = '{"game":{"name":"Fixture","scenarioId":"fixture","mods":[{"modId":"ABCDEF0123456789","name":"Fixture"}]}}'
Set-Content -LiteralPath $ownedCfg -Value $queue
Set-Content -LiteralPath $otherCfg -Value $queue
$token = [guid]::NewGuid().ToString('N')
@{ token = $token } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ownedData 'desktop-owner.json')
$program = Join-Path $forced 'Fixture.cs'
$mockExe = Join-Path $forced 'ArmaReforgerServer.exe'
'class Fixture { static void Main() { System.Threading.Thread.Sleep(60000); } }' | Set-Content -LiteralPath $program
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo "/out:$mockExe" $program
if ($LASTEXITCODE) { throw 'Could not build the shutdown fixture.' }

$owner = $null
$owned = $null
$other = $null
$guard = $null
try {
  $owner = Start-Process $info.FileName -ArgumentList '-NoProfile -Command "Start-Sleep 60"' -WindowStyle Hidden -PassThru
  $owned = Start-Process $mockExe -ArgumentList ('-config "{0}"' -f $ownedCfg) -WindowStyle Hidden -PassThru
  $other = Start-Process $mockExe -ArgumentList ('-config "{0}"' -f $otherCfg) -WindowStyle Hidden -PassThru
  $guardInfo = [Diagnostics.ProcessStartInfo]::new()
  $guardInfo.FileName = $info.FileName
  $guardInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\watchdog.ps1"' -f $source
  $guardInfo.UseShellExecute = $false
  $guardInfo.CreateNoWindow = $true
  $guardInfo.EnvironmentVariables['RFMM_HOME'] = $forced
  $guardInfo.EnvironmentVariables['RFMM_DATA'] = $ownedData
  $guardInfo.EnvironmentVariables['RFMM_DESKTOP_OWNER_PID'] = [string]$owner.Id
  $guardInfo.EnvironmentVariables['RFMM_DESKTOP_OWNER_TOKEN'] = $token
  $guard = [Diagnostics.Process]::Start($guardInfo)
  $owner.Kill()
  if (!$guard.WaitForExit(15000) -or $guard.ExitCode -or !$owned.WaitForExit(5000) -or $other.HasExited -or
      !(Test-Path -LiteralPath (Join-Path $ownedData 'paused.flag')) -or
      (Get-Content -LiteralPath $ownedCfg -Raw).Trim() -ne $queue) {
    throw 'Forced desktop close changed the queue or did not stop just the owned engine.'
  }
  'Forced-close watchdog check passed.'
} finally {
  foreach ($child in $guard,$owner,$owned,$other) {
    if ($child) {
      if (!$child.HasExited) { $child.Kill() }
      $child.Dispose()
    }
  }
}

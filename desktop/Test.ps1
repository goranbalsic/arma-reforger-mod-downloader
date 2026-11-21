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
  if ($page.body -notmatch 'Remove') { throw 'The dashboard did not return the expected page.' }
  $before = (Send-Request '/status').body | ConvertFrom-Json
  if ($before.queue.Count -ne 1 -or $before.totalB -ne 1048576 -or $before.running) { throw 'Unexpected initial queue.' }
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
  'Desktop transport and queue checks passed.'
} finally {
  $backend.StandardInput.Close()
  if (!$backend.WaitForExit(5000)) { $backend.Kill() }
  $backend.Dispose()
  [Console]::InputEncoding = $inputEncoding
}

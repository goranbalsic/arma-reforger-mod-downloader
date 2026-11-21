# Offline self-test for the shared state helpers. No dashboard, no game, no network.
#   powershell -File test-units.ps1      (exit 0 = pass)
# Until now the only test needed a live dashboard and an 86 GB install, so a fresh
# clone could not prove anything. This runs in a second.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\state.ps1"

$fail = 0
function Check([string]$Name, [bool]$Ok) {
  if ($Ok) { "  ok   $Name" } else { "  FAIL $Name"; $script:fail++ }
}
$tmp = Join-Path $env:TEMP "rfmm-units-$PID"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null

# --- the completion rule ---------------------------------------------------
function New-Addon([string]$Id, [string]$Variant) {
  $dir = Join-Path $tmp ("Mod_{0}" -f $Id)
  New-Item -ItemType Directory -Force $dir | Out-Null
  $pak = switch ($Variant) {
    'ok'      { 100 }
    'short'   { 90 }
    'missing' { 100 }
    default   { 100 }
  }
  [IO.File]::WriteAllText((Join-Path $dir 'data.pak'), ('x' * $pak))
  if ($Variant -ne 'missing') {
    [IO.File]::WriteAllText((Join-Path $dir 'addon.gproj'), '{}')
  }
  $files = @(
    [ordered]@{ name = 'data.pak'; size = 100 },
    [ordered]@{ name = 'addon.gproj'; size = 2 }
  )
  $meta = [ordered]@{ meta = [ordered]@{ versions = @([ordered]@{ package = [ordered]@{ files = @($files) } }) } }
  Save-Json $meta (Join-Path $dir 'meta') 6
  $dir
}
$ok = New-Addon 'AAAAAAAAAAAAAAAA' 'ok'
$short = New-Addon 'BBBBBBBBBBBBBBBB' 'short'
$gone = New-Addon 'CCCCCCCCCCCCCCCC' 'missing'
$nometa = Join-Path $tmp 'Mod_DDDDDDDDDDDDDDDD'
New-Item -ItemType Directory -Force $nometa | Out-Null

Write-Host 'completion rule (the addon meta file list)'
Check 'matching file list is complete'        (Test-AddonComplete $ok $null)
Check 'wrong file size is not complete'       (-not (Test-AddonComplete $short $null))
Check 'missing file is not complete'          (-not (Test-AddonComplete $gone $null))
Check 'no meta at all is not complete'        (-not (Test-AddonComplete $nometa $null))
Check 'cache returns the same answer'         ((Test-AddonComplete $ok $null) -eq $true)

Write-Host 'state files (atomic write, tolerant read)'
$f = Join-Path $tmp 'state.json'
Save-Json ([ordered]@{ a = 1; b = @(1, 2) }) $f
Check 'round-trips'                           ((Read-Json $f $null).a -eq 1)
Check 'no .tmp left behind'                   (-not (Test-Path "$f.tmp"))
Save-Json ([ordered]@{ a = 2 }) $f
Check 'replace overwrites'                    ((Read-Json $f $null).a -eq 2)
Set-Content $f '{"a":1,"b":' -NoNewline
$got = Read-Json $f ([pscustomobject]@{ a = -1 })
Check 'corrupt file falls back to default'    ($got.a -eq -1)
Check 'corrupt original is kept, not deleted' (@(Get-ChildItem $tmp -Filter '*.corrupt-*').Count -eq 1)
$threw = $false
try { Save-Json @{} 'notapath' } catch { $threw = $true }
Check 'a non-path is refused loudly'          $threw
Check 'missing file returns the default'      ((Read-Json (Join-Path $tmp 'nope.json') 'dflt') -eq 'dflt')

Write-Host 'engine config (the engine refuses a config without these)'
$stub = $CfgStub | ConvertFrom-Json
Check 'stub names the server'                 ([bool]$stub.game.name)
Check 'stub has a scenario'                   ([bool]$stub.game.scenarioId)
Check 'stub has a mods array'                 ($null -ne $stub.game.mods)
$repaired = Repair-Cfg ([pscustomobject]@{ game = [pscustomobject]@{ mods = @([ordered]@{ modId = 'X'; name = 'y' }) } })
Check 'repair adds name and scenario'         (([bool]$repaired.game.name) -and ([bool]$repaired.game.scenarioId))
Check 'repair keeps the queue'                (@($repaired.game.mods).Count -eq 1)
Check 'repair turns null mods into an array'  (@((Repair-Cfg ([pscustomobject]@{ game = [pscustomobject]@{ mods = $null } })).game.mods).Count -eq 0)

Write-Host 'preset writer (empty preset storage block, update in place)'
$pd = Join-Path $tmp 'preset'
New-Item -ItemType Directory -Force (Join-Path $pd 'data'), (Join-Path $pd 'addons\TestMod_0123456789ABCDEF'), (Join-Path $pd 'addons\Broken_1111222233334444') | Out-Null
[IO.File]::WriteAllText((Join-Path $pd 'addons\TestMod_0123456789ABCDEF\data.pak'), ('x' * 4))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": 4 } ] } } ] } }' |
  Set-Content (Join-Path $pd 'addons\TestMod_0123456789ABCDEF\meta')
# a second addon that is installed but incomplete: it must never reach a preset
[IO.File]::WriteAllText((Join-Path $pd 'addons\Broken_1111222233334444\data.pak'), ('x' * 2))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": 4 } ] } } ] } }' |
  Set-Content (Join-Path $pd 'addons\Broken_1111222233334444\meta')
@{ servers = @(@{ id = 'aaaaaaaa-0000-0000-0000-000000000000'; name = 'Test Server'
                  mods = @(@{ id = '0123456789ABCDEF'; name = 'Test Mod' }, @{ id = '1111222233334444'; name = 'Broken' }) }) } |
  ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pd 'data\batch1-servers.json')
$conf = Join-Path $pd 'ReforgerGameSettings.conf'
"GameUserSettings {`r`n  SCR_WorkshopAddonManagerPresetStorage SCR_WorkshopAddonManagerPresetStorage `"{6AEA4081FE80EE32}`" {`r`n  }`r`n}" |
  Set-Content $conf
$oldData = $env:RFMM_DATA
$env:RFMM_DATA = Join-Path $pd 'data'
$out1 = try { (& "$PSScriptRoot\make-preset.ps1" -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$out2 = try { (& "$PSScriptRoot\make-preset.ps1" -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
# a preset name that would unbalance the settings file must be refused BEFORE the
# write, leaving the file byte-identical (this used to write, then throw)
$beforeBad = Get-Content $conf -Raw
$out3 = try { (& "$PSScriptRoot\make-preset.ps1" -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') -Name 'Bad{Name' 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_DATA = $oldData
$presetText = Get-Content $conf -Raw
Check 'creates a preset in an empty storage block' ($out1 -match 'created')
Check 're-running updates instead of failing'     ($out2 -match 'updated')
Check 'exactly one preset after both runs'        (([regex]::Matches($presetText, 'SCR_WorkshopAddonPreset "\{')).Count -eq 1)
Check 'preset sits inside m_aPresets'             ($presetText.IndexOf('m_aPresets') -lt $presetText.IndexOf('SCR_WorkshopAddonPreset "'))
Check 'a conf-breaking preset is refused'         ($out3 -match 'verification failed')
Check 'the settings file is unchanged after it'   ((Get-Content $conf -Raw) -eq $beforeBad)
Check 'no temp file is left behind'               (-not (Test-Path "$conf.tmp"))
Check 'an incomplete addon is kept out of the preset' ($out1 -match 'in this preset: 1')
Check 'only the complete addon is written'        (([regex]::Matches($presetText, 'SCR_WorkshopAddonPresetAddonMeta')).Count -eq 1)

Write-Host 'trim: a partial that looks installed is deleted, one without markers is kept'
$td = Join-Path $tmp 'trim'
New-Item -ItemType Directory -Force (Join-Path $td 'data'), (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD'), (Join-Path $td 'serverprofile\addons\NoMark_EEEEFFFF00001111') | Out-Null
'x' | Set-Content (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD\addon.gproj')
'x' | Set-Content (Join-Path $td 'serverprofile\addons\NoMark_EEEEFFFF00001111\data.pak')
'{"game":{"name":"n","scenarioId":"s","mods":[{"modId":"AAAABBBBCCCCDDDD","name":"Half"},{"modId":"EEEEFFFF00001111","name":"NoMark"}]}}' |
  Set-Content (Join-Path $td 'data\batch1-serverconfig.json')
$oldHome = $env:RFMM_HOME
$env:RFMM_HOME = $td; $env:RFMM_DATA = Join-Path $td 'data'
try { & "$PSScriptRoot\trim-config.ps1" | Out-Null } catch { "ERROR: $_" }
$env:RFMM_HOME = $oldHome; $env:RFMM_DATA = $oldData
Check 'deletes the partial the engine would skip' (-not (Test-Path (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD')))
Check 'keeps the partial the engine re-fetches'   (Test-Path (Join-Path $td 'serverprofile\addons\NoMark_EEEEFFFF00001111'))
# a mod the DS can never finish must not be deleted and downloaded again on every
# restart: the second attempt within 30 minutes is refused
New-Item -ItemType Directory -Force (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD') | Out-Null
'x' | Set-Content (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD\addon.gproj')
$env:RFMM_HOME = $td; $env:RFMM_DATA = Join-Path $td 'data'
$tout2 = try { (& "$PSScriptRoot\trim-config.ps1" 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_HOME = $oldHome; $env:RFMM_DATA = $oldData
Check 'no second delete within 30 minutes' ((Test-Path (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD')) -and $tout2 -match 'kept a partial')

Write-Host 'completion rule (meta file list, and its cache)'
$cd = Join-Path $tmp 'complete\Add_AAAABBBBCCCCDDDD'
New-Item -ItemType Directory -Force $cd | Out-Null
[IO.File]::WriteAllText((Join-Path $cd 'data.pak'), ('x' * 10))
[IO.File]::WriteAllText((Join-Path $cd 'data001.pak'), ('y' * 20))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": 10 }, { "name": "data001.pak", "size": 20 } ] } } ] } }' |
  Set-Content (Join-Path $cd 'meta')
$cmt = (Get-Item $cd).LastWriteTime
Check 'an addon whose files match its meta is complete' (Test-AddonComplete $cd $cmt)
# the newest file does not change when an OLDER one is deleted, so the cache must
# also look at the folder's own write time
Start-Sleep -Milliseconds 60
Remove-Item (Join-Path $cd 'data001.pak')
Check 'deleting an older file invalidates the cached result' (-not (Test-AddonComplete $cd $cmt))

$md = Join-Path $tmp 'complete\Add_EEEEFFFF00001111'
New-Item -ItemType Directory -Force $md | Out-Null
'x' | Set-Content (Join-Path $md 'data.pak')
'{ "meta": { "versions": [ { "package": { } } ] } }' | Set-Content (Join-Path $md 'meta')
Check 'meta without a file list is not complete' (-not (Test-AddonComplete $md (Get-Item $md).LastWriteTime))
'{ "meta": { "versions": [ { "package": { "files": [ { "size": 5 } ] } } ] } }' | Set-Content (Join-Path $md 'meta')
Check 'meta entry without a name is not complete' (-not (Test-AddonComplete $md (Get-Item $md).LastWriteTime))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "../outside.pak", "size": 5 } ] } } ] } }' | Set-Content (Join-Path $md 'meta')
Check 'meta pointing outside the folder is not complete' (-not (Test-AddonComplete $md (Get-Item $md).LastWriteTime))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "C:\\Windows\\win.ini", "size": 5 } ] } } ] } }' | Set-Content (Join-Path $md 'meta')
Check 'meta with an absolute path is not complete' (-not (Test-AddonComplete $md (Get-Item $md).LastWriteTime))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": -5 } ] } } ] } }' | Set-Content (Join-Path $md 'meta')
Check 'meta with a negative size is not complete' (-not (Test-AddonComplete $md (Get-Item $md).LastWriteTime))

$gd = Join-Path $tmp 'complete\Add_0000111122223333'
New-Item -ItemType Directory -Force $gd | Out-Null
[IO.File]::WriteAllText((Join-Path $gd 'a.pak'), 'x')
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "a.pak", "size": 1 }, { "name": "b.pak", "size": 2 } ] } } ] } }' |
  Set-Content (Join-Path $gd 'meta')
Check 'a missing listed file is incomplete' (-not (Test-AddonComplete $gd (Get-Item (Join-Path $gd 'a.pak')).LastWriteTime))
Start-Sleep -Milliseconds 60
[IO.File]::WriteAllText((Join-Path $gd 'b.pak'), 'yy')
$newest = (Get-ChildItem $gd -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
Check 'creating the missing file makes it complete' (Test-AddonComplete $gd $newest)
Start-Sleep -Milliseconds 60
[IO.File]::WriteAllText((Join-Path $gd 'a.pak'), 'zz')
$newest2 = (Get-ChildItem $gd -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
Check 'changing a file size invalidates completion' (-not (Test-AddonComplete $gd $newest2))

Write-Host 'watchdog failure scan (resumable, no double counting)'
$logLines = @(
  'Addon Download started AAAABBBBCCCCDDDD',
  'Failed to fetch addon details',
  'Addon Download started EEEEEEEEFFFFFFFF',
  'Failed to fetch addon details'
)
$scan1 = Get-WorkshopFailures $logLines 0 $null
Check 'one refusal per mod is counted' (($scan1.counts['AAAABBBBCCCCDDDD'] -eq 1) -and ($scan1.counts['EEEEEEEEFFFFFFFF'] -eq 1))
$scan2 = Get-WorkshopFailures $logLines $scan1.next $scan1.current
Check 're-reading the same log counts nothing twice' ($scan2.counts.Count -eq 0)
$scan3 = Get-WorkshopFailures $logLines 1 'AAAABBBBCCCCDDDD'
Check 'a resumed scan still attributes the pending mod' ($scan3.counts['AAAABBBBCCCCDDDD'] -eq 1)

Write-Host 'download checksum'
$hf = Join-Path $tmp 'hash.bin'
[IO.File]::WriteAllText($hf, 'abc')
$hex = (Get-FileHash $hf -Algorithm SHA256).Hash.ToLower()
Check 'matching sha256 passes'          ((Test-Sha256 $hf "sha256:$hex") -eq $true)
Check 'different sha256 fails'          ((Test-Sha256 $hf ('sha256:' + ('0' * 64))) -eq $false)
Check 'no digest is unknown, not a pass' ($null -eq (Test-Sha256 $hf ''))

Write-Host 'addons folder migration (never delete what was not moved)'
$mg = Join-Path $tmp 'migrate'
$mp = Join-Path $mg 'profile\addons'
$game = Join-Path $mg 'game\addons'
New-Item -ItemType Directory -Force (Join-Path $mp 'Old_AAAABBBBCCCCDDDD') | Out-Null
'x' | Set-Content (Join-Path $mp 'Old_AAAABBBBCCCCDDDD\meta')
$migOk = Initialize-AddonsLink $mp $game (Join-Path $mg 'data\cfg.json')
Check 'moves old copies and links the folder' ($migOk -and (Test-Path (Join-Path $game 'Old_AAAABBBBCCCCDDDD\meta')) -and [bool](Get-Item $mp -Force).LinkType)

$mg2 = Join-Path $tmp 'migrate-locked'
$mp2 = Join-Path $mg2 'profile\addons'
$game2 = Join-Path $mg2 'game\addons'
New-Item -ItemType Directory -Force (Join-Path $mp2 'Locked_EEEEFFFF00001111') | Out-Null
'x' | Set-Content (Join-Path $mp2 'Locked_EEEEFFFF00001111\meta')
$handle = [IO.File]::Open((Join-Path $mp2 'Locked_EEEEFFFF00001111\meta'), 'Open', 'Read', 'None')
$migBad = Initialize-AddonsLink $mp2 $game2 (Join-Path $mg2 'data\cfg.json')
$handle.Close()
Check 'keeps the old folder when a move fails' ((-not $migBad) -and (Test-Path (Join-Path $mp2 'Locked_EEEEFFFF00001111\meta')))
Check 'leaves no empty copy in the game folder' (-not (Test-Path (Join-Path $game2 'Locked_EEEEFFFF00001111')))

Write-Host 'dashboard handlers (stubbed API and engine)'
$hd = Join-Path $tmp 'handlers'
New-Item -ItemType Directory -Force (Join-Path $hd 'data') | Out-Null
$Root = $hd
$Data = Join-Path $hd 'data'
$Cfg = Join-Path $Data 'batch1-serverconfig.json'
$Sizes = Join-Path $Data 'batch1-sizes.json'
$ServersPath = Join-Path $Data 'batch1-servers.json'
$Addons = Join-Path $hd 'serverprofile\addons'
$sizeMap = @{}
$serverList = @()
$script:calls = @()
. "$PSScriptRoot\dashboard-core.ps1"
function Reset-State {
  '{"game":{"name":"n","scenarioId":"s","mods":[]}}' | Set-Content $Cfg
  '{"totalBytes":0,"mods":{}}' | Set-Content $Sizes
  '{"servers":[]}' | Set-Content $ServersPath
  $script:sizeMap = @{}
  $script:serverList = @()
  $script:calls = @()
  $script:haveAt = (Get-Date).AddMinutes(-10)
}
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) @() }
function Stop-DS { $script:calls += 'stop'; 'stopped' }
function Start-DS { $script:calls += 'start'; 'started' }
function Invoke-RestMethod {
  param($Uri, $Headers, $Method, $Body, $ContentType, $TimeoutSec)
  $script:apiCalls += [string]$Uri
  if ("$Uri" -match '/mods/([0-9A-F]{16})$') {
    return [pscustomobject]@{ mod = [pscustomobject]@{ id = $Matches[1]; name = 'Mod ' + $Matches[1]; size = 10 } }
  }
  if ("$Uri" -match '/dependencies') { return [pscustomobject]@{ data = [pscustomobject]@{ dependencies = @() } } }
  return [pscustomobject]@{ data = @() }
}
function Get-Detail {
  param($Id)
  [pscustomobject]@{ name = 'Srv'; passwordProtected = $false; mods = @(
    [pscustomobject]@{ id = 'AAAABBBBCCCCDDDD'; name = 'Mod A'; size = 10; sizeKnown = $true }) }
}

Reset-State
# the config is empty on every call, so both calls see the mod as missing and the
# second call would hit the old duplicate-append path
function Get-Cfg { $CfgStub | ConvertFrom-Json }
$null = Invoke-AddServer '11111111-1111-1111-1111-111111111111'
$null = Invoke-AddServer '11111111-1111-1111-1111-111111111111'
$inMem = @($serverList).Count
$onDisk = @((Get-Content $ServersPath -Raw | ConvertFrom-Json).servers).Count
Check 'adding the same server twice keeps one entry in memory' ($inMem -eq 1)
Check 'adding the same server twice keeps one entry on disk'   ($onDisk -eq 1)
. "$PSScriptRoot\dashboard-core.ps1"   # restore the real Get-Cfg for the next blocks

Write-Host 'engine lock (a held lock is never stolen)'
$hold = Start-Job -ArgumentList $tmp -ScriptBlock {
  param($d)
  $m = [Threading.Mutex]::new($false, 'ReforgerEngineCtl')
  $null = $m.WaitOne(5000)
  New-Item -ItemType File -Force (Join-Path $d 'held.lock') | Out-Null
  Start-Sleep -Milliseconds 4000
  $m.ReleaseMutex()
}
foreach ($i in 1..50) { if (Test-Path (Join-Path $tmp 'held.lock')) { break }; Start-Sleep -Milliseconds 100 }
$blocked = Lock-Engine 400
Check 'a held engine lock returns null instead of being stolen' ($null -eq $blocked)
$null = Wait-Job $hold -Timeout 20000
Remove-Job $hold -Force -ErrorAction SilentlyContinue
$free = Lock-Engine 5000
Check 'the lock is available again after the holder exits' ($null -ne $free)
if ($free) { $free.ReleaseMutex() }

Write-Host 'engine ownership (only the engine we started)'
$none = Get-OwnEngine (Join-Path $tmp 'no-such-config.json')
Check 'no match is an empty array, not $null' (($null -ne $none) -and (@($none).Count -eq 0))
if ($null -eq $none) { '       (the WMI query failed on this machine, so the check above cannot run)' }
Check 'no config path claims no engine'       ($null -eq (Get-OwnEngine ''))

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
""
if ($fail) { "units: $fail failed"; exit 1 } else { 'units: OK' }



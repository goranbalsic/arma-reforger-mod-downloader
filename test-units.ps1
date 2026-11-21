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
Check 'storage ID survives preset creation' ($presetText -match '"\{6AEA4081FE80EE32\}"\s*\{\s*m_aPresets')
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
function Get-DS { param([switch]$Fresh) ,@() }   # comma: an empty array must not unroll to $null
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
Write-Host 'item 2: add server stops before writing the queue'
Reset-State
function Get-Detail {
  param($Id)
  [pscustomobject]@{ name = 'Srv'; passwordProtected = $false; mods = @(
    [pscustomobject]@{ id = 'AAAABBBBCCCCDDDD'; name = 'Mod A'; size = 10; sizeKnown = $true }) }
}
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) @([pscustomobject]@{ Id = 1 }) }
function Stop-DS { $script:calls += 'stop'; 'stopped' }
function Start-DS { $script:calls += 'start'; 'started' }
function Save-Json { param($obj, $Path, $Depth) $script:calls += ('save:' + [IO.Path]::GetFileName($Path)) }
$null = Invoke-AddServer '22222222-2222-2222-2222-222222222222'
$stopAt = [array]::IndexOf($script:calls, 'stop')
$cfgAt = [array]::IndexOf($script:calls, 'save:batch1-serverconfig.json')
$startAt = [array]::IndexOf($script:calls, 'start')
Check 'the engine is stopped before the queue is written' ($stopAt -ge 0 -and $cfgAt -gt $stopAt)
Check 'the engine is started after the write' ($startAt -gt $cfgAt)
Reset-State
function Get-DS { param([switch]$Fresh) $null }
$threw = $false
try { $null = Invoke-AddServer '22222222-2222-2222-2222-222222222222' } catch { $threw = $true }
Check 'an unreadable process list aborts before stop or queue write' (
  $threw -and ([array]::IndexOf($script:calls, 'stop') -lt 0) -and
  ([array]::IndexOf($script:calls, 'save:batch1-serverconfig.json') -lt 0))
. "$PSScriptRoot\dashboard-core.ps1"

Write-Host 'item 3: mod ids are validated at the API boundary'
. "$PSScriptRoot\state.ps1"   # item 2 stubbed Save-Json; restore the real one
Check 'Test-ModId returns the upper-case id' ((Test-ModId 'abcdef0123456789') -eq 'ABCDEF0123456789')
Check 'Test-ModId rejects a wildcard' ($null -eq (Test-ModId '*'))
Check 'Test-ModId rejects path traversal' ($null -eq (Test-ModId '..\x'))
Check 'Test-ModId rejects a short id' ($null -eq (Test-ModId 'ABCD'))
Reset-State
$sz = '{"totalBytes":0,"mods":{}}' | ConvertFrom-Json
$sv = [pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999'; name = 'S'; mods = @() }
Merge-ServerMods $sv @(
  [pscustomobject]@{ id = '*'; name = 'bad'; size = 1; sizeKnown = $true },
  [pscustomobject]@{ id = '..\x'; name = 'bad2'; size = 1; sizeKnown = $true },
  [pscustomobject]@{ id = 'abcdef0123456789'; name = 'ok'; size = 2; sizeKnown = $true }
) $sz
Check 'Merge keeps only the valid id' (@($sv.mods).Count -eq 1 -and $sv.mods[0].id -eq 'ABCDEF0123456789')
Check 'invalid ids never reach the size map' ((-not $sizeMap.ContainsKey('*')) -and (-not $sizeMap.ContainsKey('..\x')))
function Get-Detail {
  param($Id)
  [pscustomobject]@{ name = 'S'; passwordProtected = $false; mods = @(
    [pscustomobject]@{ id = '*'; name = 'bad'; size = 1; sizeKnown = $true },
    [pscustomobject]@{ id = 'ABCDEF0123456789'; name = 'ok'; size = 2; sizeKnown = $true }) }
}
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) ,@() }
function Stop-DS { 'stopped' }
function Start-DS { 'started' }
Reset-State
$null = Invoke-AddServer '33333333-3333-3333-3333-333333333333'
Check 'Add server drops an invalid mod id' (@($serverList[0].mods).Count -eq 1 -and $serverList[0].mods[0].id -eq 'ABCDEF0123456789')
Check 'the queue holds only the valid id' (@((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods).Count -eq 1)
. "$PSScriptRoot\dashboard-core.ps1"

$td2 = Join-Path $tmp 'trim-ids'
New-Item -ItemType Directory -Force (Join-Path $td2 'data'), (Join-Path $td2 'serverprofile\addons') | Out-Null
'{"game":{"name":"n","scenarioId":"s","mods":[{"modId":"*","name":"bad"}]}}' | Set-Content (Join-Path $td2 'data\batch1-serverconfig.json')
$env:RFMM_HOME = $td2; $env:RFMM_DATA = Join-Path $td2 'data'
$trimIds = try { (& "$PSScriptRoot\trim-config.ps1" 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_HOME = $oldHome; $env:RFMM_DATA = $oldData
Check 'trim skips an invalid queued id' ($trimIds -match 'invalid mod id')

Write-Host 'item 4: an unreadable queue is not an empty queue'
$q1 = Join-Path $tmp 'queue-ok.json'
'{"game":{"name":"n","scenarioId":"s","mods":[{"modId":"ABCDEF0123456789","name":"m"}]}}' | Set-Content $q1
$got = Get-Queued $q1
Check 'a readable queue returns its mods' (@($got).Count -eq 1)
'{"game":{"name":"n","scenarioId":"s","mods":[]}}' | Set-Content $q1
$gotEmpty = Get-Queued $q1
Check 'a readable empty queue is an empty array' ($null -ne $gotEmpty -and @($gotEmpty).Count -eq 0)
'{"game":{"name":"n","scenarioId":"s","mods":null}}' | Set-Content $q1
$gotNull = Get-Queued $q1
Check 'mods null is an empty array, not a failure' ($null -ne $gotNull -and @($gotNull).Count -eq 0)
'not json at all' | Set-Content $q1
Check 'malformed json returns null' ($null -eq (Get-Queued $q1))
$q2 = Join-Path $tmp 'queue-locked.json'
'{"game":{"name":"n","scenarioId":"s","mods":[]}}' | Set-Content $q2
$qh = [IO.File]::Open($q2, 'Open', 'Read', 'None')
$locked = Get-Queued $q2
$qh.Close()
Check 'an unreadable file returns null' ($null -eq $locked)

Write-Host 'item 5: corrupt state and legal dot names'
$dots = Join-Path $tmp 'dots\Add_0A0B0C0D0E0F0102'
New-Item -ItemType Directory -Force $dots | Out-Null
[IO.File]::WriteAllText((Join-Path $dots 'a..b.pak'), 'abc')
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "a..b.pak", "size": 3 } ] } } ] } }' | Set-Content (Join-Path $dots 'meta')
Check 'a name like a..b.pak is a legal file' (Test-AddonComplete $dots (Get-Item $dots).LastWriteTime)
$esc = Join-Path $tmp 'dots\Add_0A0B0C0D0E0F0304'
New-Item -ItemType Directory -Force $esc | Out-Null
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "..\\outside.pak", "size": 3 } ] } } ] } }' | Set-Content (Join-Path $esc 'meta')
Check 'a .. segment is still rejected' (-not (Test-AddonComplete $esc (Get-Item $esc).LastWriteTime))

'not json' | Set-Content (Join-Path $Data 'skipped.json')
$script:skippedAt = (Get-Date).AddMinutes(-10)
$skipped = try { @(Get-SkippedNames) } catch { 'THREW' }
Check 'a corrupt skipped.json does not break /status' ($skipped -notcontains 'THREW')

Reset-State
Remove-Item $Sizes -Force -ErrorAction SilentlyContinue
function Get-Detail {
  param($Id)
  [pscustomobject]@{ name = 'S'; passwordProtected = $false; mods = @(
    [pscustomobject]@{ id = 'ABCDEF0123456789'; name = 'ok'; size = 10; sizeKnown = $true }) }
}
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) ,@() }
function Stop-DS { 'stopped' }
function Start-DS { 'started' }
$szErr = $null
try { $null = Invoke-AddServer '44444444-4444-4444-4444-444444444444' } catch { $szErr = $_ }
$szNow = if (Test-Path $Sizes) { Get-Content $Sizes -Raw | ConvertFrom-Json } else { $null }
Check 'a missing sizes file does not break add server' ($null -eq $szErr)
Check 'the size of the new mod is recorded' ($szNow -and $szNow.mods.ABCDEF0123456789.bytes -eq 10)
. "$PSScriptRoot\dashboard-core.ps1"

Write-Host 'item 6: config updates are serialised'
Reset-State
$uout = Update-Cfg { param($cfg) $cfg.game.mods = @([pscustomobject]@{ modId = 'ABCDEF0123456789'; name = 'x' }); 'done' } $Cfg
$usaved = Get-Content $Cfg -Raw | ConvertFrom-Json
Check 'Update-Cfg saves the change' (@($usaved.game.mods).Count -eq 1)
Check 'Update-Cfg returns the block output' ($uout -eq 'done')

$hold2 = Start-Job -ArgumentList $tmp -ScriptBlock {
  param($d)
  $m = [Threading.Mutex]::new($false, 'ReforgerEngineCtl')
  $null = $m.WaitOne(5000)
  New-Item -ItemType File -Force (Join-Path $d 'held2.lock') | Out-Null
  Start-Sleep -Milliseconds 3000
  $m.ReleaseMutex()
}
foreach ($i in 1..50) { if (Test-Path (Join-Path $tmp 'held2.lock')) { break }; Start-Sleep -Milliseconds 100 }
$beforeCfg = Get-Content $Cfg -Raw
$uerr = $null
try { Update-Cfg { param($cfg) $cfg.game.mods = @() } $Cfg 300 | Out-Null } catch { $uerr = $_ }
Check 'Update-Cfg refuses while another process holds the lock' ($null -ne $uerr)
Check 'Update-Cfg wrote nothing without the lock' ((Get-Content $Cfg -Raw) -eq $beforeCfg)
$null = Wait-Job $hold2 -Timeout 20000
Remove-Job $hold2 -Force -ErrorAction SilentlyContinue

Write-Host 'item 8: the dependency crawl is bounded'
Reset-State
function Get-Detail { param($Id) [pscustomobject]@{ name = 'S'; passwordProtected = $false; mods = @() } }
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) ,@() }
function Stop-DS { 'stopped' }
function Start-DS { 'started' }
function Get-ModDeps { param($Id) @(1..300 | ForEach-Object { [pscustomobject]@{ id = ('{0:X16}' -f $_); name = "dep$_"; size = 1 } }) }
$amsg = Invoke-AddMod 'ABCDEF0123456789'
$queuedNow = @((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods)
Check 'the crawl stops at the 200 mod cap' ($queuedNow.Count -le 200 -and $queuedNow.Count -ge 2)
Check 'the message says the dependency walk was cut' ($amsg -match 'limit')
. "$PSScriptRoot\dashboard-core.ps1"
. "$PSScriptRoot\state.ps1"

Write-Host 'item 10: handler behaviour'
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) ,@() }
function Stop-DS { 'stopped' }
function Start-DS { 'started' }
function Invoke-RestMethod { param($Uri, $Headers, $Method, $Body, $ContentType, $TimeoutSec)
  if ("$Uri" -match '/mods/([0-9A-Fa-f]{16})$') { return [pscustomobject]@{ mod = [pscustomobject]@{ id = $Matches[1].ToUpper(); name = 'Mod'; size = 10 } } }
  return [pscustomobject]@{ data = @() } }
function Get-ModDeps { param($Id) @() }

Reset-State
$null = Invoke-AddMod 'ABCDEF0123456789'
Check 'add mod queues the mod once' (@((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods).Count -eq 1)
$again = Invoke-AddMod 'ABCDEF0123456789'
Check 'add mod short-circuits when already queued' ($again -match 'already queued')

Reset-State
function Get-HaveIds { @{ 'ABCDEF0123456789' = $true } }
$inst = Invoke-AddMod 'ABCDEF0123456789'
Check 'add mod short-circuits when already installed' ($inst -match 'already installed')

Reset-State
function Get-Detail { param($Id) [pscustomobject]@{ name = 'S'; passwordProtected = $false; mods = @(
  [pscustomobject]@{ id = 'ABCDEF0123456789'; name = 'M'; size = 10; sizeKnown = $true }) } }
$srvInst = Invoke-AddServer '55555555-5555-5555-5555-555555555555'
Check 'add server still lists a server whose mods are installed' ($srvInst -match 'is in the list' -and @($serverList).Count -eq 1)
Check 'that server added nothing to the queue' (@((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods).Count -eq 0)

Reset-State
$script:serverList = @([pscustomobject]@{ id = '66666666-6666-6666-6666-666666666666'; name = 'S'; mods = @(
  [pscustomobject]@{ id = '0000000000000010'; name = 'm1'; e = 1 },
  [pscustomobject]@{ id = '0000000000000011'; name = 'm2'; e = 1 }) })
$script:sizeMap = @{ '0000000000000010' = @{ name = 'm1'; bytes = 1 }; '0000000000000011' = @{ name = 'm2'; bytes = 1 }; '0000000000000012' = @{ name = 'm3'; bytes = 1 } }
function Get-HaveIds { @{ '0000000000000011' = $true } }
$null = Invoke-QueueServer '66666666-6666-6666-6666-666666666666'
$qmods = @((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods)
Check 'queue first puts the missing server mods first, then the rest' ($qmods.Count -eq 2 -and $qmods[0].modId -eq '0000000000000010' -and $qmods[1].modId -eq '0000000000000012')

Reset-State
function Get-HaveIds { @{} }
$null = Invoke-AddMod 'ABCDEF0123456789'
$cmsg = Invoke-ClearQueue
Check 'clear queue empties it' (@((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods).Count -eq 0 -and $cmsg -match 'queue cleared')

Reset-State
$script:sizeMap = @{}
$want = [ordered]@{ '0000000000000020' = 'a'; '0000000000000021' = 'b' }
Update-Cfg { param($cfg) $cfg.game.mods = @([pscustomobject]@{ modId = '0000000000000021'; name = 'b' }) } $Cfg | Out-Null
$qres = Add-MissingToQueue $want
$qafter = @((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods)
Check 'add missing queues only what is missing' ($qres.count -eq 1 -and $qafter.Count -eq 2)

Reset-State
$depIds = @{ 'ABCDEF0123456789' = '0000000000000001'; '0000000000000001' = '0000000000000002'; '0000000000000002' = '0000000000000003'; '0000000000000003' = '0000000000000004' }
function Get-ModDeps { param($Id) if ($depIds.ContainsKey($Id)) { @([pscustomobject]@{ id = $depIds[$Id]; name = 'd'; size = 1 }) } else { @() } }
$null = Invoke-AddMod 'ABCDEF0123456789'
$depthMods = @((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods | ForEach-Object { $_.modId })
Check 'the dependency depth cap stops at three levels' ($depthMods.Count -eq 4 -and $depthMods -notcontains '0000000000000004')
. "$PSScriptRoot\dashboard-core.ps1"
. "$PSScriptRoot\state.ps1"

Write-Host 'item 13: braces in a mod name do not block the preset'
$bd = Join-Path $tmp 'preset-braces'
New-Item -ItemType Directory -Force (Join-Path $bd 'data'), (Join-Path $bd 'addons\Foo {Bar_AAAABBBBCCCCDDDD'), (Join-Path $bd 'addons\Baz}Qux_EEEEFFFF00001111') | Out-Null
[IO.File]::WriteAllText((Join-Path $bd 'addons\Foo {Bar_AAAABBBBCCCCDDDD\data.pak'), 'abc')
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": 3 } ] } } ] } }' | Set-Content (Join-Path $bd 'addons\Foo {Bar_AAAABBBBCCCCDDDD\meta')
[IO.File]::WriteAllText((Join-Path $bd 'addons\Baz}Qux_EEEEFFFF00001111\data.pak'), 'abcd')
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": 4 } ] } } ] } }' | Set-Content (Join-Path $bd 'addons\Baz}Qux_EEEEFFFF00001111\meta')
@{ servers = @(@{ id = 'bbbbbbbb-0000-0000-0000-000000000000'; name = 'Brace Server'; mods = @(
  @{ id = 'AAAABBBBCCCCDDDD'; name = 'Foo {Bar' }, @{ id = 'EEEEFFFF00001111'; name = 'Baz}Qux' }) }) } |
  ConvertTo-Json -Depth 5 | Set-Content (Join-Path $bd 'data\batch1-servers.json')
$bconf = Join-Path $bd 'ReforgerGameSettings.conf'
"GameUserSettings {`r`n  SCR_WorkshopAddonManagerPresetStorage SCR_WorkshopAddonManagerPresetStorage `"{6AEA4081FE80EE32}`" {`r`n  }`r`n}" | Set-Content $bconf
$env:RFMM_DATA = Join-Path $bd 'data'
$bout = try { (& "$PSScriptRoot\make-preset.ps1" -ServerId 'bbbbbbbb-0000-0000-0000-000000000000' -ConfPath $bconf -AddonsDir (Join-Path $bd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_DATA = $oldData
$btext = Get-Content $bconf -Raw
Check 'a mod name with braces creates the preset' ($bout -match 'OK - preset')
Check 'the braces are replaced in the conf' ($btext -match 'm_sName "Foo \(Bar"' -and $btext -match 'm_sName "Baz\)Qux"')
Check 'the brace count still verifies' ($bout -match 'braces=[0-9]+/[0-9]+')

Write-Host 'item 11: the stop script targets only this folder''s helpers'
$sr = Join-Path $tmp 'stoplab'
New-Item -ItemType Directory -Force $sr | Out-Null
$p1 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 30 # $sr\watchdog.ps1" -PassThru -WindowStyle Hidden
$p2 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 30 # $sr\sync-addons.ps1" -PassThru -WindowStyle Hidden
$p3 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 30 # $sr\other.ps1" -PassThru -WindowStyle Hidden
Start-Sleep 2
$stopOut = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\stop.ps1" -Root $sr 2>&1
Start-Sleep 1
Check 'the watchdog of that folder is stopped' (-not (Get-Process -Id $p1.Id -ErrorAction SilentlyContinue))
Check 'the addon mirror of that folder is stopped' (-not (Get-Process -Id $p2.Id -ErrorAction SilentlyContinue))
Check 'an unrelated process is left alone' ([bool](Get-Process -Id $p3.Id -ErrorAction SilentlyContinue))
foreach ($pp in @($p1, $p2, $p3)) { Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue }

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



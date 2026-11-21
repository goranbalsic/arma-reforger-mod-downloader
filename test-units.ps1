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
New-Item -ItemType Directory -Force (Join-Path $pd 'data'), (Join-Path $pd 'addons\TestMod_0123456789ABCDEF') | Out-Null
[IO.File]::WriteAllText((Join-Path $pd 'addons\TestMod_0123456789ABCDEF\data.pak'), ('x' * 4))
'{ "meta": { "versions": [ { "package": { "files": [ { "name": "data.pak", "size": 4 } ] } } ] } }' |
  Set-Content (Join-Path $pd 'addons\TestMod_0123456789ABCDEF\meta')
@{ servers = @(@{ id = 'aaaaaaaa-0000-0000-0000-000000000000'; name = 'Test Server'
                  mods = @(@{ id = '0123456789ABCDEF'; name = 'Test Mod' }) }) } |
  ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pd 'data\batch1-servers.json')
$conf = Join-Path $pd 'ReforgerGameSettings.conf'
"GameUserSettings {`r`n  SCR_WorkshopAddonManagerPresetStorage SCR_WorkshopAddonManagerPresetStorage `"{6AEA4081FE80EE32}`" {`r`n  }`r`n}" |
  Set-Content $conf
$oldData = $env:RFMM_DATA
$env:RFMM_DATA = Join-Path $pd 'data'
$out1 = try { (& "$PSScriptRoot\make-preset.ps1" -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$out2 = try { (& "$PSScriptRoot\make-preset.ps1" -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_DATA = $oldData
$presetText = Get-Content $conf -Raw
Check 'creates a preset in an empty storage block' ($out1 -match 'created')
Check 're-running updates instead of failing'     ($out2 -match 'updated')
Check 'exactly one preset after both runs'        (([regex]::Matches($presetText, 'SCR_WorkshopAddonPreset "\{')).Count -eq 1)
Check 'preset sits inside m_aPresets'             ($presetText.IndexOf('m_aPresets') -lt $presetText.IndexOf('SCR_WorkshopAddonPreset "'))

Write-Host 'trim: a partial that looks installed is deleted, one without markers is kept'
$td = Join-Path $tmp 'trim'
New-Item -ItemType Directory -Force (Join-Path $td 'data'), (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD'), (Join-Path $td 'serverprofile\addons\NoMark_EEEEFFFF00001111') | Out-Null
'x' | Set-Content (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD\addon.gproj')
'x' | Set-Content (Join-Path $td 'serverprofile\addons\NoMark_EEEEFFFF00001111\data.pak')
'{"game":{"name":"n","scenarioId":"s","mods":[{"modId":"AAAABBBBCCCCDDDD","name":"Half"},{"modId":"EEEEFFFF00001111","name":"NoMark"}]}}' |
  Set-Content (Join-Path $td 'data\batch1-serverconfig.json')
$oldHome = $env:RFMM_HOME
$env:RFMM_HOME = $td; $env:RFMM_DATA = Join-Path $td 'data'
$tout = try { (& "$PSScriptRoot\trim-config.ps1" 2>&1) -join ' ' } catch { "ERROR: $_" }
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

Write-Host 'engine ownership (only the engine we started)'
$none = Get-OwnEngine (Join-Path $tmp 'no-such-config.json')
Check 'no match is an empty array, not $null' (($null -ne $none) -and (@($none).Count -eq 0))
if ($null -eq $none) { '       (the WMI query failed on this machine, so the check above cannot run)' }
Check 'no config path claims no engine'       ($null -eq (Get-OwnEngine ''))

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
""
if ($fail) { "units: $fail failed"; exit 1 } else { 'units: OK' }



# Offline self-test for the shared state helpers. No dashboard, no game, no network.
#   powershell -File test-units.ps1      (exit 0 = pass)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'state.ps1')

$fail = 0
function Check([string]$Name, [bool]$Ok) {
  if ($Ok) { "  ok   $Name" } else { "  FAIL $Name"; $script:fail++ }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) "rfmm-units-$PID"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null

Write-Host 'PowerShell state paths'
$interpolatedPaths = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.ps1' |
  Where-Object { $_.FullName -notmatch '[/\\](?:\.desktop-build|dist|data|serverprofile|steamcmd|armar-server)[/\\]' } |
  ForEach-Object {
    $tokens = $parseErrors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    $tree.FindAll({
      param($node)
      $node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and
        $node.Extent.Text -match '\$(?:\{[A-Za-z_][\w:]*\}|[A-Za-z_][\w:]*)\\(?=[A-Za-z_.])'
    }, $true)
  })
foreach ($finding in $interpolatedPaths) {
  Write-Host ("{0}:{1}: use Join-Path for this path" -f $finding.Extent.File, $finding.Extent.StartLineNumber)
}
Check 'scripts use portable path construction' ($interpolatedPaths.Count -eq 0)

Write-Host 'project repository identity'
$retiredOwner = 'goran' + 'balsic'
$retiredReferences = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
  Where-Object {
    $_.FullName -notmatch '[/\\](?:\.desktop-build|dist|data|serverprofile|steamcmd|armar-server)[/\\]' -and
      ($_.Extension -in '.cs','.ps1','.py','.yml','.sh','.json','.md','.txt','.html','.cmd' -or
        $_.Name -in 'LICENSE','NOTICE','ReforgerModDownloader')
  } |
  Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch $retiredOwner -Quiet })
foreach ($finding in $retiredReferences) { Write-Host "$($finding.FullName) uses the retired repository owner." }
Check 'source and docs use the canonical repository owner' ($retiredReferences.Count -eq 0)

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
Check 'generated engine settings are loopback-only and hidden' ($stub.bindAddress -eq '127.0.0.1' -and $stub.game.visible -eq $false -and $stub.game.maxPlayers -eq 1)
$repaired = Repair-Cfg ([pscustomobject]@{ game = [pscustomobject]@{ mods = @([ordered]@{ modId = 'X'; name = 'y' }) } })
Check 'repair adds name and scenario'         (([bool]$repaired.game.name) -and ([bool]$repaired.game.scenarioId))
Check 'repair keeps the queue'                (@($repaired.game.mods).Count -eq 1)
Check 'legacy queue configs receive the same local-only defaults' ($repaired.bindAddress -eq '127.0.0.1' -and $repaired.game.visible -eq $false -and $repaired.game.maxPlayers -eq 1)
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
$out1 = try { (& (Join-Path $PSScriptRoot 'make-preset.ps1') -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$out2 = try { (& (Join-Path $PSScriptRoot 'make-preset.ps1') -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$presetText = Get-Content $conf -Raw
Check 'storage ID survives preset creation' ($presetText -match '"\{6AEA4081FE80EE32\}"\s*\{\s*m_aPresets')
Check 'creates a preset in an empty storage block' ($out1 -match 'created')
Check 're-running updates instead of failing'     ($out2 -match 'updated')
Check 'exactly one preset after both runs'        (([regex]::Matches($presetText, 'SCR_WorkshopAddonPreset "\{')).Count -eq 1)
Check 'preset sits inside m_aPresets'             ($presetText.IndexOf('m_aPresets') -lt $presetText.IndexOf('SCR_WorkshopAddonPreset "'))
Set-Content -LiteralPath $conf ($presetText.Replace('m_sName "Test Server"', 'm_sName "My{Server"'))
$serverFile = Join-Path $env:RFMM_DATA 'batch1-servers.json'
$presetServers = Read-Json $serverFile $null
$presetServers.servers[0].name = 'My{Server'
Save-Json $presetServers $serverFile
$out3 = try { (& (Join-Path $PSScriptRoot 'make-preset.ps1') -ServerId 'aaaaaaaa-0000-0000-0000-000000000000' -ConfPath $conf -AddonsDir (Join-Path $pd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_DATA = $oldData
$updatedPreset = Get-Content $conf -Raw
Check 'updates an existing preset whose server name contains a brace' ($out3 -match 'updated' -and $updatedPreset.Contains('m_sName "My(Server"'))
Check 'a quoted brace leaves exactly one preset' (([regex]::Matches($updatedPreset, 'SCR_WorkshopAddonPreset "\{')).Count -eq 1)
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
try { & (Join-Path $PSScriptRoot 'trim-config.ps1') | Out-Null } catch { "ERROR: $_" }
$env:RFMM_HOME = $oldHome; $env:RFMM_DATA = $oldData
Check 'deletes the partial the engine would skip' (-not (Test-Path (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD')))
Check 'keeps the partial the engine re-fetches'   (Test-Path (Join-Path $td 'serverprofile\addons\NoMark_EEEEFFFF00001111'))
# a mod the DS can never finish must not be deleted and downloaded again on every
# restart: the second attempt within 30 minutes is refused
New-Item -ItemType Directory -Force (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD') | Out-Null
'x' | Set-Content (Join-Path $td 'serverprofile\addons\Half_AAAABBBBCCCCDDDD\addon.gproj')
$env:RFMM_HOME = $td; $env:RFMM_DATA = Join-Path $td 'data'
$tout2 = try { (& (Join-Path $PSScriptRoot 'trim-config.ps1') 2>&1) -join ' ' } catch { "ERROR: $_" }
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
if ($IsLinux) {
  '  SKIP (windows only) moves old copies and links the folder'
  '  SKIP (windows only) keeps the old folder when a move fails'
  '  SKIP (windows only) leaves no empty copy in the game folder'
} else {
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
}

Write-Host 'downloads without a game profile'
$standalone = Join-Path $tmp 'standalone'
$standaloneProfile = Join-Path $standalone 'serverprofile'
$standaloneAddons = Join-Path $standaloneProfile 'addons'
$standaloneData = Join-Path $standalone 'data'
$removedGame = Join-Path $standalone 'removed-game'
$formerAddons = Join-Path $removedGame 'addons'
New-Item -ItemType Directory -Path $standaloneProfile,$standaloneData,$formerAddons -Force | Out-Null
$linkType = if ($IsLinux) { 'SymbolicLink' } else { 'Junction' }
New-Item -ItemType $linkType -Path $standaloneAddons -Target $formerAddons | Out-Null
[IO.Directory]::Delete($formerAddons)
[IO.Directory]::Delete($removedGame)
$standaloneCfg = Join-Path $standaloneData 'batch1-serverconfig.json'
'{"game":{"name":"Test","scenarioId":"fixture","mods":[{"modId":"ABCDEF0123456789","name":"Pending"}]}}' |
  Set-Content -LiteralPath $standaloneCfg -Encoding UTF8
$oldHome = $env:RFMM_HOME; $oldData = $env:RFMM_DATA; $oldProfile = $env:RFMM_GAME_PROFILE
try {
  $env:RFMM_HOME = $standalone; $env:RFMM_DATA = $standaloneData; $env:RFMM_GAME_PROFILE = $removedGame
  Check 'a missing game profile uses downloader storage' ((Get-ClientAddons $standaloneProfile) -eq $standaloneAddons)
  & (Join-Path $PSScriptRoot 'trim-config.ps1') | Out-Null
  $localAddons = Get-Item -LiteralPath $standaloneAddons -Force
  Check 'start preparation replaces a dangling addons link with a local folder' ($LASTEXITCODE -eq 0 -and $localAddons.PSIsContainer -and !$localAddons.LinkType)
  Check 'recovering the addons folder keeps the queued mod and leaves the game profile absent' (
    (Get-Queued $standaloneCfg)[0].modId -eq 'ABCDEF0123456789' -and !(Test-Path -LiteralPath $removedGame))
  if (!$IsLinux) {
    $modName = 'Restored_ABCDEF0123456789'
    $privateMod = Join-Path $standaloneAddons $modName
    $privateSaves = Join-Path $standaloneAddons 'saves'
    New-Item -ItemType Directory -Path $privateMod,$privateSaves -Force | Out-Null
    'mod files' | Set-Content -LiteralPath (Join-Path $privateMod 'data.pak')
    'preserve local saves' | Set-Content -LiteralPath (Join-Path $privateSaves 'pending.txt')
    & (Join-Path $PSScriptRoot 'sync-addons.ps1')
    Check 'sync retains the mod locally while the game profile is absent' (
      $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $privateMod) -and !(Test-Path -LiteralPath $removedGame))
    New-Item -ItemType Directory -Path (Join-Path $formerAddons 'saves') -Force | Out-Null
    & (Join-Path $PSScriptRoot 'sync-addons.ps1')
    $syncCode = $LASTEXITCODE
    $preserved = @(Get-ChildItem -LiteralPath $standaloneProfile -Directory -Filter 'addons-before-link-*')
    Check 'sync moves private mods into the restored game folder and links the engine' (
      $syncCode -eq 0 -and (Get-Item -LiteralPath $standaloneAddons -Force).LinkType -eq 'Junction' -and
      (Test-Path -LiteralPath (Join-Path (Join-Path $formerAddons $modName) 'data.pak')) -and
      @(Get-ChildItem -LiteralPath $formerAddons -Directory -Filter '*_ABCDEF0123456789').Count -eq 1)
    Check 'sync preserves unrelated downloader files outside the linked folder' (
      $preserved.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $preserved[0].FullName 'saves/pending.txt')) -and
      @(Get-ChildItem -LiteralPath $preserved[0].FullName -Directory -Filter '*_ABCDEF0123456789').Count -eq 0)

    $duplicateAddons = Join-Path $standalone 'duplicate-profile/addons'
    $existingMod = Join-Path $formerAddons 'GameName_AAAABBBB00001111'
    $duplicateMod = Join-Path $duplicateAddons 'OtherName_AAAABBBB00001111'
    New-Item -ItemType Directory -Path $existingMod,$duplicateMod -Force | Out-Null
    Check 'migration never creates a second game folder for the same Workshop ID' (
      !(Initialize-AddonsLink $duplicateAddons $formerAddons $standaloneCfg) -and
      (Test-Path -LiteralPath $duplicateMod) -and @(Get-ChildItem -LiteralPath $formerAddons -Directory -Filter '*_AAAABBBB00001111').Count -eq 1)
  }
} finally {
  $env:RFMM_HOME = $oldHome; $env:RFMM_DATA = $oldData; $env:RFMM_GAME_PROFILE = $oldProfile
}

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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')
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
function Invoke-WorkshopApi {
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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')   # restore the real Get-Cfg for the next blocks
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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')

Write-Host 'item 3: mod ids are validated at the API boundary'
. (Join-Path $PSScriptRoot 'state.ps1')   # item 2 stubbed Save-Json; restore the real one
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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')

$td2 = Join-Path $tmp 'trim-ids'
New-Item -ItemType Directory -Force (Join-Path $td2 'data'), (Join-Path $td2 'serverprofile\addons') | Out-Null
'{"game":{"name":"n","scenarioId":"s","mods":[{"modId":"*","name":"bad"}]}}' | Set-Content (Join-Path $td2 'data\batch1-serverconfig.json')
$env:RFMM_HOME = $td2; $env:RFMM_DATA = Join-Path $td2 'data'
$trimIds = try { (& (Join-Path $PSScriptRoot 'trim-config.ps1') 2>&1) -join ' ' } catch { "ERROR: $_" }
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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')

Write-Host 'item 6: config updates are serialised'
Reset-State
$uout = Update-Cfg { param($cfg) $cfg.game.mods = @([pscustomobject]@{ modId = 'ABCDEF0123456789'; name = 'x' }); 'done' } $Cfg
$usaved = Get-Content $Cfg -Raw | ConvertFrom-Json
Check 'Update-Cfg saves the change' (@($usaved.game.mods).Count -eq 1)
Check 'Update-Cfg returns the block output' ($uout -eq 'done')
$malformedCfg = Join-Path $tmp 'malformed-engine.json'
'{"game":' | Set-Content -LiteralPath $malformedCfg
$malformedBefore = Get-Content -LiteralPath $malformedCfg -Raw
$writeError = $null
try { Update-Cfg { param($cfg) $cfg.game.mods = @() } $malformedCfg | Out-Null } catch { $writeError = $_ }
Check 'a queue mutation preserves a malformed config' ($writeError -and (Get-Content -LiteralPath $malformedCfg -Raw) -eq $malformedBefore)
Check 'an exact config argument identifies the engine' (Test-EngineCommandLine '"ArmaReforgerServer.exe" -config "C:/My Mods/queue.json"' 'C:/My Mods/queue.json')
Check 'another engine with a similarly named config is ignored' (!(Test-EngineCommandLine '"ArmaReforgerServer.exe" -config "C:/My Mods/queue.json.bak"' 'C:/My Mods/queue.json'))
Check 'the config path in an unrelated argument is ignored' (!(Test-EngineCommandLine '"ArmaReforgerServer.exe" -profile "C:/My Mods/queue.json"' 'C:/My Mods/queue.json'))

$stateScript = Join-Path $PSScriptRoot 'state.ps1'
$hold2 = Start-Job -ArgumentList $tmp,$stateScript -ScriptBlock {
  param($d,$state)
  . $state
  $m = Lock-Engine 5000
  if (!$m) { throw 'Could not acquire the fixture lock.' }
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

Write-Host 'UTF-8 Workshop responses'
& {
  . (Join-Path $PSScriptRoot 'workshop-api.ps1')
  $name = ([string][char]0x65E5) + [char]0x672C + ' ' + [char]0x00D7
  $bytes = [Text.Encoding]::UTF8.GetBytes(('{"name":"' + $name + '"}'))
  $fixture = [IO.MemoryStream]::new($bytes)
  try {
    $reply = Read-WorkshopJson $fixture 512 ([Threading.CancellationToken]::None)
    Check 'server names preserve their UTF-8 characters' ($reply.name -ceq $name)
    $fixture.Position = 0
    $rejected = $false
    try { $null = Read-WorkshopJson $fixture 8 ([Threading.CancellationToken]::None) }
    catch { $rejected = $_.Exception.Message -match 'too large' }
    Check 'streaming Workshop reads enforce the decoded size limit' $rejected
  } finally { $fixture.Dispose() }
  $rejected = $false
  try { $null = Get-WorkshopUri 'http://example.invalid/' } catch { $rejected = $true }
  Check 'public Workshop URLs require HTTPS' $rejected
  Check 'a numeric pre-release suffix compares numerically' ((Compare-WorkshopVersion 'v1.2.3-beta.10' '1.2.3-beta.2') -gt 0)
  Check 'a stable version sorts after its pre-release' ((Compare-WorkshopVersion '1.2.3' '1.2.3-rc.1') -gt 0)
  Check 'build metadata does not change version precedence' ((Compare-WorkshopVersion '1.2.3+build.2' '1.2.3+build.1') -eq 0)
}

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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')
. (Join-Path $PSScriptRoot 'state.ps1')

Write-Host 'item 10: handler behaviour'
function Get-HaveIds { @{} }
function Get-DS { param([switch]$Fresh) ,@() }
function Stop-DS { 'stopped' }
function Start-DS { 'started' }
function Invoke-WorkshopApi { param($Uri, $Headers, $Method, $Body, $ContentType, $TimeoutSec)
  if ("$Uri" -match '/mods/([0-9A-Fa-f]{16})$') { return [pscustomobject]@{ mod = [pscustomobject]@{ id = $Matches[1].ToUpper(); name = 'Mod'; size = 10 } } }
  return [pscustomobject]@{ data = @() } }
function Get-ModDeps { param($Id) @() }

Reset-State
$null = Invoke-AddMod 'ABCDEF0123456789'
Check 'add mod queues the mod once' (@((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods).Count -eq 1)
$again = Invoke-AddMod 'ABCDEF0123456789'
Check 'add mod short-circuits when already queued' ($again -match 'already queued')

function Get-DS { param([switch]$Fresh) ,@('running engine') }
$script:duplicateStops = 0
function Stop-DS { $script:duplicateStops++ }
$duplicate = Add-QueuedMods @([pscustomobject]@{ modId = 'ABCDEF0123456789'; name = 'Mod' })
Check 'adding a queued mod keeps the active engine running' ($duplicate.count -eq 0 -and $script:duplicateStops -eq 0)
function Get-DS { param([switch]$Fresh) ,@() }
function Stop-DS { 'stopped' }

$script:queueReads = 0
$readConfigSource = (Get-Command Read-EngineConfig).ScriptBlock
function Read-EngineConfig([string]$Path) { $script:queueReads++; & $readConfigSource $Path }
$ReadOnly = $true
$firstRead = Get-Cfg
$secondRead = Get-Cfg
Check 'the status worker parses an unchanged queue once' ($script:queueReads -eq 1 -and $secondRead.game.mods.Count -eq $firstRead.game.mods.Count)
$changedConfig = $firstRead | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$changedConfig.game.mods = @()
Save-Json $changedConfig $Cfg
Check 'the status worker sees an atomically replaced queue' (@((Get-Cfg).game.mods).Count -eq 0 -and $script:queueReads -eq 2)
$ReadOnly = $false
. (Join-Path $PSScriptRoot 'state.ps1')

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
$script:installedFixture = @{}
function Get-HaveIds { $script:installedFixture }
Update-Cfg { param($config) $config.game.mods = @([pscustomobject]@{ modId = 'ABCDEF0123456789'; name = 'Waiting' }) } $Cfg | Out-Null
$null = Invoke-AddServer '55555555-5555-5555-5555-555555555555'
Check 'adding an already queued server mod leaves the installed cache unchanged' (!$script:installedFixture.ContainsKey('ABCDEF0123456789'))

Reset-State
$script:serverList = @([pscustomobject]@{ id = '66666666-6666-6666-6666-666666666666'; name = 'S'; mods = @(
  [pscustomobject]@{ id = '0000000000000010'; name = 'm1'; e = 1 },
  [pscustomobject]@{ id = '0000000000000011'; name = 'm2'; e = 1 }) })
$script:sizeMap = @{ '0000000000000010' = @{ name = 'm1'; bytes = 1 }; '0000000000000011' = @{ name = 'm2'; bytes = 1 }; '0000000000000012' = @{ name = 'm3'; bytes = 1 } }
function Get-HaveIds { @{ '0000000000000011' = $true } }
Update-Cfg { param($cfg) $cfg.game.mods = @([pscustomobject]@{ modId = '0000000000000012'; name = 'm3'; version = '1.2.3' }) } $Cfg | Out-Null
$sizeMap['0000000000000013'] = @{ name = 'removed'; bytes = 1 }
$null = Invoke-QueueServer '66666666-6666-6666-6666-666666666666'
$qmods = @((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods)
Check 'queue first puts the missing server mods first, then the rest' ($qmods.Count -eq 2 -and $qmods[0].modId -eq '0000000000000010' -and $qmods[1].modId -eq '0000000000000012' -and $qmods[1].version -eq '1.2.3')

Reset-State
function Get-HaveIds { @{} }
$null = Invoke-AddMod 'ABCDEF0123456789'
$cmsg = Invoke-ClearQueue
Check 'clear queue empties it' (@((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods).Count -eq 0 -and $cmsg -match 'queue cleared')

Reset-State
$null = Invoke-AddMod 'ABCDEF0123456789'
Update-Cfg { param($cfg) $cfg.game.mods += [pscustomobject]@{ modId = '0000000000000020'; name = 'Other' } } $Cfg | Out-Null
$null = Invoke-RemoveQueuedMod 'abcdef0123456789'
$remaining = @((Get-Cfg).game.mods)
Check 'remove one mod preserves the other download' ($remaining.Count -eq 1 -and $remaining[0].modId -eq '0000000000000020')
$null = Invoke-ResumeAll
Check 'bulk queue does not restore a removed standalone mod from size history' (@((Get-Cfg).game.mods).Count -eq 1)

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
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')
. (Join-Path $PSScriptRoot 'state.ps1')

Write-Host 'download progress uses the current batch'
Reset-State
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')
function Get-DS { param([switch]$Fresh) ,@() }
function Get-Log { }
function Get-ClientIds { @() }
function Get-AddonsBytes { 9999 }
function Get-SkippedNames { @() }
function Get-DirMap { $script:fixtureDirs }
function Test-AddonComplete { param($Directory, $Modified) $script:fixtureComplete }
$script:fixtureComplete = $false
$script:fixtureDirs = @{ 'ABCDEF0123456789' = @{ bytes = 5; mtime = Get-Date; path = 'fixture' } }
$script:sizeMap = @{ 'ABCDEF0123456789' = @{ bytes = 10 }; '0000000000000020' = @{ bytes = 9999 } }
# Get-Status reloads the sizes file when it changes (a second worker may have written
# it), so the fixture must exist on disk as well as in memory
'{"totalBytes":10009,"mods":{"ABCDEF0123456789":{"bytes":10},"0000000000000020":{"bytes":9999}}}' | Set-Content $Sizes
$script:sizeFileStamp = $null
Update-Cfg { param($cfg) $cfg.game.mods = @([pscustomobject]@{ modId = 'ABCDEF0123456789'; name = 'Active' }) } $Cfg | Out-Null
$status = Get-Status
Check 'progress ignores allocated files and the historical library' ($status.totalB -eq 10 -and $status.doneB -eq 0 -and $status.pct -eq 0)
Check 'status ships a completed revision, not the whole list' ($status.recentRev -and $null -eq $status.PSObject.Properties['recent'])
$transferLog = Join-Path $tmp 'transfer.log'
$transferNow = Get-Date
$stamp = $transferNow.ToString('HH:mm:ss.fff')
@("$stamp  BACKEND      : Fixture: [======>_____________] 79% 8680/11000 MB",
  "$stamp  BACKEND      : Download speed 7876.49 KB/s") | Set-Content -LiteralPath $transferLog
$report = Get-TransferSnapshot (Get-Item -LiteralPath $transferLog) $transferNow $transferNow.AddMinutes(-1)
Check 'reported bytes and speed come from the engine log' ($report.mods.Fixture.b -eq 8680MB -and $report.mods.Fixture.expB -eq 11000MB -and $report.speedB -eq [Math]::Round(7876.49 * 1KB))
$staleReport = Get-TransferSnapshot (Get-Item -LiteralPath $transferLog) $transferNow.AddSeconds(31) $transferNow.AddMinutes(-1)
Check 'old speed is withheld rather than shown as current' ($staleReport.speedB -eq 0)
& {
  function Get-DS { ,@([pscustomobject]@{ StartTime = $transferNow.AddMinutes(-1) }) }
  function Get-Log { Get-Item -LiteralPath $transferLog }
  Update-Cfg { param($cfg) $cfg.game.mods[0].name = 'Fixture' } $Cfg | Out-Null
  $script:batchRev = [string](Get-QueueRevision)
  $script:modHigh = $null
  $firstActive = try { Get-Status } catch { Write-Host $_.Exception.Message }
  Check 'first active status initializes per-mod progress without a revision change' ($firstActive -and $firstActive.active[0].b -eq 8680MB)
  $script:batchRev = $null; $script:batchHighB = [double]0; $script:batchHighPct = [double]0; $script:modHigh = @{}
  $large = Get-Status
  Check 'status supports downloads above the 32-bit byte limit' ($large.doneB -eq 8680MB -and $large.totalB -eq 11000MB -and $large.pctF -gt 78)
  "$stamp BACKEND      : Addon Download started ABCDEF0123456789 - Active from log" | Set-Content -LiteralPath $transferLog
  $script:modHigh = @{}   # isolate this fixture from earlier high-water
  $started = Get-Status
  Check 'active mod appears before the first byte report' ($started.active[0].id -eq 'ABCDEF0123456789' -and $started.active[0].name -eq 'Active from log' -and $null -eq $started.active[0].b)
  Check 'Workshop size is available before the first byte report' ($started.active[0].expB -eq 10)
  $cacheFixture = Join-Path $tmp 'sample-transfer'
  $chunkDir = Join-Path $cacheFixture 'temp'
  [void][IO.Directory]::CreateDirectory($chunkDir)
  [IO.File]::WriteAllBytes((Join-Path $chunkDir 'chunk'), [byte[]](1,2,3))
  $script:fixtureDirs['ABCDEF0123456789'].path = $cacheFixture
  $oldStamp = $transferNow.AddSeconds(-45).ToString('HH:mm:ss.fff')
  "$oldStamp BACKEND : Addon Download started ABCDEF0123456789 - Quiet mod" | Set-Content -LiteralPath $transferLog
  $script:modHigh = @{}
  $script:batchHighB = $script:batchHighPct = $script:batchTotalHighB = [double]0
  $quiet = Get-Status
  Check 'quiet transfers show the measured cache as progress' ($quiet.active[0].age -ge 45 -and $quiet.active[0].cachedB -eq 3 -and $quiet.active[0].b -eq 3 -and $quiet.active[0].fromCache)
  Check 'the batch includes the active cache before the first engine byte report' ($quiet.doneB -eq 3 -and $quiet.pctF -eq 30)
  $packageFile = Join-Path $cacheFixture 'data002.pak'
  $allocatedFile = Join-Path $cacheFixture 'preallocated.pak'
  $packageMeta = Join-Path $cacheFixture 'meta'
  [IO.File]::WriteAllBytes($packageFile, [byte[]]::new(8))
  [IO.File]::WriteAllBytes($allocatedFile, [byte[]]::new(10))
  '{"meta":{"selectedRev":0,"versions":[{"package":{"files":[{"name":"data002.pak","size":10},{"name":"preallocated.pak","size":10}]}}]}}' |
    Set-Content -LiteralPath $packageMeta
  $writing = Get-Status
  Check 'growing package output advances the row and batch without double-counting or preallocation' (
    $writing.active[0].b -eq 4 -and $writing.doneB -eq 4 -and $writing.pctF -eq 40)
  Remove-Item -LiteralPath $packageFile, $allocatedFile, $packageMeta -Force
  $encoding = [Text.UTF8Encoding]::new($false)
  [IO.File]::AppendAllText($transferLog, ("unrelated engine output" + [Environment]::NewLine) * 200, $encoding)
  [IO.File]::AppendAllText($transferLog, "$stamp BACKEND : Quiet mod: [====] 25% 1/4", $encoding)
  $script:modHigh = @{}
  $pendingLine = Get-Status
  Check 'unfinished log lines do not fabricate measurements' ($pendingLine.active[0].name -eq 'Quiet mod' -and $pendingLine.active[0].fromCache -and $pendingLine.active[0].b -eq 3)
  [IO.File]::AppendAllText($transferLog, " MB" + [Environment]::NewLine, $encoding)
  $script:modHigh = @{}
  $continued = Get-Status
  Check 'next poll consumes the completed line after more than 160 unrelated entries' ($continued.active[0].b -eq 1MB -and $continued.active[0].expB -eq 4MB)
  $stoppedLog = @("$stamp BACKEND : Addon Download started ABCDEF0123456789 - Active from log",
    "$stamp BACKEND : Server registered")
  $stoppedLog | Set-Content -LiteralPath $transferLog
  $script:batchHighB = [double]0; $script:modHigh = @{}
  $idle = Get-Status
  Check 'a server that has registered is no longer downloading' ($idle.running -and !$idle.active.Count -and $idle.speedB -eq 0)
  # the engine rewrites its log while it assembles a mod; a lower report must not
  # move the batch or the mod backwards
  Set-Content -LiteralPath $transferLog "$stamp BACKEND : Fixture: [====] 40% 4400/11000 MB"
  $script:batchHighB = [double]8680MB
  $script:modHigh = @{ 'ABCDEF0123456789' = [double]8680MB }
  $back = Get-Status
  Check 'progress does not go backwards when the engine reports a smaller value' ($back.doneB -ge 8680MB -and $back.pctF -ge 78)
  Check 'an active mod keeps its highest measured bytes' ($back.active[0].b -ge 8680MB)
}
$script:fixtureComplete = $true
$status = Get-Status
Check 'progress resets when the last queued mod completes' ($status.totalB -eq 0 -and $status.doneB -eq 0 -and $status.pct -eq 0 -and !$status.queue.Count)
$script:fixtureComplete = $false
& {
  . (Join-Path $PSScriptRoot 'state.ps1')
  $Addons = Join-Path $tmp 'finish-fast'
  $modDir = Join-Path $Addons 'Fixture_ABCDEF0123456789'
  $tempDir = Join-Path $modDir 'temp'
  [void][IO.Directory]::CreateDirectory($tempDir)
  $meta = Join-Path $modDir 'meta'
  [IO.File]::WriteAllBytes((Join-Path $modDir 'data.pak'), [byte[]]::new(4))
  [IO.File]::WriteAllText($meta, '{"meta":{"selectedRev":0,"versions":[{"version":"1.0.0","package":{"files":[{"name":"data.pak","size":4}]}}]}}')
  $script:inventory = @{ dirs = @{}; client = @(); installed = @{}; versions = @{}; recent = @(); bytes = 0 }
  function Get-StatusInventory { $script:inventory }
  function Get-DS { ,@([pscustomobject]@{ StartTime = $transferNow.AddMinutes(-1) }) }
  function Get-Log { Get-Item -LiteralPath $transferLog }
  Set-Content -LiteralPath $transferLog "$stamp BACKEND : Addon Download started ABCDEF0123456789 - Fixture"
  Update-Cfg {
    param($config)
    $config.game.mods = @(
      [pscustomobject]@{ modId = 'ABCDEF0123456789'; name = 'Fixture'; version = '2.0.0' },
      [pscustomobject]@{ modId = '0011223344556677'; name = 'Next'; size = 10 }
    )
  } $Cfg | Out-Null
  Check 'a full-sized transfer still in temp stays queued' ((Get-Status).queue.Count -eq 2)
  Remove-Item -LiteralPath $tempDir
  Check 'an older installed revision stays queued' ((Get-Status).queue.Count -eq 2)
  [IO.File]::WriteAllText($meta, ([IO.File]::ReadAllText($meta).Replace('1.0.0', '2.0.0')))
  $completed = Get-Status
  Check 'the next status poll counts the finished mod before the full library scan' (
    $completed.doneCount -eq 1 -and $completed.queue.Count -eq 1 -and
    $completed.queue[0].id -eq '0011223344556677' -and 'ABCDEF0123456789' -in $completed.installedIds)
  Check 'recent downloads change on the same poll as the queue' ($completed.recentRev -match 'ABCDEF0123456789')
}
$null = Invoke-ClearQueue
$start = Invoke-StartQueue
Check 'Start leaves a cleared queue empty even when the partial still exists' ($start -match 'queue is empty' -and !@((Get-Cfg).game.mods).Count)
. (Join-Path $PSScriptRoot 'state.ps1')

Write-Host 'cancel removes tracked partials and preserves installed packages'
& {
  $cancelRoot = Join-Path $tmp 'cancel-fixture'
  $Data = Join-Path $cancelRoot 'data'
  $DsProfile = Join-Path $cancelRoot 'serverprofile'
  $Addons = Join-Path $DsProfile 'addons'
  $Cfg = Join-Path $Data 'batch1-serverconfig.json'
  New-Item -ItemType Directory -Path $Data,$Addons -Force | Out-Null
  $partial = Join-Path $Addons 'Incomplete_AAAABBBBCCCCDDDD'
  $installed = Join-Path $Addons 'Installed_EEEEFFFF00001111'
  $external = Join-Path $Addons 'Untracked_1111222233334444'
  $patch = Join-Path $Addons 'Updating_2222333344445555'
  $patchTemp = Join-Path $patch 'temp'
  New-Item -ItemType Directory -Path $partial,$installed,$external,$patchTemp -Force | Out-Null
  'half' | Set-Content -LiteralPath (Join-Path $partial 'partial.pak')
  'local' | Set-Content -LiteralPath (Join-Path $external 'partial.pak')
  'chunk' | Set-Content -LiteralPath (Join-Path $patchTemp 'chunk.pak')
  [IO.File]::WriteAllText((Join-Path $installed 'data.pak'), 'data')
  [IO.File]::WriteAllText((Join-Path $patch 'older.pak'), 'keep')
  '{"meta":{"selectedRev":0,"versions":[{"package":{"files":[{"name":"data.pak","size":4}]}}]}}' |
    Set-Content -LiteralPath (Join-Path $installed 'meta')
  '{"game":{"name":"Cancel","scenarioId":"fixture","mods":[{"modId":"2222333344445555","name":"Updating","version":"2.0"}]}}' |
    Set-Content -LiteralPath $Cfg
  $sizeMap = @{ AAAABBBBCCCCDDDD = @{}; EEEEFFFF00001111 = @{} }
  function Stop-DS { 'paused' }
  function Get-Process {}
  function Get-EngineProcesses {}
  $result = Invoke-CancelDownloads
  Check 'cancel clears the queue and deletes finished transfer fragments only' (
    $result -match 'Removed 2 partial downloads' -and !@((Get-Cfg).game.mods).Count -and
    !(Test-Path $partial) -and !(Test-Path $patchTemp) -and
    (Test-Path (Join-Path $patch 'older.pak')) -and (Test-Path (Join-Path $installed 'data.pak')) -and
    (Test-Path (Join-Path $external 'partial.pak')))
}

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
$bout = try { (& (Join-Path $PSScriptRoot 'make-preset.ps1') -ServerId 'bbbbbbbb-0000-0000-0000-000000000000' -ConfPath $bconf -AddonsDir (Join-Path $bd 'addons') 2>&1) -join ' ' } catch { "ERROR: $_" }
$env:RFMM_DATA = $oldData
$btext = Get-Content $bconf -Raw
Check 'a mod name with braces creates the preset' ($bout -match 'OK - preset')
Check 'the braces are replaced in the conf' ($btext -match 'm_sName "Foo \(Bar"' -and $btext -match 'm_sName "Baz\)Qux"')
Check 'the brace count still verifies' ($bout -match 'braces=[0-9]+/[0-9]+')

Write-Host 'item 11: the stop script targets only this folder''s helpers'
if ($IsLinux) {
  '  SKIP (windows only) the watchdog of that folder is stopped'
  '  SKIP (windows only) the addon mirror of that folder is stopped'
  '  SKIP (windows only) an unrelated process is left alone'
} else {
  $sr = Join-Path $tmp 'stoplab'
  New-Item -ItemType Directory -Force $sr | Out-Null
  $p1 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 30 # $(Join-Path $sr 'watchdog.ps1')" -PassThru -WindowStyle Hidden
  $p2 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 30 # $(Join-Path $sr 'sync-addons.ps1')" -PassThru -WindowStyle Hidden
  $p3 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 30 # $(Join-Path $sr 'other.ps1')" -PassThru -WindowStyle Hidden
  Start-Sleep 2
  $stopOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'stop.ps1') -Root $sr 2>&1
  Start-Sleep 1
  Check 'the watchdog of that folder is stopped' (-not (Get-Process -Id $p1.Id -ErrorAction SilentlyContinue))
  Check 'the addon mirror of that folder is stopped' (-not (Get-Process -Id $p2.Id -ErrorAction SilentlyContinue))
  Check 'an unrelated process is left alone' ([bool](Get-Process -Id $p3.Id -ErrorAction SilentlyContinue))
  foreach ($pp in @($p1, $p2, $p3)) { Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host 'engine lock (a held lock is never stolen)'
$hold = Start-Job -ArgumentList $tmp,$stateScript -ScriptBlock {
  param($d,$state)
  . $state
  $m = Lock-Engine 5000
  if (!$m) { throw 'Could not acquire the fixture lock.' }
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
Write-Host 'download progress without an engine report'
New-Item -ItemType Directory -Force $tmp | Out-Null
$snap1 = Resolve-TransferBytes $null 104857600 419430400
Check 'the measured cache counts as downloaded bytes' ($snap1.b -eq 104857600 -and $snap1.pct -eq 25 -and $snap1.fromCache)
$snap2 = Resolve-TransferBytes 209715200 104857600 419430400
Check 'a larger engine report wins over the cache' ($snap2.b -eq 209715200 -and -not $snap2.fromCache)
$snap3 = Resolve-TransferBytes $null 500 400
Check 'progress never exceeds the total' ($snap3.b -eq 400 -and $snap3.pct -eq 100)
Check 'no report and no cache is unknown' ($null -eq (Resolve-TransferBytes $null $null 400))

$tlog = Join-Path $tmp 'console.log'
$tnow = Get-Date
$tstamp = $tnow.ToString('HH:mm:ss.fff')
Set-Content $tlog "$tstamp BACKEND      : Addon Download started AAAABBBBCCCCDDDD - Huge Mod"
$tsnap = Get-TransferSnapshot ([IO.FileInfo]::new($tlog)) $tnow ($tnow.AddMinutes(-1))
Check 'the current mod is known before any progress line' ($tsnap.current.name -eq 'Huge Mod')
Check 'no byte report exists yet' ($tsnap.mods.Count -eq 0)
Add-Content $tlog "$tstamp BACKEND      : Huge Mod: [==] 50% 10/20 MB"
$tsnap2 = Get-TransferSnapshot ([IO.FileInfo]::new($tlog)) (Get-Date) ($tnow.AddMinutes(-1))
Check 'a progress line carries bytes' ($tsnap2.mods['Huge Mod'].b -eq 10MB -and $tsnap2.mods['Huge Mod'].expB -eq 20MB)

Write-Host 'installed version cache'
$vd = Join-Path $tmp 'versioned'
New-Item -ItemType Directory -Force $vd | Out-Null
Set-Content (Join-Path $vd 'meta') '{"meta":{"selectedRev":0,"versions":[{"version":"1.0.0"}]}}'
$iver1 = Get-InstalledVersion $vd
Check 'reads the selected version' ($iver1 -eq '1.0.0')
Set-Content (Join-Path $vd 'meta') '{"meta":{"selectedRev":0,"versions":[{"version":"1.0.1"}]}}'
$mfi = [IO.FileInfo]::new((Join-Path $vd 'meta')); $mfi.LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(1)
$iver2 = Get-InstalledVersion $vd
Check 'a rewritten meta invalidates the version cache' ($iver2 -eq '1.0.1')
Write-Host 'library scan reuses unchanged folders'
. (Join-Path $PSScriptRoot 'dashboard-core.ps1')   # a fixture above stubbed Get-DirMap
$lb = Join-Path $tmp 'library'
$modA = Join-Path $lb 'ModA_AAAABBBBCCCCDDDD'
$modB = Join-Path $lb 'ModB_EEEEFFFF00001111'
New-Item -ItemType Directory -Force $modA, $modB | Out-Null
[IO.File]::WriteAllText((Join-Path $modA 'data.pak'), ('x' * 10))
[IO.File]::WriteAllText((Join-Path $modA 'meta'), 'm')
[IO.File]::WriteAllText((Join-Path $modB 'data.pak'), ('y' * 20))
$savedAddons = $Addons
$Addons = $lb
$script:dirCacheAt = [datetime]::MinValue
$script:dirFolderCache = @{}
$first = Get-DirMap
Check 'the first scan totals each mod folder' ($first['AAAABBBBCCCCDDDD'].bytes -eq 11 -and $first['EEEEFFFF00001111'].bytes -eq 20)
# a folder being written stays recent, so it is always re-read
$script:dirCacheAt = [datetime]::MinValue
$null = Get-DirMap
[IO.File]::WriteAllText((Join-Path $modA 'chunk.pak'), ('z' * 5))
$script:dirCacheAt = [datetime]::MinValue
$second = Get-DirMap
Check 'an appended chunk shows up after a rescan' ($second['AAAABBBBCCCCDDDD'].bytes -eq 16)
$Addons = $savedAddons
if ($fail) { "units: $fail failed"; exit 1 } else { 'units: OK' }



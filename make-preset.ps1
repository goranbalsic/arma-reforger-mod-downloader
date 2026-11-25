# Create a preset from a tracked server's installed mods.
# Usage: .\make-preset.ps1 -ServerId <server guid>
# The game reads presets from m_aPresets inside SCR_WorkshopAddonManagerPresetStorage.
param(
  [Parameter(Mandatory = $true)][string]$ServerId,
  [string]$ConfPath,
  [string]$Name,                 # preset name (default: the server's short name)
  [string[]]$Exclude = @(),      # regex patterns: mods whose name matches are left out
  [string]$AddonsDir,            # client addons folder (default: the game's)
  [switch]$Summary
)
$ErrorActionPreference = 'Stop'
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
# Use the same file and size checks as the downloader.
. (Join-Path $PSScriptRoot 'state.ps1')
. (Join-Path $PSScriptRoot 'preset-scenarios.ps1')

$conf = if ($ConfPath) { $ConfPath } else {
  # Use the newest settings file for this profile.
  $game = Get-GameProfile
  if (!$game) { throw 'Set RFMM_GAME_PROFILE to the game profile folder to make presets.' }
  $f = Get-ChildItem (Join-Path $game 'profile/.save') -Recurse -Filter ReforgerGameSettings.conf -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { throw 'ReforgerGameSettings.conf not found' }
  $f.FullName
}
$srvs = Get-Content -LiteralPath (Join-Path $Data 'batch1-servers.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$clAddons = if ($AddonsDir) { $AddonsDir } else { (Join-Path (Get-GameProfile) 'addons') }

# Wait for the game client to exit and save its settings before editing them.
$gameProc = Get-Process -Name 'ArmaReforger*' -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessName -ne 'ArmaReforgerServer' }
if (-not $ConfPath -and $gameProc) { throw "Game is running ($($gameProc[0].ProcessName)) - close it first (it rewrites this file on exit)" }

$text = [IO.File]::ReadAllText($conf)
$confTokenPattern = '"(?:[^"\\]|\\.)*"|[{}]'

function Find-ClosingConfBrace([string]$Contents, [int]$Opening) {
  if ($Opening -lt 0) { return -1 }
  $depth = 0
  foreach ($token in [regex]::Matches($Contents.Substring($Opening), $confTokenPattern)) {
    if ($token.Value -ceq '{') { $depth++ }
    elseif ($token.Value -ceq '}') {
      $depth--
      if ($depth -eq 0) { return ($Opening + $token.Index) }
    }
  }
  -1
}

function ConvertTo-PresetText([string]$Label) {
  (($Label.Replace('"', "'").Replace('{', '(').Replace('}', ')').Replace('\', '/')) -replace '[\x00-\x1F]', ' ')
}

# Presets must be enclosed by the storage declaration's m_aPresets block.
$declaration = '(?m)^[ \t]*SCR_WorkshopAddonManagerPresetStorage[ \t]+SCR_WorkshopAddonManagerPresetStorage[ \t]+'
# Restore a truncated storage ID from this profile's backups.
if ($text -match ($declaration + '"\{\s*"')) {
  $guid = $null
  foreach ($backup in (Get-ChildItem -LiteralPath (Split-Path $conf) -Filter 'ReforgerGameSettings.conf.bak-*' | Sort-Object LastWriteTime -Descending)) {
    $saved = [IO.File]::ReadAllText($backup.FullName)
    if ($saved -match ($declaration + '"\{([0-9A-Fa-f]{16})\}"') -or
        $saved -match ($declaration + '"\{\s+m_aPresets\s*\{[\s\S]*?\}\s*([0-9A-Fa-f]{16})\}"')) {
      $guid = $Matches[1]
      break
    }
  }
  if (-not $guid) { throw 'The preset storage ID is damaged. Restore a settings backup with its original ID.' }
  $text = [regex]::Replace($text, '(' + $declaration + ')"\{\s*"', ('$1"{' + $guid + '}"'))
}
$header = [regex]::Match($text, $declaration + '"\{[0-9A-Fa-f]{16}\}"\s*\{')
if (-not $header.Success) { throw 'Cannot locate a valid preset storage declaration in the settings file.' }
$storageStart = $header.Index + $header.Length
$end = Find-ClosingConfBrace $text ($storageStart - 1)
if ($end -lt 0) { throw 'Unclosed preset storage block.' }
$storage = $text.Substring($storageStart, $end - $storageStart)
$presetsBefore = ([regex]::Matches($storage, 'SCR_WorkshopAddonPreset "\{[0-9A-F]{16}\}"')).Count

# insert inside m_aPresets { }; create that container when the conf has none yet
$indent = '   '   # the game indents a preset by 3 spaces inside m_aPresets
$presetField = [regex]::Match($storage, '(?m)^[ \t]*m_aPresets\s*\{')
if ($presetField.Success) {
  $ins = $storageStart + $presetField.Index + $presetField.Length
  $wrapBefore = ''; $wrapAfter = ''
} else {
  # An empty storage block needs its own m_aPresets container.
  $ins = $storageStart
  $wrapBefore = "`r`n  m_aPresets {"
  $wrapAfter = "`r`n  }"
}

$srv = @($srvs.servers | Where-Object { $_.id -eq $ServerId })[0]
if (-not $srv) { throw "server $ServerId is not in batch1-servers.json" }
$presetName = if ($Name) { $Name }
              elseif ($srv.PSObject.Properties['key'] -and $srv.key) { [string]$srv.key }
              else { ([string]$srv.name -split '\|')[0].Trim() }
if ($presetName.Length -gt 60) { $presetName = $presetName.Substring(0, 60).Trim() }
$previousName = ($presetName.Replace('"', "'") -replace '[\x00-\x1F]', ' ')
$presetName = ConvertTo-PresetText $presetName

# Include an addon only when its metadata and files pass the shared completion check.
$installed = @{}
$directories = @{}
Get-ChildItem $clAddons -Directory |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' -and (Test-Path (Join-Path $_.FullName 'meta')) } |
  ForEach-Object {
    if (Test-AddonComplete $_.FullName $_.LastWriteTime) {
      $id = [regex]::Match($_.Name, '_([0-9A-F]{16})$').Groups[1].Value
      $directories[$id] = $_.FullName
      $installed[$id] = ($_.Name -replace '_[0-9A-F]{16}$', '')
    }
  }
$mods = @($srv.mods | Where-Object { $installed.ContainsKey($_.id) })
$installedCount = $mods.Count
$dropped = @()
if ($Exclude.Count) {
  $dropped = @($mods | Where-Object { $n = $_.name; @($Exclude | Where-Object { $n -match $_ }).Count -gt 0 })
  $mods = @($mods | Where-Object { $n = $_.name; @($Exclude | Where-Object { $n -match $_ }).Count -eq 0 })
  if (!$Summary) { "excluded for this preset: $($dropped.Count) mod(s): $(($dropped | ForEach-Object { $_.name }) -join ', ')" }
}
if (!$Summary) { "server: $($srv.name)  mods=$(@($srv.mods).Count)  installed here: $installedCount  in this preset: $($mods.Count)" }
if (!$Summary -and $installedCount -lt @($srv.mods).Count) {
  "note: $(@($srv.mods).Count - $installedCount) mod(s) not installed yet - re-run this after the batch finishes"
}
if (-not $mods) { throw 'no installed mods for this preset yet' }

function Get-Hash16([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 16) }
  finally { $sha.Dispose() }
}
$presetGuid = (Get-Hash16 "preset:$($srv.id):$presetName").ToUpper()
# Reforger regenerates object IDs when saving settings. Reuse the saved ID
# for this named preset so the next click updates the same entry.
$names = '(?:' + [regex]::Escape($presetName) + '|' + [regex]::Escape($previousName) + ')'
$existing = [regex]::Match($storage, 'SCR_WorkshopAddonPreset "\{([0-9A-Fa-f]{16})\}"\s*\{\s*m_sName "' + $names + '"')
if ($existing.Success) { $presetGuid = $existing.Groups[1].Value }
$metas = foreach ($m in $mods) {
  $g = (Get-Hash16 "meta:$($m.id)").ToUpper()
  $n = ConvertTo-PresetText $installed[$m.id]
  $indent + '  SCR_WorkshopAddonPresetAddonMeta "{' + $g + '}" {' + "`r`n" +
  $indent + '   m_sGuid "' + $m.id + '"' + "`r`n" +
  $indent + '   m_sName "' + $n + '"' + "`r`n" +
  $indent + '  }'
}
$body = $indent + 'SCR_WorkshopAddonPreset "{' + $presetGuid + '}" {' + "`r`n" +
        $indent + ' m_sName "' + $presetName + '"' + "`r`n" +
        $indent + ' m_aAddonsMeta {' + "`r`n" +
        (($metas -join "`r`n") + "`r`n") +
        $indent + ' }' + "`r`n" +
        $indent + '}'

# Replace the existing preset when its GUID matches.
$mark = 'SCR_WorkshopAddonPreset "{' + $presetGuid + '}"'
$at = $text.IndexOf($mark, $storageStart, $storage.Length)
if ($at -ge 0) {
  $ob = $text.IndexOf('{', $at + $mark.Length)
  $cb = Find-ClosingConfBrace $text $ob
  if ($cb -lt 0) { throw 'the existing preset in the conf has no closing brace - restore a .bak next to the conf' }
  $newText = $text.Remove($at, $cb - $at + 1).Insert($at, $body.Substring($indent.Length))
  $action = 'updated'
  $expected = $presetsBefore
} else {
  $newText = $text.Insert($ins, $wrapBefore + "`r`n" + $body + $wrapAfter)
  $action = 'created'
  $expected = $presetsBefore + 1
}
# Validate the preset before replacing the settings file.
$check = $newText
$open = 0; $close = 0
foreach ($token in [regex]::Matches($check, $confTokenPattern)) {
  if ($token.Value -ceq '{') { $open++ }
  elseif ($token.Value -ceq '}') { $close++ }
}
$presets = ([regex]::Matches($check.Substring($check.IndexOf('SCR_WorkshopAddonManagerPresetStorage')), 'SCR_WorkshopAddonPreset "\{[0-9A-F]{16}\}"')).Count
# the preset must sit INSIDE m_aPresets, otherwise the game drops it on save
$newField = [regex]::Match($check.Substring($storageStart), '(?m)^[ \t]*m_aPresets\s*\{')
$mpAfter = if ($newField.Success) { $storageStart + $newField.Index + $newField.Length - 1 } else { -1 }
$mpEnd = Find-ClosingConfBrace $check $mpAfter
$newAt = $check.IndexOf('SCR_WorkshopAddonPreset "{' + $presetGuid + '}"')
$inside = $mpAfter -ge 0 -and $newAt -gt $mpAfter -and $newAt -lt $mpEnd
if (!$Summary) { "verification: presets=$presets (expected $expected) inside m_aPresets=$inside meta=$($mods.Count) braces=$open/$close" }
if ($presets -ne $expected -or $open -ne $close -or -not $inside) { throw 'verification failed - the settings file was not changed' }

# atomic: a temp file beside it, then a swap that also keeps the previous version
$tmpConf = "$conf.tmp"
[IO.File]::WriteAllText($tmpConf, $newText, [Text.UTF8Encoding]::new($false))
[IO.File]::Replace($tmpConf, $conf, "$conf.bak-$(Get-Date -f yyyyMMdd-HHmmss)")
# Keep the five most recent backups.
Get-ChildItem (Split-Path $conf -Parent) -Filter "$([IO.Path]::GetFileName($conf)).bak-*" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
  Remove-Item -Force -ErrorAction SilentlyContinue
if (!$Summary) { "OK - preset '$presetName' $action with $($mods.Count) installed mods" }

$scenarioCount = 0
$scenarioFailures = 0
foreach ($mod in $mods) {
  try { $scenarioCount += Sync-PresetScenarios $directories[$mod.id] $mod.id }
  catch {
    $scenarioFailures++
    $details = "Scenario check incomplete for $($mod.name): $($_.Exception.Message)"
    if ($Summary) { Add-Content -LiteralPath (Join-Path $Data 'preset-scenarios.log') -Value $details -Encoding UTF8 -ErrorAction SilentlyContinue }
    else { $details }
  }
}
if ($Summary) {
  $message = "Preset '$presetName' $action ($($mods.Count) mods)."
  if ($installedCount -lt @($srv.mods).Count) { $message += " $(@($srv.mods).Count - $installedCount) mods are still missing." }
  if ($scenarioFailures) { $message += " Couldn't check scenarios for $scenarioFailures mods." }
  $message
} else { "Local scenarios confirmed: $scenarioCount" }

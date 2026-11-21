# Build an Arma Reforger launcher preset from a server's real modlist.
#   .\make-preset.ps1 -ServerId <server guid>
# The preset MUST be a child of m_aPresets { } inside
# SCR_WorkshopAddonManagerPresetStorage. A preset written directly into the
# storage block is silently dropped on the next game save (verified against a
# real conf: the block vanished and only hand-made presets survived).
# Only mods already installed locally are included: the launcher deletes preset
# entries it cannot resolve, so uninstalled workshop items would poison the whole
# preset on exit. Re-run when the batch finishes to pick up the rest.
param(
  [Parameter(Mandatory = $true)][string]$ServerId,
  [string]$ConfPath,
  [string]$Name,                 # preset name (default: the server's short name)
  [string[]]$Exclude = @(),      # regex patterns: mods whose name matches are left out
  [string]$AddonsDir             # client addons folder (default: the game's)
)
$ErrorActionPreference = 'Stop'
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
# the completion rule (meta lists every file with its exact size) - one copy
. "$PSScriptRoot\state.ps1"

$conf = if ($ConfPath) { $ConfPath } else {
  # newest wins: several profile folders (one per Steam/user) each hold a copy,
  # and picking an arbitrary one rewrote a stale conf
  $f = Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforger\profile\.save" -Recurse -Filter ReforgerGameSettings.conf -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { throw 'ReforgerGameSettings.conf not found' }
  $f.FullName
}
$srvs = Get-Content "$Data\batch1-servers.json" -Raw | ConvertFrom-Json
$clAddons = if ($AddonsDir) { $AddonsDir } else { "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons" }

# any running client build (Steam, MS Store, DX12 variants), never the dedicated
# server: the game rewrites this file on exit and the preset would vanish
$gameProc = Get-Process -Name 'ArmaReforger*' -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessName -ne 'ArmaReforgerServer' }
if (-not $ConfPath -and $gameProc) { throw "Game is running ($($gameProc[0].ProcessName)) - close it first (it rewrites this file on exit)" }

$text = [IO.File]::ReadAllText($conf)

# anchor on the storage declaration itself, never on a version line: inserting
# near the top gets the preset dropped by the game
$sIdx = $text.IndexOf('SCR_WorkshopAddonManagerPresetStorage')
if ($sIdx -lt 0) { throw 'preset storage block not found in conf' }
$storage = $text.Substring($sIdx)
$presetsBefore = ([regex]::Matches($storage, 'SCR_WorkshopAddonPreset "\{[0-9A-F]{16}\}"')).Count

# insert inside m_aPresets { }; create that container when the conf has none yet
$indent = '   '   # the game indents a preset by 3 spaces inside m_aPresets
$mp = $text.IndexOf('m_aPresets', $sIdx)
if ($mp -ge 0) {
  $ins = $text.IndexOf('{', $mp) + 1
  $wrapBefore = ''; $wrapAfter = ''
} else {
  # an empty storage block has neither m_aPresets nor m_iVersion (the conf on this
  # machine ships "{ }"), so anchor on the storage block's own brace. Every Make
  # preset click used to fail here with "preset storage m_iVersion not found".
  $ins = $text.IndexOf('{', $sIdx) + 1
  $wrapBefore = "`r`n  m_aPresets {"
  $wrapAfter = "`r`n  }"
}

$srv = @($srvs.servers | Where-Object { $_.id -eq $ServerId })[0]
if (-not $srv) { throw "server $ServerId is not in batch1-servers.json" }
$presetName = if ($Name) { $Name }
              elseif ($srv.PSObject.Properties['key'] -and $srv.key) { [string]$srv.key }
              else { ([string]$srv.name -split '\|')[0].Trim() }
if ($presetName.Length -gt 60) { $presetName = $presetName.Substring(0, 60).Trim() }
# quotes and control characters would break the conf or its brace structure
$presetName = ($presetName -replace '"', "'") -replace '[\x00-\x1F]', ' '

# a folder alone is not an installed addon: UTF-Hesco_6A23267521A13350 exists in
# this machine's client folder with 0 files, and a preset referencing an id the
# launcher cannot resolve loses the whole preset. The meta file is required (the
# launcher reads it) AND must match the files on disk - same completion rule as the
# downloader and verify, so a half-downloaded mod never ends up in a preset.
$installed = @{}
Get-ChildItem $clAddons -Directory |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' -and (Test-Path (Join-Path $_.FullName 'meta')) } |
  ForEach-Object {
    if (Test-AddonComplete $_.FullName $_.LastWriteTime) {
      $id = [regex]::Match($_.Name, '_([0-9A-F]{16})$').Groups[1].Value
      $installed[$id] = ($_.Name -replace '_[0-9A-F]{16}$', '')
    }
  }
$mods = @($srv.mods | Where-Object { $installed.ContainsKey($_.id) })
$installedCount = $mods.Count
$dropped = @()
if ($Exclude.Count) {
  $dropped = @($mods | Where-Object { $n = $_.name; @($Exclude | Where-Object { $n -match $_ }).Count -gt 0 })
  $mods = @($mods | Where-Object { $n = $_.name; @($Exclude | Where-Object { $n -match $_ }).Count -eq 0 })
  "excluded for this preset: $($dropped.Count) mod(s): $(($dropped | ForEach-Object { $_.name }) -join ', ')"
}
"server: $($srv.name)  mods=$(@($srv.mods).Count)  installed here: $installedCount  in this preset: $($mods.Count)"
if ($installedCount -lt @($srv.mods).Count) {
  "note: $(@($srv.mods).Count - $installedCount) mod(s) not installed yet - re-run this after the batch finishes"
}
if (-not $mods) { throw 'no installed mods for this preset yet' }

function Get-Hash16([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 16)
}
$presetGuid = (Get-Hash16 "preset:$($srv.id):$presetName").ToUpper()
$metas = foreach ($m in $mods) {
  $g = (Get-Hash16 "meta:$($m.id)").ToUpper()
  $n = ($installed[$m.id] -replace '"', "'") -replace '[\x00-\x1F]', ' '
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

# same server and same name = same preset guid, so an existing preset is updated
# in place with the current modlist instead of refusing: a server changes its mods
# and the preset has to follow
$mark = 'SCR_WorkshopAddonPreset "{' + $presetGuid + '}"'
$at = $text.IndexOf($mark)
if ($at -ge 0) {
  $ob = $text.IndexOf('{', $at + $mark.Length)
  $depth = 0; $cb = -1
  for ($i = $ob; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq '{') { $depth++ }
    elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { $cb = $i; break } }
  }
  if ($cb -lt 0) { throw 'the existing preset in the conf has no closing brace - restore a .bak next to the conf' }
  $newText = $text.Remove($at, $cb - $at + 1).Insert($at, $body.Substring($indent.Length))
  $action = 'updated'
  $expected = $presetsBefore
} else {
  $newText = $text.Insert($ins, $wrapBefore + "`r`n" + $body + $wrapAfter)
  $action = 'created'
  $expected = $presetsBefore + 1
}
# verify BEFORE writing: a preset that would break the settings file is never
# committed, so there is nothing to roll back
$check = $newText
$open = ([regex]::Matches($check, '\{')).Count
$close = ([regex]::Matches($check, '\}')).Count
$presets = ([regex]::Matches($check.Substring($check.IndexOf('SCR_WorkshopAddonManagerPresetStorage')), 'SCR_WorkshopAddonPreset "\{[0-9A-F]{16}\}"')).Count
# the preset must sit INSIDE m_aPresets, otherwise the game drops it on save
$mpAfter = $check.IndexOf('m_aPresets', $check.IndexOf('SCR_WorkshopAddonManagerPresetStorage'))
$newAt = $check.IndexOf('SCR_WorkshopAddonPreset "{' + $presetGuid + '}"')
$inside = $mpAfter -ge 0 -and $newAt -gt $mpAfter
"verification: presets=$presets (expected $expected) inside m_aPresets=$inside meta=$($mods.Count) braces=$open/$close"
if ($presets -ne $expected -or $open -ne $close -or -not $inside) { throw 'verification failed - the settings file was not changed' }

# atomic: a temp file beside it, then a swap that also keeps the previous version
$tmpConf = "$conf.tmp"
[IO.File]::WriteAllText($tmpConf, $newText, [Text.UTF8Encoding]::new($false))
[IO.File]::Replace($tmpConf, $conf, "$conf.bak-$(Get-Date -f yyyyMMdd-HHmmss)")
# keep the newest 5 backups only: 17 had accumulated next to a single conf
Get-ChildItem (Split-Path $conf -Parent) -Filter "$([IO.Path]::GetFileName($conf)).bak-*" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
  Remove-Item -Force -ErrorAction SilentlyContinue
"OK - preset '$presetName' $action with $($mods.Count) installed mods"

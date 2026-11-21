# The dedicated server can install the mission payload without filling the
# client's scenario catalog. Only the selected mod revision may be repaired.
function Sync-PresetScenarios([string]$Directory, [string]$Id) {
  $dbPath = Join-Path $Directory 'resourceDatabase.rdb'
  if (-not [IO.File]::Exists($dbPath)) { return 0 }
  $bytes = [IO.File]::ReadAllBytes($dbPath)
  $index = [Text.Encoding]::ASCII.GetString($bytes)
  if ($index -notmatch '(?i)Missions/[^\x00\r\n]{1,512}\.conf\x00') { return 0 }

  $path = Join-Path $Directory 'meta'
  $original = [IO.File]::ReadAllText($path)
  $doc = $original | ConvertFrom-Json
  $revision = $doc.meta.versions[[int]$doc.meta.selectedRev]
  if (!$revision -or $doc.meta.id -ne $Id) { throw 'Invalid local revision metadata' }
  $known = @{}
  foreach ($row in $revision.scenarios) { if ($row.gameId) { $known[$row.gameId] = $true } }
  # Skip the remote lookup when every local mission path already has a record.
  $candidates = @([regex]::Matches($index, '(?i)Missions/[^\x00\r\n]{1,512}\.conf\x00') | ForEach-Object {
    $offset = $_.Index + $_.Length + 6
    if ($offset + 8 -le $bytes.Length) {
      '{' + [BitConverter]::ToUInt64($bytes,$offset).ToString('X16') + '}' + $_.Value.TrimEnd([char]0)
    }
  })
  if (!@($candidates | Where-Object { !$known.ContainsKey($_) }).Count) { return $known.Count }

  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $page = Invoke-WebRequest "https://reforger.armaplatform.com/workshop/$Id/scenarios" -UseBasicParsing -DisableKeepAlive -TimeoutSec 12
  $json = [regex]::Match($page.Content,'(?s)<script id="__NEXT_DATA__"[^>]*>(.*?)</script>')
  if (!$json.Success) { throw 'Workshop scenario catalog unavailable' }
  $catalog = ($json.Groups[1].Value | ConvertFrom-Json).props.pageProps
  if ($catalog.asset.id -ne $Id -or $catalog.asset.currentVersionNumber -ne $revision.version) {
    throw 'Workshop catalog differs from the installed version'
  }
  $added = @(foreach ($mission in $catalog.assetVersionDetail.scenarios) {
    if ($mission.gameId -in $candidates -and !$known.ContainsKey($mission.gameId)) {
      $known[$mission.gameId] = $true
      [ordered]@{ name=$mission.name; description=$mission.description; authorName=$mission.authorName
        ownerId=$Id; image=@{}; gameId=$mission.gameId; playerCount=$mission.playerCount }
    }
  })
  if ($added.Count) {
    $revision.scenarios = @($revision.scenarios | Where-Object { $_ }) + $added
    $tmp = "$path.$([guid]::NewGuid()).tmp"
    try {
      [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 100 -Compress))
      if ([IO.File]::ReadAllText($path) -cne $original) { throw 'Local metadata changed during repair' }
      [IO.File]::Replace($tmp,$path,"$path.before-preset-scenarios")
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
  }
  return $known.Count
}

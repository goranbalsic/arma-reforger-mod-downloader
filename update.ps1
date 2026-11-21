# Checks GitHub for a newer release of this tool, and installs it.
#
#   .\update.ps1            check only
#   .\update.ps1 -Install   download the new release over this folder
#   .\update.ps1 -Quiet     say nothing unless there is an update
#
# An update replaces the scripts only: the engine (armar-server), SteamCMD and
# your queue/logs (data) are never touched.
param(
    [switch]$Install,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Repo = 'goranbalsic/arma-reforger-mod-downloader'
$mine = (Get-Content (Join-Path $Root 'version.txt') -Raw -ErrorAction SilentlyContinue)
$mine = if ($mine) { $mine.Trim() } else { 'unknown' }

try {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers @{ 'User-Agent' = 'arma-reforger-mod-downloader' } -TimeoutSec 20
} catch {
    if (-not $Quiet) {
        Write-Host 'Could not reach GitHub to check for updates.' -ForegroundColor Yellow
        Write-Host 'The tool still works - an update check needs internet.'
    }
    exit 1
}

$new = ($rel.tag_name -replace '^v', '').Trim()
# "not the same" is not the same as "newer": an older release must never be
# offered as an update, and 1.0.10 is newer than 1.0.9
[version]$newV = [version]'0.0'; [version]$mineV = [version]'0.0'
$comparable = [version]::TryParse($new, [ref]$newV) -and [version]::TryParse($mine, [ref]$mineV)
$newer = if ($comparable) { $newV -gt $mineV } else { $new -ne $mine }
if (-not $new -or -not $newer) {
    if (-not $Quiet) { Write-Host "You have the latest version ($mine)." -ForegroundColor Green }
    exit 0
}

Write-Host "New version available: $mine -> $new" -ForegroundColor Cyan
if ($rel.name) { Write-Host "  $($rel.name)" }
if (-not $Install) {
    Write-Host 'Run "2 - Update.cmd" to install it.' -ForegroundColor Yellow
    exit 0
}

$asset = @($rel.assets) | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $asset) {
    Write-Host 'That release has no .zip file to download.' -ForegroundColor Red
    exit 1
}

$zip = Join-Path $env:TEMP "rfmm-$new.zip"
$tmp = Join-Path $env:TEMP "rfmm-$new"
Write-Host "Downloading $($asset.name)..."
Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 600
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $tmp -Force

Get-ChildItem $tmp -Force |
    Where-Object { $_.Name -notin 'steamcmd', 'armar-server', 'data' } |
    ForEach-Object { Copy-Item $_.FullName $Root -Recurse -Force }

Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
Set-Content (Join-Path $Root 'version.txt') $new
Write-Host "Updated to $new. Restart the tool if it is running." -ForegroundColor Green

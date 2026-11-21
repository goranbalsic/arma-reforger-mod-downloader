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
# the checksum helper lives with the rest of the shared code
. "$PSScriptRoot\state.ps1"
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

# the release carries a sha256 digest: a truncated or altered download is refused
$check = Test-Sha256 $zip ([string]$asset.digest)
if ($check -eq $false) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Host 'The downloaded update does not match its published checksum - nothing was changed.' -ForegroundColor Red
    exit 1
}
if ($check -eq $true) { Write-Host 'checksum ok' -ForegroundColor Green }
else { Write-Host 'this release publishes no checksum - the download cannot be verified' -ForegroundColor Yellow }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $tmp -Force

# scripts and docs only: a release must never be able to drop a binary or overwrite
# the engine/state folders
Get-ChildItem $tmp -Force |
    Where-Object {
        ($_.PSIsContainer -and $_.Name -eq 'docs') -or
        (-not $_.PSIsContainer -and ($_.Extension -in '.ps1', '.cmd', '.md', '.txt' -or $_.Name -in '.gitignore', 'LICENSE'))
    } |
    ForEach-Object { Copy-Item $_.FullName $Root -Recurse -Force }

Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
Set-Content (Join-Path $Root 'version.txt') $new
Write-Host "Updated to $new. Restart the tool if it is running." -ForegroundColor Green

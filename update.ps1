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
. (Join-Path $PSScriptRoot 'state.ps1')
$project = Get-ProjectRepository
$mine = (Get-Content (Join-Path $Root 'version.txt') -Raw -ErrorAction SilentlyContinue)
$mine = if ($mine) { $mine.Trim() } else { 'unknown' }
$UserAgent = "arma-reforger-mod-downloader/$mine"

try {
    $api = "https://api.github.com/repositories/$($project.id)"
    $headers = @{ 'User-Agent' = $UserAgent }
    $repository = Invoke-RestMethod $api -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
    if ($repository.id -ne $project.id -or $repository.full_name -cne $project.name) {
        throw 'GitHub returned a different update repository.'
    }
    $rel = Invoke-RestMethod "$api/releases/latest" -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
    $releaseUrl = '^' + [regex]::Escape("https://api.github.com/repos/$($project.name)/releases/") + '[1-9][0-9]*$'
    if ($rel.url -cnotmatch $releaseUrl) { throw 'GitHub returned a release outside the update repository.' }
} catch {
    if (-not $Quiet) {
        Write-Host "Could not check GitHub for updates: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    exit 1
}

$new = ([string]$rel.tag_name -replace '^v', '').Trim()
[version]$newV = [version]'0.0'; [version]$mineV = [version]'0.0'
$comparable = [version]::TryParse($new, [ref]$newV) -and [version]::TryParse($mine, [ref]$mineV)
if ($rel.draft -or $rel.prerelease -or $rel.tag_name -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+$' -or !$comparable) {
    if (-not $Quiet) { Write-Host 'The installed or published version could not be verified.' -ForegroundColor Yellow }
    exit 1
}
if ($newV -le $mineV) {
    if (-not $Quiet) { Write-Host "You have the latest version ($mine)." -ForegroundColor Green }
    exit 0
}

Write-Host "New version available: $mine -> $new" -ForegroundColor Cyan
if ($rel.name) { Write-Host "  $($rel.name)" }
if (-not $Install) {
    Write-Host 'Run "2 - Update.cmd" to install it.' -ForegroundColor Yellow
    exit 0
}

$assetName = 'ReforgerModDownloader-scripts.zip'
$assetUrl = "https://github.com/$($project.name)/releases/download/$($rel.tag_name)/$assetName"
$assets = @($rel.assets | Where-Object {
    $_.name -ceq $assetName -and $_.state -ceq 'uploaded' -and $_.size -gt 0 -and
      $_.browser_download_url -ceq $assetUrl -and $_.digest -match '^sha256:[0-9a-f]{64}$'
})
if ($assets.Count -ne 1) {
    Write-Host 'The release does not contain a source update with a valid SHA-256 digest.' -ForegroundColor Red
    exit 1
}
$asset = $assets[0]

$temp = Join-Path ([IO.Path]::GetTempPath()) ('rfmm-update-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $temp 'update.zip'
$payload = Join-Path $temp 'payload'
try {
    $null = [IO.Directory]::CreateDirectory($payload)
    Write-Host "Downloading $assetName..."
    Invoke-WebRequest $assetUrl -OutFile $zip -UseBasicParsing -TimeoutSec 600 -MaximumRedirection 4
    if ((Get-Item -LiteralPath $zip).Length -ne $asset.size -or !(Test-Sha256 $zip ([string]$asset.digest))) {
        throw 'The downloaded update did not match its published SHA-256 digest.'
    }
    Expand-ProjectArchive $zip $payload
    Get-ChildItem -LiteralPath $payload -Force |
        Where-Object {
            ($_.PSIsContainer -and $_.Name -eq 'docs') -or
            (!$_.PSIsContainer -and ($_.Extension -in '.ps1', '.cmd', '.md', '.txt', '.html' -or $_.Name -in '.gitignore', 'LICENSE'))
        } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Root -Recurse -Force }
    Set-Content -LiteralPath (Join-Path $Root 'version.txt') $new
} catch {
    Write-Host "Could not apply the update: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
Write-Host "Updated to $new. Restart the tool if it is running." -ForegroundColor Green

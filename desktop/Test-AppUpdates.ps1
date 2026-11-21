$ErrorActionPreference = 'Stop'
$binary = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\ReforgerModDownloader.exe'
$assembly = [Reflection.Assembly]::LoadFrom($binary)
$feature = $assembly.GetType('AppUpdates', $true)
$release = [Activator]::CreateInstance($assembly.GetType('AppUpdates+Release', $true), $true)
$assetType = $assembly.GetType('AppUpdates+Asset', $true)
$asset = [Activator]::CreateInstance($assetType, $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$newer = $feature.GetMethod('NewerVersion', $flags)
$select = $feature.GetMethod('SelectAsset', $flags)
$release.tag_name = 'v1.2.3'
$current = [version]'1.1.0.0'
if ($newer.Invoke($null, @($release, $current)) -ne [version]'1.2.3.0') { throw 'Newer release was ignored.' }
$release.prerelease = $true
if ($newer.Invoke($null, @($release, $current))) { throw 'Prerelease would be installed.' }
$release.prerelease = $false
$release.tag_name = 'v1.1.0'
if ($newer.Invoke($null, @($release, $current))) { throw 'An equal version would be installed.' }
$release.tag_name = 'v1.0.0'
if ($newer.Invoke($null, @($release, $current))) { throw 'A downgrade was allowed.' }
$release.tag_name = 'v1.2.3'
$asset.name = 'ReforgerModDownloader.exe'
$asset.state = 'uploaded'
$asset.size = 123
$asset.digest = 'sha256:' + ('a' * 64)
$asset.browser_download_url = 'https://github.com/goranbalsic/arma-reforger-mod-downloader/releases/download/v1.2.3/ReforgerModDownloader.exe'
$release.assets = [Array]::CreateInstance($assetType, 1)
$release.assets[0] = $asset
if (!$select.Invoke($null, @($release))) { throw 'Valid release asset was ignored.' }
$asset.digest = ''
$rejected = $false
try { $select.Invoke($null, @($release)) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'An asset without a digest was accepted.' }
$asset.digest = 'sha256:' + ('a' * 64)
$asset.browser_download_url = 'https://example.invalid/ReforgerModDownloader.exe'
$rejected = $false
try { $select.Invoke($null, @($release)) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'A download outside the repository was accepted.' }

$fixture = Join-Path $env:TEMP ('rfmm-app-update-test-' + [guid]::NewGuid())
$runtime = Join-Path $fixture 'app\runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$apply = Join-Path $runtime 'Apply-AppUpdate.ps1'
Copy-Item (Join-Path $PSScriptRoot 'Apply-AppUpdate.ps1') $apply
$target = Join-Path $fixture 'Fixture.exe'
'old' | Set-Content -LiteralPath $target
'new' | Set-Content -LiteralPath "$target.update"
$env:RFMM_UPDATE_TARGET = $target
$env:RFMM_UPDATE_PARENT = '2147483647'
$env:RFMM_UPDATE_DIGEST = '0' * 64
powershell -NoProfile -ExecutionPolicy Bypass -File $apply
if ($LASTEXITCODE -ne 1 -or (Get-Content -LiteralPath $target) -ne 'old') {
  throw 'An invalid update changed the current executable.'
}
$env:RFMM_UPDATE_DIGEST = (Get-FileHash -LiteralPath "$target.update" -Algorithm SHA256).Hash
powershell -NoProfile -ExecutionPolicy Bypass -File $apply
if ($LASTEXITCODE -or (Get-Content -LiteralPath $target) -ne 'new' -or (Test-Path -LiteralPath "$target.update")) {
  throw 'Verified update replacement failed.'
}
'App update checks passed.'

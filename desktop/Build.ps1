param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
$work = Join-Path $source '.desktop-build'
$dist = Join-Path $source 'dist'
$version = (Get-Content (Join-Path $source 'version.txt') -Raw).Trim()
$packageVersion = '1.0.4314.35'
$packageHash = '90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4'
$archive = Join-Path $work 'webview2.zip'
$sdk = Join-Path $work "webview2-$packageVersion"
$payload = Join-Path $work 'payload'
New-Item -ItemType Directory -Force -Path $work,$dist,$payload | Out-Null

if ($Restore -or !(Test-Path $archive)) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $package = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$packageVersion/microsoft.web.webview2.$packageVersion.nupkg"
  Invoke-WebRequest -Uri $package -OutFile "$archive.download" -UseBasicParsing
  Move-Item -LiteralPath "$archive.download" -Destination $archive -Force
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $packageHash) {
  throw 'The WebView2 SDK checksum did not match. Rebuild with -Restore.'
}
Expand-Archive -LiteralPath $archive -DestinationPath $sdk -Force
$managed = Join-Path $sdk 'lib\net462'
$core = Join-Path $managed 'Microsoft.Web.WebView2.Core.dll'
$forms = Join-Path $managed 'Microsoft.Web.WebView2.WinForms.dll'
$loader = Join-Path $sdk 'runtimes\win-x64\native\WebView2Loader.dll'
$files = @(
  'dashboard-core.ps1', 'download-web.ps1', 'make-preset.ps1', 'page.html',
  'preset-scenarios.ps1', 'Setup.ps1', 'state.ps1', 'sync-addons.ps1',
  'trim-config.ps1', 'update-mods.ps1', 'version.txt', 'watchdog.ps1', 'LICENSE', 'NOTICE'
)
foreach ($name in $files) {
  Copy-Item -LiteralPath (Join-Path $source $name) -Destination $payload -Force
}
Copy-Item -LiteralPath $core,$forms,$loader -Destination $payload -Force
Copy-Item -LiteralPath (Join-Path $sdk 'LICENSE.txt') -Destination (Join-Path $payload 'WebView2-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sdk 'NOTICE.txt') -Destination (Join-Path $payload 'WebView2-NOTICE.txt') -Force
$bundle = Join-Path $work 'payload.zip'
$payloadFiles = @($files + 'WebView2-LICENSE.txt' + 'WebView2-NOTICE.txt' +
  'Microsoft.Web.WebView2.Core.dll' + 'Microsoft.Web.WebView2.WinForms.dll' + 'WebView2Loader.dll' |
  ForEach-Object { Join-Path $payload $_ })
Compress-Archive -LiteralPath $payloadFiles -DestinationPath $bundle -Force

$metadata = Join-Path $work 'AssemblyInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("Arma Reforger Mod Downloader")]
[assembly: AssemblyProduct("Arma Reforger Mod Downloader")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
"@ | Set-Content -LiteralPath $metadata -Encoding UTF8

$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$output = Join-Path $dist 'ReforgerModDownloader.exe'
$sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' | ForEach-Object FullName)
& $compiler /nologo /target:winexe /platform:x64 /codepage:65001 /optimize+ "/out:$output" "/resource:$bundle,Payload.zip" `
  "/win32icon:$(Join-Path $PSScriptRoot 'app.ico')" `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
  /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
  "/reference:$core" "/reference:$forms" $metadata @sources
if ($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
$output

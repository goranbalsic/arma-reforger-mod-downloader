$ErrorActionPreference = 'Stop'
$binary = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\ReforgerModDownloader.exe'
$assembly = [Reflection.Assembly]::LoadFrom($binary)
$feature = $assembly.GetType('AppUpdates', $true)
$releaseType = $assembly.GetType('AppUpdates+Release', $true)
$release = [Activator]::CreateInstance($releaseType, $true)
$identity = [Activator]::CreateInstance($assembly.GetType('AppUpdates+Repository', $true), $true)
$identity.id = 1459406111
$identity.full_name = 'goxy701/arma-reforger-mod-downloader'
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
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$capture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\release.json') -Raw
$live = $serializer.Deserialize($capture, $releaseType)
$asset = $select.Invoke($null, @($live, $identity))
if ($asset.name -cne 'ReforgerModDownloader.exe') { throw 'Valid release asset was ignored.' }
$identity.id++
$rejected = $false
try { $select.Invoke($null, @($live, $identity)) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'A release with a different repository ID was accepted.' }
$identity.id--
$originalDigest = $asset.digest
$asset.digest = ''
$rejected = $false
try { $select.Invoke($null, @($live, $identity)) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'An asset without a digest was accepted.' }
$asset.digest = $originalDigest
$asset.browser_download_url = 'https://example.invalid/ReforgerModDownloader.exe'
$rejected = $false
try { $select.Invoke($null, @($live, $identity)) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'A download outside the repository was accepted.' }

$fixture = Join-Path $env:TEMP ('rfmm-app-update-test-' + [guid]::NewGuid())
$discover = $assembly.GetType('SteamEngineDiscovery', $true)
$library = Join-Path $fixture 'Steam Library'
$steamapps = Join-Path $library 'steamapps'
$engineDir = Join-Path $steamapps 'common\Arma Reforger Server'
[void][IO.Directory]::CreateDirectory($engineDir)
$engine = Join-Path $engineDir 'ArmaReforgerServer.exe'
[IO.File]::WriteAllBytes($engine, [byte[]]@())
$libraries = [object[]]::new(1)
$libraries[0] = [string[]]@($library)
$findInLibraries = $discover.GetMethod('FindInLibraries', $flags)
if ($findInLibraries.Invoke($null, $libraries) -ne $engine) {
  throw 'A Steam dedicated server in the default folder was missed without an app manifest.'
}
$custom = Join-Path $steamapps 'common\Custom Reforger Server'
[IO.Directory]::Move($engineDir, $custom)
$engine = Join-Path $custom 'ArmaReforgerServer.exe'
Set-Content -LiteralPath (Join-Path $steamapps 'appmanifest_1874900.acf') '"appid" "1874900" "installdir" "Custom Reforger Server"'
if ($findInLibraries.Invoke($null, $libraries) -ne $engine) {
  throw 'A Steam dedicated server in a custom manifest folder was missed.'
}
if ($discover.GetMethod('FindInFolder', $flags).Invoke($null, @($custom.PSObject.BaseObject)) -ne $engine) {
  throw 'A selected folder containing the dedicated server was missed.'
}
'Existing server discovery checks passed.'
$installPayload = $assembly.GetType('Program', $true).GetMethod('InstallPayload', $flags)
$testLocation = Join-Path $fixture 'extracted-package'
$installArguments = [object[]]@($testLocation.PSObject.BaseObject)
$extracted = $installPayload.Invoke($null, $installArguments)
$sessionData = Join-Path $fixture 'custom session data'
[void][IO.Directory]::CreateDirectory($sessionData)
[IO.File]::WriteAllText((Join-Path $sessionData 'batch1-serverconfig.json'), '{"game":{"mods":[]}}')
$staleToken = @{ token = ('a' * 32); written = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $sessionData 'desktop-token.json'), $staleToken)
$hostType = $assembly.GetType('PowerShellHost', $true)
$instanceFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$sessionToken = [guid]::NewGuid().ToString('N')
$oldData = $env:RFMM_DATA
$reader = $null
try {
  $env:RFMM_DATA = $sessionData
  $reader = $hostType.GetConstructors($instanceFlags)[0].Invoke(
    [object[]]@($extracted.PSObject.BaseObject, $fixture.PSObject.BaseObject, $engine.PSObject.BaseObject, $sessionToken.PSObject.BaseObject, $true))
  $replyTask = $hostType.GetMethod('SendAsync', $instanceFlags).Invoke($reader, @('/status', 'GET'))
  if (!$replyTask.Wait(15000) -or $replyTask.Result.status -ne 200 -or
      ($replyTask.Result.body | ConvertFrom-Json).tok -cne $sessionToken) {
    throw 'The Windows status worker did not use the current desktop session token.'
  }
} finally {
  if ($reader) { $reader.Dispose() }
  [Environment]::SetEnvironmentVariable('RFMM_DATA', $oldData)
}
'Windows status worker session check passed.'
$echoRuntime = Join-Path $fixture 'utf8-worker'
[void][IO.Directory]::CreateDirectory($echoRuntime)
@'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Console]::OutputEncoding = $utf8
$request = [Console]::ReadLine().TrimStart([char]0xFEFF) | ConvertFrom-Json
[Console]::WriteLine('RFMM ' + (@{ status=200; body=$request.path } | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath (Join-Path $echoRuntime 'download-web.ps1') -Encoding Ascii
$savedInput = [Console]::InputEncoding
$reader = $null
try {
  [Console]::InputEncoding = [Text.Encoding]::GetEncoding(1252)
  $reader = $hostType.GetConstructors($instanceFlags)[0].Invoke(
    [object[]]@($echoRuntime.PSObject.BaseObject, $fixture.PSObject.BaseObject, $engine.PSObject.BaseObject, $sessionToken.PSObject.BaseObject, $true))
  $sample = '/test/' + [char]0xE9 + [char]0x65E5 + [char]::ConvertFromUtf32(0x1F680)
  $replyTask = $hostType.GetMethod('SendAsync', $instanceFlags).Invoke($reader, @($sample.PSObject.BaseObject, 'GET'))
  if (!$replyTask.Wait(15000) -or $replyTask.Result.body -cne $sample) {
    throw 'The Windows desktop transport did not round-trip UTF-8 under a legacy console code page.'
  }
} finally {
  if ($reader) { $reader.Dispose() }
  [Console]::InputEncoding = $savedInput
}
'Windows desktop request and response UTF-8 checks passed.'
$notice = Join-Path $extracted 'NOTICE'
$expectedNotice = (Get-FileHash -LiteralPath $notice -Algorithm SHA256).Hash
[IO.File]::WriteAllBytes($notice, (New-Object byte[] (Get-Item -LiteralPath $notice).Length))
$null = $installPayload.Invoke($null, $installArguments)
if ((Get-FileHash -LiteralPath $notice -Algorithm SHA256).Hash -ne $expectedNotice) {
  throw 'Extraction accepted same-length data that differs from the embedded payload.'
}
$runtime = Join-Path $fixture 'app\runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$apply = Join-Path $runtime 'Apply-AppUpdate.ps1'
Copy-Item (Join-Path $PSScriptRoot 'Apply-AppUpdate.ps1') $apply
$target = Join-Path $fixture 'Fixture.exe'
'old' | Set-Content -LiteralPath $target
'new' | Set-Content -LiteralPath "$target.update"
$env:RFMM_UPDATE_TARGET = $target
$env:RFMM_UPDATE_PARENT = '2147483647'
$env:RFMM_UPDATE_RESTART = '0'
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
# Launch the production C# handoff from a running EXE, then verify which binary reopens.
$folder = Join-Path $fixture 'portable app'
[void][IO.Directory]::CreateDirectory($folder)
$oldApp = Join-Path $folder 'Test App.exe'
$newApp = Join-Path $fixture 'Replacement.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$ownerSource = Join-Path $fixture 'Owner.cs'
$nextSource = Join-Path $fixture 'Next.cs'
@"
using System;
using System.IO;
using System.Reflection;
class Owner {
    static void Main() {
        var assembly = Assembly.LoadFrom(Environment.GetEnvironmentVariable("TEST_APP_ASSEMBLY"));
        var updater = assembly.GetType("AppUpdates", true);
        var pendingType = updater.GetNestedType("Pending", BindingFlags.NonPublic);
        var pending = Activator.CreateInstance(pendingType, true);
        pendingType.GetField("Digest", BindingFlags.NonPublic | BindingFlags.Instance)
            .SetValue(pending, Environment.GetEnvironmentVariable("TEST_APP_DIGEST"));
        updater.GetMethod("ApplyWhenClosed", BindingFlags.Static | BindingFlags.NonPublic)
            .Invoke(null, new object[] { Environment.GetEnvironmentVariable("TEST_APP_RUNTIME"), pending, true });
        File.WriteAllText("handoff", "scheduled");
        for (int i = 0; i < 200 && !File.Exists("close"); i++) System.Threading.Thread.Sleep(50);
    }
}
"@ | Set-Content -LiteralPath $ownerSource
@"
using System;
using System.IO;
class Next {
    static void Main() { File.WriteAllText("reopened", Environment.GetEnvironmentVariable("RFMM_HOME") ?? ""); }
}
"@ | Set-Content -LiteralPath $nextSource
& $compiler /nologo /target:exe "/out:$oldApp" $ownerSource
if ($LASTEXITCODE) { throw 'Could not compile the owner fixture.' }
& $compiler /nologo /target:winexe "/out:$newApp" $nextSource
if ($LASTEXITCODE) { throw 'Could not compile the restart fixture.' }
Copy-Item -LiteralPath $newApp -Destination "$oldApp.update"
$digest = (Get-FileHash -LiteralPath $newApp).Hash
$info = [Diagnostics.ProcessStartInfo]::new($oldApp)
$info.WorkingDirectory = $folder
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.EnvironmentVariables['TEST_APP_ASSEMBLY'] = $binary
$info.EnvironmentVariables['TEST_APP_DIGEST'] = $digest
$info.EnvironmentVariables['TEST_APP_RUNTIME'] = $runtime
$info.EnvironmentVariables['RFMM_HOME'] = 'fixture download location'
$owner = [Diagnostics.Process]::Start($info)
try {
  $deadline = [datetime]::UtcNow.AddSeconds(15)
  while (!(Test-Path -LiteralPath (Join-Path $folder 'handoff'))) {
    if ($owner.HasExited -or [datetime]::UtcNow -gt $deadline) { throw 'The running EXE could not start the updater.' }
    Start-Sleep -Milliseconds 50
  }
  if (!(Test-Path -LiteralPath "$oldApp.update") -or (Get-FileHash -LiteralPath $oldApp).Hash -eq $digest) {
    throw 'The updater replaced the EXE while the previous process was still running.'
  }
  [IO.File]::WriteAllText((Join-Path $folder 'close'), '')
  if (!$owner.WaitForExit(15000) -or $owner.ExitCode) { throw 'The owner fixture could not close.' }
  $marker = Join-Path $folder 'reopened'
  $deadline = [datetime]::UtcNow.AddSeconds(20)
  while (!(Test-Path -LiteralPath $marker)) {
    if ([datetime]::UtcNow -gt $deadline) { throw 'The verified replacement did not reopen.' }
    Start-Sleep -Milliseconds 50
  }
  if ((Get-FileHash -LiteralPath $oldApp).Hash -ne $digest -or
      [IO.File]::ReadAllText($marker) -ne 'fixture download location') {
    throw 'The restarted program or its download location changed unexpectedly.'
  }
} finally {
  if (!$owner.HasExited) { $owner.Kill() }
  $owner.Dispose()
}
'App update checks passed.'

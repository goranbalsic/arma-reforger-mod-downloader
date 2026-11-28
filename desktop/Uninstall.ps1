$ErrorActionPreference = 'Stop'

function Test-InFolder([string]$Path, [string]$Folder) {
  $comparison = [StringComparison]::OrdinalIgnoreCase
  $Path.Equals($Folder, $comparison) -or $Path.StartsWith($Folder.TrimEnd('\') + '\', $comparison)
}

function Assert-PhysicalParents([string]$Path) {
  for ($parent = [IO.Directory]::GetParent($Path); $parent; $parent = $parent.Parent) {
    if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Uninstall stopped at a linked parent folder: $($parent.FullName)"
    }
  }
}

function Remove-DownloaderPath([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (!$item) { return }
  if ($item.PSIsContainer) {
    if (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      foreach ($child in (Get-ChildItem -LiteralPath $item.FullName -Force)) {
        Remove-DownloaderPath $child.FullName
      }
    }
    [IO.Directory]::Delete($item.FullName)
  } else {
    Remove-Item -LiteralPath $item.FullName -Force
  }
}

function Remove-DownloaderInstallation([string]$Root, [string]$Local, [string]$Executable, [string[]]$GameProfiles,
    [switch]$Engine, [string]$DataFolder) {
  $Root = [IO.Path]::GetFullPath($Root)
  $Local = [IO.Path]::GetFullPath($Local)
  if ($Root -eq [IO.Path]::GetPathRoot($Root) -or $Local -eq [IO.Path]::GetPathRoot($Local)) { throw 'Select a downloader folder below the drive root.' }
  $Root = $Root.TrimEnd('\')
  $Local = $Local.TrimEnd('\')
  $Executable = [IO.Path]::GetFullPath($Executable)
  $data = if ($DataFolder) { [IO.Path]::GetFullPath($DataFolder) } else { Join-Path $Root 'data' }
  $targets = @(
    (Join-Path $Local 'app'), (Join-Path $Local 'webview'), (Join-Path $Local 'desktop.log'),
    (Join-Path $Local 'desktop.log.1'), (Join-Path $Local 'download-location.txt'),
    $Executable, "$Executable.update"
  )
  if (Test-Path -LiteralPath (Join-Path $data 'batch1-serverconfig.json') -PathType Leaf) {
    $targets += Join-Path $Root 'serverprofile'
    $ownedNames = @('actions.log', 'batch1-serverconfig.json', 'batch1-servers.json', 'batch1-sizes.json',
      'desktop-owner.json', 'desktop-token.json', 'engine-error.log', 'engine-output.log', 'mod-update-available.json',
      'mod-update-batch.json', 'paused.flag', 'preset-scenarios.log', 'queue-revision.txt', 'redownload.json',
      'skipped.json', 'update-progress.json', 'verify.json', 'watchdog-error.log', 'watchdog-output.log', 'watchdog.log')
    $ownedData = @((Get-ChildItem -LiteralPath $data -File -Force) | Where-Object {
      $_.Name -in $ownedNames -or $_.Name -match '^job-[0-9a-f]+\.json$' -or
        ($_.Name -replace '\.(?:corrupt-[0-9-]+|[a-f0-9]{32}\.tmp)$', '') -in $ownedNames
    })
    $targets += $ownedData.FullName
  }
  if ($Engine) {
    $managed = Join-Path $Root 'armar-server'
    $steamcmd = Join-Path $Root 'steamcmd'
    if (Test-Path -LiteralPath (Join-Path $managed 'ArmaReforgerServer.exe') -PathType Leaf) { $targets += $managed }
    if (Test-Path -LiteralPath (Join-Path $steamcmd 'steamcmd.exe') -PathType Leaf) { $targets += $steamcmd }
  }

  foreach ($path in ($targets | Where-Object { $_ })) {
    Assert-PhysicalParents $path
    foreach ($game in $GameProfiles) {
      if (!$game) { continue }
      $game = [IO.Path]::GetFullPath($game).TrimEnd('\')
      if ((Test-InFolder $path $game) -or (Test-InFolder $game $path)) {
        throw "Uninstall would overlap a game folder: $game"
      }
    }
  }
  foreach ($path in ($targets | Where-Object { $_ })) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($true) {
      try { Remove-DownloaderPath $path; break }
      catch [IO.IOException] {
        if ([DateTime]::UtcNow -ge $deadline) { throw }
        Start-Sleep -Milliseconds 250
      }
    }
  }
  $standardData = Join-Path $Root 'data'
  if ($data -eq $standardData -and [IO.Directory]::Exists($data) -and
      !((Get-Item -LiteralPath $data -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and
      !(Get-ChildItem -LiteralPath $data -Force | Select-Object -First 1)) { [IO.Directory]::Delete($data) }
  $defaultRoot = Join-Path $Local 'downloads'
  if ($Root -eq $defaultRoot -and [IO.Directory]::Exists($Root) -and
      !(Get-ChildItem -LiteralPath $Root -Force | Select-Object -First 1)) { [IO.Directory]::Delete($Root) }
  if ([IO.Directory]::Exists($Local) -and
      !(Get-ChildItem -LiteralPath $Local -Force | Select-Object -First 1)) { [IO.Directory]::Delete($Local) }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
  $owner = Get-Process -Id ([int]$env:RFMM_UNINSTALL_PARENT) -ErrorAction SilentlyContinue
  if ($owner -and !$owner.WaitForExit(60000)) { throw 'The downloader is still open.' }
  $profiles = @((Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'My Games/ArmaReforger'), $env:RFMM_UNINSTALL_GAME_PROFILE)
  $local = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Reforger Mod Downloader'
  $root = $env:RFMM_UNINSTALL_ROOT
  Remove-DownloaderInstallation $root $local $env:RFMM_UNINSTALL_EXE $profiles -Engine:($env:RFMM_UNINSTALL_ENGINE -eq '1') -DataFolder $env:RFMM_UNINSTALL_DATA
} catch {
  Add-Type -AssemblyName System.Windows.Forms
  [void][Windows.Forms.MessageBox]::Show("Uninstall could not finish. $($_.Exception.Message)", 'Uninstall', 'OK', 'Warning')
  exit 1
} finally {
  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

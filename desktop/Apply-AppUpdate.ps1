$ErrorActionPreference = 'Stop'
$target = $env:RFMM_UPDATE_TARGET
$pending = "$target.update"
$restart = $env:RFMM_UPDATE_RESTART -eq '1'
$log = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'desktop.log'

function Write-UpdateLog([string]$Message) {
  try { Add-Content -LiteralPath $log -Encoding UTF8 -Value "[$(Get-Date -Format s)] $Message" } catch { }
}

try {
  $owner = Get-Process -Id ([int]$env:RFMM_UPDATE_PARENT) -ErrorAction SilentlyContinue
  if ($owner -and !$owner.WaitForExit(60000)) { throw 'The downloader is still open.' }
  $deadline = [datetime]::UtcNow.AddSeconds(10)
  while ($true) {
    try {
      $actual = (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash
      if ($actual -ne $env:RFMM_UPDATE_DIGEST) { throw 'The staged update failed its SHA-256 check.' }
      [IO.File]::Replace($pending, $target, [NullString]::Value)
      break
    } catch [IO.IOException] {
      if ([datetime]::UtcNow -ge $deadline -or ![IO.File]::Exists($pending)) { throw }
      Start-Sleep -Milliseconds 250
    }
  }
  Write-UpdateLog 'App update installed.'
  if ($restart) {
    Start-Process -FilePath $target -WorkingDirectory (Split-Path -LiteralPath $target)
  }
} catch {
  Write-UpdateLog "App update failed: $($_.Exception.Message)"
  if ($restart) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show("Could not finish the update. Open the downloader again. Details are in $log.",
      'Arma Reforger Mod Downloader', 'OK', 'Warning')
  }
  exit 1
}

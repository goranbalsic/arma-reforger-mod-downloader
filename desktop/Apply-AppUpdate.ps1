$ErrorActionPreference = 'Stop'
$target = $env:RFMM_UPDATE_TARGET
$pending = "$target.update"
$log = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'desktop.log'
try {
  $owner = Get-Process -Id ([int]$env:RFMM_UPDATE_PARENT) -ErrorAction SilentlyContinue
  if ($owner -and !$owner.WaitForExit(15000)) { throw 'The downloader did not close in time.' }
  $actual = (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash
  if ($actual -ne $env:RFMM_UPDATE_DIGEST) { throw 'The staged update failed its SHA-256 check.' }
  [IO.File]::Replace($pending, $target, [NullString]::Value)
  Add-Content -LiteralPath $log -Value "[$(Get-Date -Format s)] App update installed."
} catch {
  Add-Content -LiteralPath $log -Value "[$(Get-Date -Format s)] Could not install app update: $($_.Exception.Message)"
  exit 1
}

# Stops the helper processes of this install: the watchdog and the addon mirror.
# Never touches ArmaReforgerServer (your game server) or any other PowerShell.
#
#   .\stop.ps1
#   .\stop.ps1 -Root <folder>    only processes whose command line names that folder
#
# Closing the dashboard window stops the page and the engine loop; the watchdog and
# the mirror keep running hidden. This is how to stop them.
param([string]$Root)
$ErrorActionPreference = 'Stop'
$Root = if ($Root) { $Root } else { $PSScriptRoot }
$here = $Root.TrimEnd('\')
$stopped = 0

# same identification rule as Get-OwnEngine: only processes whose command line
# carries THIS folder, so another checkout is untouched
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
  Where-Object {
    $_.ProcessId -ne $PID -and
    $_.CommandLine -and
    $_.CommandLine.IndexOf($here, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $_.CommandLine -match '(watchdog|sync-addons)\.ps1'
  }

foreach ($p in @($procs)) {
  Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  $stopped++
  Write-Host ("stopped {0} (pid {1})" -f $(if ($p.CommandLine -match '(watchdog|sync-addons)\.ps1') { $Matches[1] } else { 'helper' }), $p.ProcessId) -ForegroundColor Green
}
if (-not $stopped) { Write-Host 'nothing to stop - the watchdog and the addon mirror are not running for this folder.' -ForegroundColor Yellow }
exit 0

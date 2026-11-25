# Local audit for this repository.
#
#   powershell -File tools\audit.ps1           fast (files, parse, unit tests, analyzer)
#   powershell -File tools\audit.ps1 -Deep     also docs and the live torture test
#
# Every check reports PASS, FAIL or INCOMPLETE. A mandatory check that could not run
# (tool missing, crash) makes the whole audit INCOMPLETE - never PASS. Exit codes:
#   0 = PASS   1 = FAIL   2 = INCOMPLETE
param(
  [switch]$Deep,
  [string]$Root
)
$ErrorActionPreference = 'Stop'
$Root = if ($Root) { (Resolve-Path $Root).Path } else { Split-Path $PSScriptRoot -Parent }
$rows = New-Object System.Collections.Generic.List[object]

function Add-Row([string]$Name, [string]$Status, [bool]$Mandatory, [string]$Detail) {
  $rows.Add([pscustomobject]@{ check = $Name; status = $Status; mandatory = $Mandatory; detail = $Detail })
}

# --- required files (mandatory) -------------------------------------------------
$required = 'state.ps1', 'dashboard-core.ps1', 'download-web.ps1', 'page.html', 'watchdog.ps1', 'trim-config.ps1', 'make-preset.ps1', 'test-units.ps1'
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
Add-Row 'required files' $(if ($missing.Count) { 'FAIL' } else { 'PASS' }) $true $(
  if ($missing.Count) { "missing: $($missing -join ', ')" } else { "$($required.Count) present" })

# --- parse every script (mandatory) ---------------------------------------------
try {
  $bad = @()
  Get-ChildItem $Root -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs.Count) { $bad += "$($_.Name) ($($errs.Count) error(s))" }
  }
  Add-Row 'parse every script' $(if ($bad.Count) { 'FAIL' } else { 'PASS' }) $true $(
    if ($bad.Count) { $bad -join '; ' } else { 'no syntax errors' })
} catch {
  Add-Row 'parse every script' 'INCOMPLETE' $true $_.Exception.Message
}

# --- child processes ------------------------------------------------------------
function Invoke-Child([string]$Exe, [string[]]$ChildArgs) {
  # Start-Process with redirected files, because `& powershell ... 2>&1` under 5.1
  # can turn the child's stderr into a terminating error - a failing test then
  # looked INCOMPLETE instead of FAIL. This returns the real exit code and text.
  $out = [IO.Path]::GetTempFileName()
  $err = [IO.Path]::GetTempFileName()
  try {
    $quoted = @($ChildArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { $_ } })
    $p = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -PassThru -Wait `
      -RedirectStandardOutput $out -RedirectStandardError $err
    $text = @()
    if (Test-Path $out) { $text += @(Get-Content $out -ErrorAction SilentlyContinue) }
    if (Test-Path $err) { $text += @(Get-Content $err -ErrorAction SilentlyContinue) }
    @{ code = $p.ExitCode; output = $text }
  } finally {
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
  }
}

# --- unit tests (mandatory) -----------------------------------------------------
$units = Join-Path $Root 'test-units.ps1'
if (-not (Test-Path $units)) {
  Add-Row 'unit tests' 'INCOMPLETE' $true 'test-units.ps1 not found'
} else {
  try {
    $r = Invoke-Child 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $units)
    $last = @($r.output | Where-Object { "$_".Trim() }) | Select-Object -Last 1
    Add-Row 'unit tests' $(if ($r.code -eq 0) { 'PASS' } else { 'FAIL' }) $true ([string]$last)
  } catch {
    Add-Row 'unit tests' 'INCOMPLETE' $true $_.Exception.Message
  }
}

# --- PSScriptAnalyzer (mandatory: no clean audit without it) ---------------------
try {
  $mod = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1
  if (-not $mod) {
    Add-Row 'PSScriptAnalyzer errors' 'INCOMPLETE' $true 'module not installed'
  } else {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $errs = @(Invoke-ScriptAnalyzer -Path $Root -Recurse -Severity Error -ErrorAction Stop)
    Add-Row 'PSScriptAnalyzer errors' $(if ($errs.Count) { 'FAIL' } else { 'PASS' }) $true $(
      if ($errs.Count) { "$($errs.Count) error(s): $(($errs | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName)" }) -join '; ')" } else { 'none' })
  }
} catch {
  Add-Row 'PSScriptAnalyzer errors' 'INCOMPLETE' $true $_.Exception.Message
}

if ($Deep) {
  # --- docs (optional) ----------------------------------------------------------
  $docs = @('SECURITY.md', 'ARCHITECTURE.md', 'TESTING.md') |
    Where-Object { -not (Test-Path (Join-Path (Join-Path $Root 'docs') $_)) }
  Add-Row 'documentation' $(if ($docs.Count) { 'INCOMPLETE' } else { 'PASS' }) $false $(
    if ($docs.Count) { "missing: $($docs -join ', ')" } else { 'all guides present' })

  # --- backend stress test (optional, isolated) ---------------------------------
  try {
    $sr = Invoke-Child 'powershell' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'tools\Test-Stress.ps1'))
    $line = @($sr.output | Where-Object { "$_" -match 'checks:' }) | Select-Object -Last 1
    Add-Row 'backend stress test' $(if ($sr.code -eq 0) { 'PASS' } else { 'FAIL' }) $false ([string]$line)
  } catch { Add-Row 'backend stress test' 'INCOMPLETE' $false $_.Exception.Message }

  # --- live torture test (optional) --------------------------------------------
  $live = $false
  try { $live = (Invoke-WebRequest 'http://localhost:8123/status' -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { }
  if (-not $live) {
    Add-Row 'live torture test' 'INCOMPLETE' $false 'dashboard not running on localhost:8123'
  } else {
    try {
      $r = Invoke-Child 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'test-torture.ps1'))
      $summary = @($r.output | Where-Object { "$_" -match 'checks:' }) | Select-Object -Last 1
      Add-Row 'live torture test' $(if ($r.code -eq 0) { 'PASS' } else { 'FAIL' }) $false ([string]$summary)
    } catch {
      Add-Row 'live torture test' 'INCOMPLETE' $false $_.Exception.Message
    }
  }
}

$rows | Format-Table @{ n = 'check'; e = { $_.check } }, @{ n = 'type'; e = { if ($_.mandatory) { 'required' } else { 'optional' } } }, status, detail -AutoSize |
  Out-String -Width 200 | Write-Host

$failed = @($rows | Where-Object { $_.status -eq 'FAIL' })
$unknown = @($rows | Where-Object { $_.mandatory -and $_.status -eq 'INCOMPLETE' })
$overall = if ($failed.Count) { 'FAIL' } elseif ($unknown.Count) { 'INCOMPLETE' } else { 'PASS' }
"audit: $overall  (required: $(@($rows | Where-Object { $_.mandatory }).Count), failed: $($failed.Count), not-run: $(@($rows | Where-Object { $_.status -eq 'INCOMPLETE' }).Count))"
if ($overall -eq 'FAIL') { exit 1 }
if ($overall -eq 'INCOMPLETE') { exit 2 }
exit 0

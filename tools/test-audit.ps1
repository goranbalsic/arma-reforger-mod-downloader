# Proves the audit reports the right status:
#   - a failing unit test            -> FAIL      (exit 1)
#   - PSScriptAnalyzer not available -> INCOMPLETE (exit 2)
#   - this repository                -> PASS      (exit 0)
# Run: powershell -File tools\test-audit.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$audit = Join-Path $PSScriptRoot 'audit.ps1'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { "  ok   $Name" } else { "  FAIL $Name - $Detail"; $script:fail++ }
}
function Run-Audit([string[]]$AuditArgs, $ModulePath) {
  $out = [IO.Path]::GetTempFileName()
  $err = [IO.Path]::GetTempFileName()
  $old = $env:PSModulePath
  try {
    if ($null -ne $ModulePath) { $env:PSModulePath = $ModulePath }
    $p = Start-Process -FilePath 'powershell' -NoNewWindow -PassThru -Wait `
      -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$audit`"") + $AuditArgs) `
      -RedirectStandardOutput $out -RedirectStandardError $err
    @{ code = $p.ExitCode; text = ((@(Get-Content $out -ErrorAction SilentlyContinue) + @(Get-Content $err -ErrorAction SilentlyContinue)) -join "`n") }
  } finally {
    $env:PSModulePath = $old
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
  }
}

# 1) a failing unit test must be FAIL, not INCOMPLETE and not PASS
$tmp = Join-Path $env:TEMP ('rfmm-audit-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  foreach ($f in 'state.ps1', 'dashboard-core.ps1', 'download-web.ps1', 'page.html', 'watchdog.ps1', 'trim-config.ps1', 'make-preset.ps1') {
    Copy-Item (Join-Path $root $f) $tmp
  }
  'Write-Host "fixture: always fails"; exit 1' | Set-Content (Join-Path $tmp 'test-units.ps1')
  $r = Run-Audit @('-Root', "`"$tmp`"") $null
  Check 'a failing unit test is FAIL (exit 1)' ($r.code -eq 1 -and $r.text -match 'audit: FAIL') "exit $($r.code)"
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# 2) a missing mandatory tool must be INCOMPLETE, never PASS
$empty = Join-Path $env:TEMP ('rfmm-empty-modules-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $empty | Out-Null
try {
  $r = Run-Audit @() $empty
  Check 'a missing analyzer is INCOMPLETE (exit 2)' ($r.code -eq 2 -and $r.text -match 'audit: INCOMPLETE') "exit $($r.code)"
} finally {
  Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
}

# 3) the real repository must pass
$r = Run-Audit @() $null
Check 'this repository is PASS (exit 0)' ($r.code -eq 0 -and $r.text -match 'audit: PASS') "exit $($r.code)"

""
if ($fail) { "AUDIT SELF-TEST: FAIL ($fail)"; exit 1 }
'AUDIT SELF-TEST: OK'
exit 0

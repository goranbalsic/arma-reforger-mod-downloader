# Testing

| Suite | Coverage |
| --- | --- |
| `test-units.ps1` | State, path rules, queue and preset behavior, progress, Workshop UTF-8 and version parsing. Windows-only checks report explicit skips on Linux. |
| `tools/Test-StateWrites.ps1` | Atomic swaps, cleanup on failure, normalized engine paths, and two processes making 200 writes each. |
| `tools/Test-Stress.ps1` | Worker requests against a mock Workshop API, including queue edits, updates, cancellation, and state checks. `-RunHttpSuites` also runs the rules and torture suites against an isolated legacy dashboard. |
| `test-rules.ps1` | Completed addon integrity, recoverable partials, dashboard JavaScript syntax, and malformed-state recovery. |
| `test-torture.ps1` | Legacy session and request rules, parallel polling, start and pause, and server/refresh workflows. |
| `tools/Test-LinuxStart.py` | Start, trim, Pause, Resume, presets, and watchdog restart against a compiled ELF fixture engine. Runs against source and packaged scripts. |
| `linux/test-desktop.py` | Packaged GTK/WebKit smoke test, Steam discovery and setup retry, rendered labels, confirmation, status latency, and shutdown. |
| `desktop/Test.ps1`, `desktop/Test-AppUpdates.ps1` | Windows worker protocol, packaged files, release identity and digest checks, and update handoff and restart. |
| `tools/audit.ps1` | Checks required files, PowerShell syntax, unit tests, and PSScriptAnalyzer on Windows. A missing check reports `INCOMPLETE`. |

## Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\audit.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-StateWrites.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\Test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\Test-AppUpdates.ps1
```

```bash
pwsh -NoProfile -File ./test-units.ps1
pwsh -NoProfile -File ./tools/Test-StateWrites.ps1
pwsh -NoProfile -File ./tools/Test-Stress.ps1 -RunHttpSuites
python3 tools/Test-LinuxStart.py .
sh linux/package.sh
mkdir -p /tmp/rfmm-test-package
tar xzf dist/ReforgerModDownloader-linux-x64.tar.gz -C /tmp/rfmm-test-package
cp linux/test-desktop.py /tmp/rfmm-test-package/ReforgerModDownloader/
xvfb-run -a /usr/bin/python3 /tmp/rfmm-test-package/ReforgerModDownloader/test-desktop.py
python3 tools/Test-LinuxStart.py /tmp/rfmm-test-package/ReforgerModDownloader/lib
```

CI runs the Windows desktop and audit jobs and the Ubuntu desktop and backend jobs on `main` and pull requests. You can also run CI manually. The jobs use temporary profiles and a local Workshop mock.

To test against the live Workshop, use an empty profile. Install the dedicated server from the packaged app, queue a public mod, and check that it appears under **Library → Installed mods**. Pause, close the app, and reopen it to check that the queue and pause state are saved.

See [Security](SECURITY.md) for release verification.

# Testing

## Suites

### `test-units.ps1` — offline, ~1-2 s
No dashboard, no game, no network. Everything runs in a temp folder. Covers the shared
rules that every other script depends on:

| Group | Checks |
| --- | --- |
| JSON persistence | atomic write refuses a non-path, missing file returns the default, corrupt file is moved aside |
| Engine config | stub has `name`/`scenarioId`/`mods`; repair adds them and turns `mods: null` into an array |
| Preset writer | creates into an empty storage block, updates in place on a second run, one preset only, inside `m_aPresets`; a conf-breaking name is refused and leaves the file byte-identical; no temp file left |
| Trim | deletes a partial the engine would skip, keeps one without markers, no second delete within 30 minutes |
| Completion rule | valid meta passes; deleting an older file invalidates the cache; missing file list, nameless entry, `..`, and absolute paths are rejected |
| Watchdog scan | one refusal per mod, re-reading the same log counts nothing twice, a resumed scan keeps the pending id |
| Checksum | matching digest passes, wrong digest fails, absent digest is "unknown" not a pass |
| Migration | moves old copies and creates the junction; a locked file keeps the source and leaves no empty copy |
| Engine ownership | no match is an empty array, no config path claims no engine |

### `test-torture.ps1` — live dashboard
Runs against a *running* install. Pauses and restarts the download on purpose.
33 checks by default; 37 with `-ServerRoundTrip` (which removes and re-adds a tracked
server, and restores it if the API fails).

Covers: page, `/status`, `/servers`, 404, 403 without and with a wrong token, 96 parallel
polls from 8 clients, 5 starts in a row, pause/start, verify, six mutating routes with
unknown ids, and after all that: valid config, well-formed and unique queued ids, valid
sizes and server files, no repeated mod in a server, no duplicate addon folder, junction
intact, dashboard still answering.

### `test-rules.ps1` - live integrity (manual)
Asserts that every mod the dashboard lists as completed satisfies the same rule and has
not been written to for 2 minutes. Needs a live install with a library.

### `tools/audit.ps1` - local gate
Runs the mandatory checks and reports PASS, FAIL or INCOMPLETE per check and overall.
A mandatory check that could not run makes the audit INCOMPLETE (exit 2) - never PASS.
`-Deep` adds the docs, changelog and the live torture test (optional; a missing dashboard
is INCOMPLETE, not a failure).

| Check | Covered by | Evidence |
| --- | --- | --- |
| engine lock | `test-units.ps1` | a held lock returns `$null` (400 ms timeout against a 4 s holder) and is available afterwards |
| job lifecycle | `test-torture.ps1` | refresh returns a job id, the message names it, polling reaches `done` with a message, server list intact |
| audit statuses | audit + fixtures | PASS (exit 0), INCOMPLETE when the analyzer module is hidden (exit 2), FAIL on a broken script (exit 1) |

Counts: `test-units.ps1` 53 checks; `test-torture.ps1` 38 (42 with `-ServerRoundTrip`).

## Not covered

- A real Steam/Workshop download in CI (needs a 12 GB engine and an account).
- A lock held longer than the 20 s default: the short-timeout path is tested; the
  "waited long enough, then proceeded" path is not.
- The update path end to end (network + release). It is run by hand on every release and
  the result is recorded in the release report.
- WMI failure (`Get-OwnEngine` returning `$null`). The code paths exist; there is no
  simulation test.

## Running

```powershell
powershell -File test-units.ps1
powershell -File test-torture.ps1                 # dashboard must be running
powershell -File test-torture.ps1 -ServerRoundTrip
powershell -File test-rules.ps1                   # live install with addons
powershell -File tools\audit.ps1                  # all mandatory checks
powershell -File tools\audit.ps1 -Deep            # plus docs and live tests
```

Exit code 0 means everything passed; any failed check prints `FAIL` and returns 1.

## CI

`.github/workflows/ci.yml` runs on `windows-latest`:

1. Install PSScriptAnalyzer for Windows PowerShell.
2. Run `tools/audit.ps1` (it parses every script, runs the unit tests, and gates on
   analyzer errors).

If the module cannot be installed, the audit reports INCOMPLETE and the job fails; it
never reports success for a check it could not run.

PSScriptAnalyzer findings at warning level are printed but not enforced.

The torture and rules suites are not in CI: they need a running dashboard and a real
addon library. They are release checks, run by hand and reported with each release.

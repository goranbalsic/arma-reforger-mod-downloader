# Engineering audit

Scope: every script in this repository at `main` (commit `869ab2d` plus the changes in
this release), the dashboard page, state files, tests and release flow.
Runtime assumed: Windows 10/11, Windows PowerShell 5.1, one dashboard process, one
watchdog process, ~300 addons / ~30 GB on disk.

Each finding lists the real root cause and the test that now proves the fix. Severity:
**P0** data loss or false success, **P1** major correctness, **P2** engineering defect,
**P3** improvement.

## P0 — fixed

### 1. Addon migration deleted files that were never moved
`state.ps1` `Initialize-AddonsLink` (previously in `download-web.ps1`)
- Cause: `Move-Item ... -ErrorAction SilentlyContinue` followed by an unconditional
  `Remove-Item` of the old folder. A locked file made the move fail silently and the
  original tree was deleted anyway. A failed move can also leave an **empty**
  destination folder, so checking only "does the target exist" is not enough.
- Repro: open a file inside `<profile>\addons\<Mod>_<id>` without share mode, start the
  dashboard, let it migrate.
- Impact: permanent loss of addon files the user already had.
- Fix: success is judged by the source being gone; empty leftovers are removed; on any
  failure the function returns without deleting anything.
- Test: `test-units.ps1` "keeps the old folder when a move fails", "leaves no empty
  copy in the game folder", "moves old copies and links the folder".

### 2. A meta without a file list counted as a complete addon
`state.ps1` `Test-AddonComplete`
- Cause: `@(@($j.meta.versions)[0].package.files)` — `@($null).Count` is 1 in
  PowerShell, so the block entered the success branch and every nameless entry was
  skipped.
- Repro: `{"meta":{"versions":[{"package":{}}]}}` plus any file.
- Impact: false "installed" state, mods never re-downloaded, presets referencing
  incomplete mods, verify reporting ok.
- Fix: versions/package/files must exist, be non-empty, and every entry needs a name
  and a numeric size.
- Test: "meta without a file list is not complete", "meta entry without a name is not
  complete".

## P1 — fixed

### 3. Completion cache survived a file deletion
`state.ps1` `Test-AddonComplete`
- Cause: cache key was `path + newest file time`. Deleting an older file does not change
  the newest file time, so the cached `true` stayed.
- Impact: a mod missing a file was reported complete by status, verify, queue and sync.
- Fix: cache also keys on the folder's own write time (deleting an entry changes it).
- Test: "deleting an older file invalidates the cached result".

### 4. Watchdog dropped a mod after one real Workshop failure
`watchdog.ps1`
- Cause: the same run log was re-parsed every 15 s and every parse incremented the
  per-mod strike counter. Three ticks (~30 s) turned one refusal into "3 errors" and the
  mod was removed from the queue and written to `skipped.json`.
- Impact: valid mods silently dropped from the batch.
- Fix: `Get-WorkshopFailures` (in `state.ps1`) is a pure, resumable scan — the watchdog
  remembers the file and the last processed line, so each log line is counted once.
- Test: "one refusal per mod is counted", "re-reading the same log counts nothing
  twice", "a resumed scan still attributes the pending mod".

### 5. Updates were installed without any integrity check
`update.ps1`
- Cause: the release zip was downloaded and extracted with no verification, and every
  entry in it was copied into the application folder (a release could add binaries or
  overwrite folders).
- Impact: a truncated or tampered download became executable code; supply-chain surface.
- Fix: compare SHA-256 against the release asset's published `digest` and refuse on
  mismatch; copy only `.ps1/.cmd/.md/.txt/.gitignore/LICENSE/docs`.
- Limit: the digest comes from the same repository — it detects corruption and casual
  tampering, not a compromised release. No code signing is in place.
- Test: "matching sha256 passes", "different sha256 fails", "no digest is unknown, not a
  pass". The end-to-end install is exercised on every release.

### 6. A preset could be written before it was validated
`make-preset.ps1`
- Cause: the settings file was written first and verified afterwards; a name containing
  `{` unbalanced the file and the verification then threw, leaving the user to restore a
  `.bak` by hand.
- Impact: a broken game settings file; recovery required manual work.
- Fix: verification runs on the candidate text before any write; the write is atomic
  (`File.Replace`) and keeps the previous version as a timestamped backup.
  Preset and addon names have quotes replaced and control characters stripped.
- Test: "a conf-breaking preset is refused", "the settings file is unchanged after it",
  "no temp file is left behind".

### 7. Engine mutex was not required everywhere
`download-web.ps1` `Stop-DS`, `trim-config.ps1`, `watchdog.ps1`
- Cause: `Stop-DS` proceeded when `Lock-Engine` returned `$null`; `trim-config.ps1`
  wrote the queue config outside the lock and even when it could not get it; the
  watchdog killed a stalled engine without the lock.
- Impact: a start and a stop/delete could interleave — two engines on one profile, or
  files removed under a live engine.
- Fix: every state-changing path takes `ReforgerEngineCtl`, `Stop-DS` aborts without it,
  the trim holds it across deletion **and** the config write, and the watchdog takes it
  around the kill. The lock is always released in `finally`.
- Test: exercised by `test-torture.ps1` (5 starts in a row, pause/start, refresh) and the
  trim unit tests; a cross-process lock-timeout test was not written (see TESTING).

## P2 — fixed

### 8. Meta paths could point outside the addon
`state.ps1` `Test-AddonComplete`
- Cause: `Join-Path $Path $f.name` with no validation; `..`, an absolute path or an
  alternate data stream verified a file elsewhere on disk.
- Fix: reject `..`, rooted paths and names containing `:`.
- Test: "meta pointing outside the folder is not complete", "meta with an absolute path
  is not complete".

### 9. Network refreshes blocked the whole page
`download-web.ps1`
- Cause: `/refresh-servers` and `/refresh-server` called the API inside the request.
  The listener handles one request at a time, so the page and every button waited for
  the slowest API call (30 s timeout each).
- Impact: the UI appeared frozen during a refresh, and the watchdog could not be driven
  from the page meanwhile.
- Fix: one bounded background job (`Start-Job`, one at a time) does all network work and
  writes a JSON result; `/job?id=` applies it once on the request thread, so queue and
  state changes stay serialised. A second refresh request returns the running job instead
  of starting another process.
- Measured: `/refresh-servers` 0.65 s, `/refresh-server` 0.09 s (previously the full
  round trip). Tests: torture phase "background refresh job" (job id, poll to `done`,
  message, server list unchanged).

## P3 — accepted, not changed

- **The apply step is still synchronous.** When a background refresh finishes, the
  result is written and new mods are queued on the request thread; this can stop and
  start the engine (~2 s). It is fast and must stay serialised, so it is not a job.
- **`/status` costs 0.31-0.38 s warm.** It used to be polled every 400 ms, measuring
  **97% of one core**; at 1 s it measures **31%**, and zero when the page is closed.
  A cached status would cut it further at the cost of stale numbers.
- **No structured log file.** Console + `data\actions.log` + `data\watchdog.log`. They
  are append-only and unbounded; only `watchdog.log` is transition-based. Rotation is a
  known gap.
- **No schema version in state files.** `batch1-serverconfig.json` is owned by the game
  engine; adding fields risks rejection. The other files are additive and readers ignore
  unknown fields. A migration framework is not justified until a format actually changes.
- **`test-rules.ps1` needs a live dashboard and library.** It is a manual integrity
  check, not part of CI.

## Round 2 — findings against the public tree

| Severity | Finding | State |
| --- | --- | --- |
| P2 | There was no local audit tool, and nothing distinguished "check could not run" from "check passed". | Fixed: `tools/audit.ps1` reports PASS / FAIL / INCOMPLETE; a mandatory check that cannot run makes the audit INCOMPLETE (exit 2), never PASS. |
| P2 | Refreshing servers ran inside the HTTP request: one slow API call froze the page and other requests. | Fixed: one bounded background job per refresh; network only in the job, apply on the request thread. |
| P3 | `Lock-Engine` always waited 20 s, so contention could not be tested. | Fixed: timeout parameter (default unchanged) + contention test. |
| — | Mutex enforcement, preset validation and meta validation (reported again for `mod-manager/…`, a path that does not exist in this repository) were already fixed in 1.0.12/1.0.13; re-verified with tests rather than assumed. | Verified |

The audit now distinguishes a skipped check from a passing one: PSScriptAnalyzer had been
installed only for PowerShell 7, and the 5.1 audit reported INCOMPLETE until it was made
available to the runtime the tool actually uses. That is the behaviour the review asked
for.

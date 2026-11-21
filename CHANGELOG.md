# Changelog

## 1.0.16

- Queue trimming now holds the engine lock while reading and saving the queue, drops invalid mod IDs, and records the first retry for partial downloads.
- Addon mirroring reports copy failures and handles lowercase IDs and bracketed folder names.

## 1.0.15

- Adding a server lists it once (memory and `batch1-servers.json`), stops the engine
  before writing the queue, and aborts when the process list cannot be read.
- `Test-ModId` validates ids at every API boundary; invalid ids are dropped with a
  warning and trim skips them before any filesystem call.
- An unreadable queue is no longer read as "queue empty" by the watchdog.
- Corrupt `skipped.json` cannot break `/status`; sizes reads use an explicit default;
  `a..b.pak` is a legal file name again.
- Every queue write goes through `Update-Cfg` under the engine mutex.
- Mutating routes are POST-only (405) and every response carries `X-Frame-Options`,
  `nosniff` and a CSP.
- Blocking API calls time out after 10 s; the dependency walk stops at 20 s / 200 mods.
- Dashboard functions live in `dashboard-core.ps1`; the page is `page.html` (copied by
  the updater).
- New handler unit tests, `Stop Mods Download.cmd` + `stop.ps1`, and an audit that
  reports FAIL vs INCOMPLETE (with `tools\test-audit.ps1` proving it).
- Fixed: `Add-Member` failed for an all-digit mod id, so sizes were silently dropped.
- Docs, user agent and version references cleaned up.
## 1.0.14

- `tools/audit.ps1`: PASS / FAIL / INCOMPLETE. A mandatory check that cannot run makes the
  audit INCOMPLETE, never PASS. CI now runs it.
- Refresh runs in one bounded background job; the page stays responsive (0.65 s instead of
  waiting for the API) and the result is applied on the request thread. A second refresh
  returns the running job.
- `Lock-Engine` takes a timeout so contention is testable; a held lock is never stolen.
- Tests: 53 unit checks (lock contention, incomplete preset exclusion, created/modified
  files, negative size) and 38 torture checks (refresh job lifecycle).
- Docs: architecture, testing and audit updates for the job mechanism and the audit gate.

## 1.0.13

Reliability, integrity and performance pass.

- Addon migration never deletes a folder that was not fully moved; a failed move
  leaves the source untouched and creates no empty copy.
- Completion rule rejects a meta without a file list, entries without a name or size,
  and paths that point outside the addon. The cache now notices a deleted file.
- Presets are verified before the settings file is touched, written atomically, and keep
  a timestamped backup. Names with control characters are sanitised.
- The watchdog counts each Workshop failure once instead of re-counting the same log
  line every 15 s (that dropped valid mods after one refusal).
- Engine lock is required to stop the engine, held across the trim's delete + config
  write, and taken before the watchdog kills a stalled engine.
- Updates verify the release's SHA-256 and only copy scripts and docs.
- Page polls every 1 s instead of 400 ms (a status build costs ~0.3 s of one core).
- `docs/` added, CI added, unit tests extended from 24 to 39 checks.

## 1.0.12

- Preset generation uses the shared completion rule.
- `Stop-DS` / trim / watchdog mutex gaps closed.
- Meta validation and cache fingerprint fixes.

## 1.0.11

- Partial downloads that the engine would skip are cleaned up (once per 30 min per mod).
- Start on an empty queue no longer reports a phantom unfinished download, and clears
  Pause.
- Add mod / Start read the disk instead of a 3-second-old cache.
- Per-server Refresh and Remove; shorter README.

## 1.0.10

- Partial-cleanup fix for mods stuck at a fixed size.
- Torture test added.

## 1.0.6 – 1.0.9

Setup path fix, engine config repair, one addons folder (junction), per-server refresh,
presets, update check. Released versions before the reliability pass; only the newest
release is kept on GitHub.

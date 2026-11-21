# Reliability report — 1.0.13

## 1. Initial repository assessment

`goranbalsic/arma-reforger-mod-downloader`, branch `main`, clean tree at `869ab2d`
before this pass. Windows PowerShell 5.1 target. One dashboard process, one watchdog
process, ~300 addons / ~30 GB. No CI, three test scripts, no `docs/`.

## 2. Issues I found independently

| Severity | Issue |
| --- | --- |
| P1 | The watchdog re-read the same run log every 15 s and added its failures again, so ONE Workshop refusal became "3 errors" and the mod was dropped from the queue and written to `skipped.json`. |
| P1 | `update.ps1` installed the release with no integrity check and copied every entry in the zip into the app folder. |
| P1 | `make-preset.ps1` wrote the settings file first and verified afterwards; a preset name with `{` left a broken file that needed a manual `.bak` restore. |
| P2 | `Test-AddonComplete` accepted `meta` entries like `../outside.pak` or `C:\Windows\win.ini`. |
| P2 | The page polled `/status` every 400 ms; measured 97% of one CPU core while the page was open. |
| P3 | `Queue-Missing` used an unapproved verb; one unused test variable. |

## 3. Issues confirmed from the earlier review

All five were accurate:

1. Migration could delete files that were not moved — **confirmed**, and worse than
   described: a failed move leaves an *empty* destination folder, so checking only "the
   target exists" still deletes the source.
2. Completion cache missed a deleted older file — **confirmed**.
3. A meta without a file list counted as complete — **confirmed** (`@($null).Count -eq 1`).
4. Mutex not enforced in `Stop-DS`, trim and the watchdog kill — **confirmed**.
5. Presets accepted any folder with a `meta` file — **confirmed**.

## 4. Issues that were incorrect or not reproducible

None of the five failed to reproduce. One detail was imprecise: the review blamed the
migration on permissions and locked files only. The dangerous part is the silent target
folder created by a failed move, which the proposed fix ("check the destination") would
still have missed.

## 5. Files modified

`state.ps1` (completion rule, cache key, meta path validation, migration, `Test-Sha256`,
`Get-WorkshopFailures`), `download-web.ps1` (migration call, `Stop-DS` lock, missing-to-
queue rename, 1 s poll), `trim-config.ps1` (lock across delete + write, abort paths),
`watchdog.ps1` (resumable failure scan, lock around kill), `make-preset.ps1` (verify
before write, atomic replace, name sanitising, shared completion rule), `update.ps1`
(digest verification, copy whitelist), `test-units.ps1` (45 checks), `README.md`,
`CHANGELOG.md`, `docs/*`, `.github/workflows/ci.yml`.

## 6. Features preserved

Dashboard endpoints and page, server browser, per-server Refresh/Remove, presets
(create and update), verify, pause/resume, queue management, watchdog behaviour, pointer
junction, update check. No state or config format changed; no user data was migrated or
re-downloaded.

## 7. Improvements implemented

- Migration is non-destructive and testable (moved to `state.ps1`).
- One completion rule everywhere: status, verify, trim, presets, sync, resume.
- Preset writes are validated, atomic and backed up.
- Updates are checksum-verified and restricted to scripts and docs.
- The engine lock is required for every state-changing operation and is always released
  in `finally`.
- The watchdog counts failures once, and takes the engine lock before killing.
- The page's polling cost dropped from 97% to 31% of one core.

## 8. Security vulnerabilities fixed

- Untrusted update artefact executed without verification (now SHA-256, fail-closed on
  mismatch).
- Arbitrary file drops from a release archive (now a whitelist).
- Meta-driven path traversal outside an addon (now rejected).
- No new secrets, no new network listeners, no permission changes.

## 9. Tests added

Unit: meta without a list, nameless entry, `..`, absolute path, cache invalidation on file
deletion, preset refusal without writing, no temp file left, resumable failure scan (3),
SHA-256 (3), migration success/failure/no-empty-copy (3), trim 30-minute limit.

Live: `test-torture.ps1` extended earlier in this release cycle covers auth, invalid ids,
parallel polling, server remove/re-add and state-file damage.

## 10. Tests actually executed

| Check | Result |
| --- | --- |
| PowerShell parse, all `.ps1` | 0 errors |
| PSScriptAnalyzer (Error severity, module installed locally) | 0 errors, 98 warnings (Write-Host by design, best-effort catches) |
| `test-units.ps1` | **45 checks, 0 failures** |
| `test-torture.ps1` (live dashboard) | **33 checks, 0 failures** |
| Live verify of the installed library | 299 ok, 0 partial, 0 pending, 0 suspects |
| SHA-256 against the real release asset | valid asset accepted, one-byte-corrupted copy refused |
| Real re-download after change | deleted mod re-fetched, queue emptied (10 s) |
| Update install from a release | exercised on 1.0.12 → 1.0.13 (see release notes) |

## 11. Exact results

`units: OK` / `TORTURE: OK`, exit code 0. No skipped checks in these runs. The CI
workflow was authored but has not run on GitHub yet — it is not reported as passing.

## 12. Performance measurements

Same machine, 299 addons:

| Operation | Before | After |
| --- | --- | --- |
| `/status` warm | 0.31-0.38 s | unchanged (0.31-0.38 s) |
| `/status` cold | ~1.0 s | unchanged |
| `/servers` | 0.01 s (memory) | unchanged |
| Verify 299 mods | 0.57 s | unchanged |
| Dashboard CPU while page open | **97% of one core** | **31%** (poll 400 ms → 1 s) |
| Working set | 146 MB | 146 MB |

## 13. Backward compatibility

- `data/*.json` formats unchanged; a new `data/redownload.json` is additive.
- Engine config keys (`mods`, `name`, `scenarioId`) unchanged.
- Launcher preset format unchanged; existing presets are updated in place.
- Dashboard routes and page behaviour unchanged, except the poll interval.
- `version.txt` is the only release artefact that changes on install.

## 14. Remaining risks

1. The dashboard is synchronous: `Refresh all` with many servers blocks other requests.
2. No authentication beyond loopback binding + the CSRF token; other local users could
   drive it.
3. Updates are checksum-verified but not signed.
4. Logs are not rotated.
5. A mod the engine can never complete is retried once per 30 minutes indefinitely.
6. Empty `catch` blocks remain where a failure is genuinely non-fatal (best-effort
   cleanup); they are reviewed but not logged.

## 15. Checks blocked by environment

- GitHub Actions: authored, not executed here (no runner). Marked UNVERIFIED.
- Real Workshop download in CI: impossible without a 12 GB engine and an account.
- PowerShell 7: the tool targets 5.1; 7 was not exercised.
- Cross-process mutex timeout (>20 s hold): no automated test.

## 16. Score

**8.5 / 10.** Data-integrity paths are now tested and fail safely; the completion rule is
single-sourced; the update path verifies content. It is not a 10 because the HTTP
architecture is still synchronous, CI has not run on GitHub, there is no signed release,
and logging has no rotation or structured format.

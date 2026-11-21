# Architecture

A local tool that drives the free Arma Reforger dedicated server as a download engine,
plus a browser page that controls it.

## Components

| File | Role |
| --- | --- |
| `download-web.ps1` | Entry point. Creates state files, links the engine folder, starts the watchdog and the mirror, serves the page and the JSON routes (`HttpListener`, one request at a time, port 8123). |
| `state.ps1` | Shared rules, dot-sourced by every script: `Save-Json`/`Read-Json` (atomic, corrupt-file recovery), `Test-AddonComplete` (the single completion rule + cache), `Get-OwnEngine` (ownership by config path in the command line), `Lock-Engine` (named mutex `ReforgerEngineCtl`), `Repair-Cfg`, `Initialize-AddonsLink`, `Test-Sha256`, `Get-WorkshopFailures`. |
| `watchdog.ps1` | Restarts the engine when it exits, when it is silent for 5 minutes with mods left, and stops it when the queue empties. Skips a mod after 3 Workshop refusals. Single instance via a named mutex. |
| `trim-config.ps1` | Runs before every engine start: drops completed mods from the queue config, deletes partial folders the engine would skip (with a 30-minute retry limit), writes the config under the engine lock. |
| `sync-addons.ps1` | Mirrors completed mods into the game folder. No-op when the engine folder is already a junction; one folder per mod id. |
| `make-preset.ps1` | Writes or updates a launcher preset from a server's modlist. Verifies the candidate text, then replaces the settings file atomically with a backup. |
| `Setup.ps1`, `update.ps1` | One-time engine install (SteamCMD), and release update with SHA-256 verification. |
| `tools/audit.ps1` | Local gate: mandatory checks (files, parse, unit tests, analyzer) with PASS/FAIL/INCOMPLETE. A check that cannot run makes the audit INCOMPLETE, never PASS. |
| `download-web.ps1` (page) | Single HTML document with inline CSS/JS, polls `/status`. |

## Data flow

1. The user adds a server → the API (`api.reforgermods.net`) returns its modlist and
   sizes → the list is appended to the engine config (`data/batch1-serverconfig.json`).
2. `Start` stops/validates, trims the config and launches `ArmaReforgerServer.exe` with
   `-config` and `-profile serverprofile`.
3. The engine downloads into `serverprofile/addons`, which is a **junction** to
   `Documents/My Games/ArmaReforger/addons`, so each mod is stored once, where the game
   reads it.
4. The page computes state from the filesystem (`Get-DirMap`) and the engine log; the
   watchdog restarts a dead or stalled engine; `trim-config` keeps the config under the
   engine's 1 MB download-list limit.

## Files and ownership

| File | Owner | Notes |
| --- | --- | --- |
| `data/batch1-serverconfig.json` | the engine | The DS rewrites it on exit; never modify while it runs. Has `name`/`scenarioId`, which the engine requires. |
| `data/batch1-sizes.json` | dashboard | Workshop sizes per mod id. |
| `data/batch1-servers.json` | dashboard | Tracked servers and their last known modlists. |
| `data/redownload.json` | trim | Last partial-cleanup attempt per mod id (30-minute limit). |
| `data/actions.log`, `data/watchdog.log` | append-only | Action trail and watchdog transitions. |
| `data/paused.flag` | dashboard | While present, the watchdog restarts nothing. Cleared by Start. |
| `data/skipped.json` | watchdog | Mods skipped after repeated Workshop errors. |

## Background jobs

The HTTP loop handles one request at a time, so a network call inside a request blocks
the page and every other button. Network refreshes therefore run in a single bounded
`Start-Job` process:

1. `/refresh-servers` or `/refresh-server` starts the job (or returns the one already
   running) and answers in well under a second with a job id.
2. The job fetches modlists and any unknown sizes and writes `data/job-<id>.json`. It does
   not touch shared state.
3. The page polls `/job?id=<id>`. On the request thread, `Complete-RefreshJob` merges the
   result (sizes, change markers), queues new mods (stopping/starting the engine under
   the mutex), saves state, removes the temp file and the job, and returns
   `{ state: done | failed, msg | error }`.

One job at a time bounds the number of background processes. If a job finishes and nobody
collects it, the next refresh discards it. The apply step stays synchronous on purpose:
it is where shared state changes, and serialising it removes a whole class of races.

## Concurrency

- One named mutex (`ReforgerEngineCtl`) serialises start, stop, trim and the watchdog's
  kill. It is held across the whole critical operation and always released in `finally`;
  an abandoned mutex (crashed holder) is taken over safely.
- The dashboard is single-threaded: requests are serialised by the HTTP loop, so
  in-process races are not possible. Cross-process races are the mutex's job.
- `Get-OwnEngine` identifies "our" engine by the config path in its command line, so a
  server the user runs themselves is never touched.

## Failure recovery

- State files are written to a temp file and swapped in; a corrupt file is moved aside
  (`*.corrupt-<timestamp>`), never deleted, and defaults are used.
- An interrupted download is resumed by Start (folders that are incomplete are re-queued).
- A partial folder that the engine would mistake for installed is deleted (once per 30
  minutes) and downloaded again.
- The update keeps the previous scripts only implicitly (git users) — no automatic rollback
  of scripts; the release archive is verified before copying.

## Why not Rust

The workload is process orchestration, JSON, filesystem checks and a small HTTP server.
Measured hot paths are disk enumeration (~300 folders) and network waits; neither is
CPU-bound. A rewrite would add a toolchain and lose the "no build step, edit and run"
property, with no measurable gain. It would only make sense if the dashboard had to serve
many users concurrently, which it explicitly does not.

# Architecture

The downloader uses the Arma Reforger dedicated server to fetch Workshop addons into a local profile. Windows hosts the dashboard in WebView2. Linux uses GTK 3 and WebKitGTK.

## Request paths

- The desktop hosts send one JSON request per line to `download-web.ps1 -Desktop` and accept replies prefixed with `RFMM `. The main worker handles actions. A read-only worker serves `/status` and `/completed` while the main worker runs an action.
- `page.html` uses delegated event listeners and a per-document script nonce. The Windows host applies the nonce as a response header. The Linux host applies it to the dashboard and its WebKit bridge.
- The legacy browser dashboard accepts loopback HTTP requests on port 8123. State changes require a session token in the `X-RFMM-Token` header.

## Downloads and state

- `dashboard-core.ps1` implements the queue, status, and Workshop handlers. `workshop-api.ps1` sets limits on redirects, request time, and decoded response size.
- `state.ps1` handles atomic writes, addon validation, and process ownership by normalized configuration path. Queue edits and engine start or stop calls share one lock. Each data directory has a second lock for Workshop sizes and tracked server lists.
- `trim-config.ps1` removes completed addons from the queue before each engine start. `watchdog.ps1` restarts an owned engine when its queue still has work, and records repeated Workshop failures.
- The engine writes under `serverprofile/addons`. Windows can link that folder to the game's addons with a junction. Linux can link to an explicitly configured `RFMM_GAME_PROFILE` with a symlink.
- `make-preset.ps1` reads installed metadata, builds a preset, checks its structure, and atomically replaces the game settings with a backup.

## Packaging

`desktop/Build.ps1` embeds the Windows runtime. The launcher verifies cached files before reuse. `linux/package.sh` assembles the Linux launcher and its PowerShell scripts. Both packages include `repository.txt` and `version.txt`. The release workflow builds and exercises both packages before publication.

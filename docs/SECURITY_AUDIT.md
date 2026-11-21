# Security audit

Scope: the dashboard, the scripts that act on the machine, the update path, and the
data they handle. This is a local desktop tool; it has no server-side component and no
user accounts.

## What is protected, and how

| Area | Measure |
| --- | --- |
| Dashboard network exposure | Listener prefix is `http://localhost:8123/`. Windows HttpListener binds a `localhost` prefix to loopback; the page is not reachable from the LAN. |
| State-changing requests | Every route that changes state (`/start`, `/pause`, `/verify`, `/queue-server`, `/resume-all`, `/clear-queue`, `/make-preset`, `/add-server`, `/refresh-servers`, `/refresh-server`, `/remove-server`, `/add-mod`) requires a per-process token `?t=...`; a request without it gets 403. This blocks another website in the same browser from driving the tool (CSRF). |
| Token exposure | The token is served in `/status` so an open page survives a dashboard restart. Anything that can read that response is already running as the same user on the same machine. |
| Shell injection | No `cmd /c`, no `Invoke-Expression`, no string-built command lines. `Start-Process` receives fixed executables with `-ArgumentList` values; mod ids are validated with `Test-ModId` (16 hex, upper-cased) at every API boundary and invalid ones are dropped before they can reach a file name; server ids are only looked up, never interpolated into a command. `robocopy` arguments are folder paths produced from validated ids. |
| Path traversal | Addon folder names must match `*_<16 hex>`. Meta file entries are rejected if they contain `..`, are rooted, or contain `:` (alternate data stream), so a meta cannot verify a file outside its own folder. |
| Update integrity | The release zip's SHA-256 is compared with the digest GitHub publishes for the asset; a mismatch aborts before anything is copied. Only `.ps1/.cmd/.md/.txt`, `.gitignore`, `LICENSE` and `docs` are copied into the app folder. |
| Secrets | None in this repository. No credentials are read, written or logged. |
| Local data written | `data/` (queue, sizes, server lists, logs), `serverprofile/` (engine profile), and the game's settings file for presets. Preset writes are atomic and keep a timestamped backup. |
| Background jobs | A refresh runs in one `Start-Job` process with the same user rights. It writes `data/job-<id>.json` (server names, mod ids, sizes - no secrets) which is deleted when the result is applied. A second refresh is refused while one runs, so at most one extra process exists. |
| Addon writes | Only inside the addons folder, through the engine or in a migration that refuses to delete anything it did not move. |

## What is NOT protected

- **No authentication on the dashboard.** Any process or user session on this machine
  that can reach `localhost:8123` can read `/status` (including the action token) and
  then act. This is by design for a single-user desktop tool; do not run it on a shared
  terminal where other users are untrusted.
- **The update digest is not a signature.** It is fetched over TLS from the same GitHub
  release as the zip. It detects corruption and partial downloads; it does not protect
  against a compromised GitHub account or repository. A signing key would be needed for
  that, and is not implemented.
- **Third-party content is trusted as delivered.** Mods come from the official Workshop
  through Steam; the tool does not sandbox them. A malicious mod runs with the game's
  privileges.
- **The dedicated server is pinned by SteamCMD, not by hash.** A Steam-side compromise is
  outside this tool's control.
- **`data\actions.log` records who pressed what.** It contains local paths and mod names,
  no credentials or tokens (the request token is explicitly excluded).

## Verified behaviour

- 403 without a token and with a wrong token; 404 for unknown routes (`test-torture.ps1`).
- 96 parallel `/status` requests answered; invalid ids on all 13 mutating routes rejected
  (`test-torture.ps1`).
- Corrupt, empty and missing state files do not stop the dashboard; a corrupt file is
  moved aside, never deleted (`Read-Json`).

## Residual risks

1. An attacker with code execution as this user already owns the machine; the token adds
   no protection at that level.
2. Release signing is absent (see above).
3. Logs grow without rotation; disk exhaustion is possible on a very long-running install.

# Security

## Local access

- The Windows and Linux desktop dashboards talk to their worker over standard input and output. The browser dashboard accepts loopback connections with an allowed Host and a matching Origin when supplied.
- State changes require POST and a constant-time session-token check. The legacy browser sends the token in `X-RFMM-Token`. Its `/status` response omits the token.
- Dashboard scripts use a per-document nonce and delegated handlers. The packaged Linux test checks that markup-like names render as literal text, and that queue clearing opens a confirmation dialog.
- The engine defaults to `127.0.0.1`, stays hidden from the server browser, and advertises one player slot.
- The Workshop client requires HTTPS outside the loopback test fixture, limits redirects, decoded response size, and request time. Queue identifiers are validated before use in filenames. Addon metadata is checked against its own folder.
- Desktop logs rotate at roughly 2 MiB. Legacy action and watchdog logs can continue growing. Those logs record mod and server names and exclude session tokens.

## Update trust

The Windows and source updaters require `goxy701/arma-reforger-mod-downloader` and GitHub repository ID `1459406111`. They load release metadata from the numeric repository endpoint and reject redirects. They check each download against its canonical URL, size, and SHA-256 digest. The source updater validates archive destinations before extraction. Windows checks each extracted runtime file against the embedded payload before reuse.

The release workflow publishes build-provenance attestations. The app checks the release digest automatically. To verify a downloaded file's provenance independently, run `gh attestation verify FILE -R goxy701/arma-reforger-mod-downloader`. Attestation verification is a manual step.

The Windows SteamCMD bootstrap has a pinned SHA-256. SteamCMD self-updates and the dedicated-server depot come from Valve and use SteamCMD's verification. Linux uses the distribution's SteamCMD package. Workshop mods run under the game when loaded.

The legacy dashboard is intended for one trusted desktop user. A local process with access to the page can obtain the browser session token.

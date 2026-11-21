# Arma Reforger Mod Downloader

Pick a server and download its missing Workshop mods before you join. Reforger Mod Downloader is a Windows x64 desktop app. It uses the free Arma Reforger dedicated server to download mods into the addons folder your game already uses.

## Get started

1. Download and open **ReforgerModDownloader.exe** from the [latest release](../../releases/latest).
2. Choose where to keep the download engine, then select **Install engine**. Allow about 20 GB for setup and additional space for your mods.
3. In **Find mods**, search for your server and select **Add server**. Go to **Downloads** and select **Start / Resume**.

The app uses the Microsoft Edge WebView2 Runtime for its window. If Windows is missing it, install the Evergreen Runtime. [Microsoft WebView2 download](https://developer.microsoft.com/microsoft-edge/webview2/)

For a single addon, use **Find a Workshop mod**. You can search by name, author, or the 16-character mod ID.

## Managing downloads

**Download status** shows progress for the current batch and resets when it finishes. **Downloading now** shows which files are coming in, and **Queue** shows what’s left. Use **Pause** to take a break and **Start / Resume** to pick up again. Use **Remove** next to a mod or **Clear queue** to cancel queued downloads and keep any files already on disk.

Under **Tracked servers**, use **Queue first** to put a server’s missing mods at the front of the queue. **Refresh** queues mods that were added to the server since your last refresh. **Remove** takes the server off your list and keeps its queued and installed mods.

Once the downloads finish, close Arma Reforger and click **Make preset** next to the server. The preset includes its installed mods. Click it again after downloading more to update the same preset.

In **Library**, use **Update installed mods**, **Update tracked servers’ mods**, or **Update mods** next to a server. To update a single mod, select **Update** under **Completed**. These actions check Workshop versions in the background and download newer revisions when available.

Select **Cancel updates** to stop a check or remove its queued updates. Finished updates, partial files, and unrelated downloads stay on disk or in the queue.

## Files, updates, and shutdown

Your mods live in `Documents\My Games\ArmaReforger\addons`. The download engine and queue are saved in the folder selected during setup. The default is `%LOCALAPPDATA%\Reforger Mod Downloader\downloads`.

To use an existing installation, close its legacy dashboard and put the executable next to its `armar-server` and `data` folders. To update the desktop app, close it and replace the executable. Your queue, engine, and installed mods carry over.

Active downloads can finish in the background after you close the app. To stop them first, select **Pause** and then close the window.

## If something gets stuck

- **The app won’t open.** Check that the WebView2 Runtime is installed. Startup errors are saved in `%LOCALAPPDATA%\Reforger Mod Downloader\desktop.log`.
- **Downloads won’t start.** Check the dashboard message and whether another dedicated server is running.
- **One mod stays in the queue.** Refresh its server and click **Start / Resume**. The downloader can retry an incomplete installation.
- **A preset doesn’t appear.** Close the game and run **Make preset** again. The game writes its settings when it exits.

## Development

Run `powershell -NoProfile -ExecutionPolicy Bypass -File desktop\Build.ps1` to build `dist\ReforgerModDownloader.exe`. The executable bundles the existing PowerShell scripts, the interface, and the WebView2 SDK files. It uses a private process stream for desktop requests.

Run `powershell -File test-units.ps1` for the offline unit suite. See the [testing guide](docs/TESTING.md) before running the live tests.

## Verify a download

Windows builds are unsigned. You can build the executable from the tagged source, or compare a release download’s SHA-256 with the digest GitHub records for that asset:

```powershell
Get-FileHash .\ReforgerModDownloader.exe -Algorithm SHA256
gh release view v1.1.0 --repo goranbalsic/arma-reforger-mod-downloader --json assets --jq '.assets[] | select(.name == "ReforgerModDownloader.exe") | .digest'
```

The desktop CI workflow tests and attests the executable it builds on `main`. For that workflow’s artifact, run `gh attestation verify .\ReforgerModDownloader.exe -R goranbalsic/arma-reforger-mod-downloader`. The v1.1.0 release was built locally, so use the SHA-256 check for it.

The desktop interface talks to its PowerShell worker over standard input and output. Workshop and server data come from ReforgerMods.net, and initial engine setup downloads SteamCMD from Steam. The dedicated server fetches mod files. Build dependencies, runtime scripts, and tests are in this repository.

[Architecture](docs/ARCHITECTURE.md) · [Engineering audit](docs/ENGINEERING_AUDIT.md) · [Security audit](docs/SECURITY_AUDIT.md) · [Changelog](CHANGELOG.md) · [PolyForm Noncommercial 1.0.0](LICENSE) · [Copyright notice](NOTICE)

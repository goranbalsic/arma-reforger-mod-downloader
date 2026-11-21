# Arma Reforger Mod Downloader

Download **Arma Reforger Workshop mods before joining a multiplayer server**. Search for a server to queue its full mod list, or find a single mod by name, author, or Workshop ID. The desktop app skips installed mods when building a server queue, checks for updates, and creates launcher presets from installed mods.

[**Download for Windows x64**](https://github.com/goranbalsic/arma-reforger-mod-downloader/releases/latest/download/ReforgerModDownloader.exe) · [**Linux x64 preview**](#install-on-linux-x64) · [**Release notes**](../../releases/latest)

## Install on Windows x64

1. Open **ReforgerModDownloader.exe** from the [latest release](../../releases/latest).
2. Choose where to keep the download engine, then select **Install engine**. Allow about 20 GB for setup and additional space for your mods.
3. In **Find mods**, search for your server and select **Add server**. Go to **Downloads** and select **Start / Resume**.

The app uses the Microsoft Edge WebView2 Runtime for its window. If Windows is missing it, install the Evergreen Runtime. [Microsoft WebView2 download](https://developer.microsoft.com/microsoft-edge/webview2/)

## Install on Linux x64

Open the latest successful run on `main` in [GitHub Actions](https://github.com/goranbalsic/arma-reforger-mod-downloader/actions/workflows/ci.yml?query=branch%3Amain). Download the **ReforgerModDownloader-linux-x64** artifact, extract it and the included TAR archive, then run `./ReforgerModDownloader` from the extracted app folder. Linux uses native SteamCMD and the native Arma Reforger dedicated server.

Install PowerShell 7 (`pwsh`), SteamCMD, and the GTK 3 and WebKitGTK 4.1 Python bindings from your distribution. The Ubuntu and Debian packages for the window are `python3-gi`, `gir1.2-gtk-3.0`, and `gir1.2-webkit2-4.1`. Select **Install engine** on first launch.

The default data folder is `~/.local/share/reforger-mod-downloader` (or the corresponding folder under `XDG_DATA_HOME`). Mods go into its `serverprofile/addons` directory. To share mods with a Steam Proton install and enable launcher presets, set `RFMM_GAME_PROFILE` to the complete path of the game’s `Documents/My Games/ArmaReforger` folder before first launch. For a custom engine location, set `RFMM_HOME`.

## Download a server’s mod list or a single Workshop mod

For a full mod list, open **Find mods → Find a server**, then select **Add server**. For a single addon, use **Find a Workshop mod** and search by name, author, or the 16-character mod ID. Open **Downloads** and select **Start / Resume** when you’re ready.

## Pause, resume, and update mods

**Download status** shows progress for the current batch and resets when it finishes. **Downloading now** shows which files are coming in, and **Queue** shows what’s left. Use **Pause** to take a break and **Start / Resume** to pick up again. Use **Remove** next to a mod or **Clear queue** to cancel queued downloads and keep any files already on disk.

Under **Tracked servers**, use **Queue first** to put a server’s missing mods at the front of the queue. **Refresh** queues mods that were added to the server since your last refresh. **Remove** takes the server off your list and keeps its queued and installed mods.

Once the downloads finish, close Arma Reforger and click **Make preset** next to the server. The preset includes its installed mods. Click it again after downloading more to update the same preset.

In **Library**, use **Update installed mods**, **Update tracked servers’ mods**, or **Update mods** next to a server. To update a single mod, select **Update** under **Completed**. These actions check Workshop versions in the background and download newer revisions when available.

In current desktop builds from [GitHub Actions](https://github.com/goranbalsic/arma-reforger-mod-downloader/actions/workflows/ci.yml?query=branch%3Amain), select **Cancel updates** to stop a check or remove its queued updates. Finished updates, partial files, and unrelated downloads stay on disk or in the queue.

## Frequently asked questions

### Do I need a Steam account for setup?

The app installs the free Arma Reforger dedicated server through SteamCMD’s anonymous login. The dedicated server fetches the mods.

### Can I download mods from a password-protected server?

Server search can queue a full mod list when the server publishes it. If the list is private or unavailable, you can still queue individual Workshop mods by name or ID.

### Can I create a launcher preset for a server?

Yes. After the downloads finish, close the game and select **Make preset** next to the tracked server. The preset includes the mods that are installed. On Linux, set `RFMM_GAME_PROFILE` as described in the [Linux setup section](#install-on-linux-x64).

## Files, updates, and shutdown

On Windows, your mods live in `Documents\My Games\ArmaReforger\addons`. The download engine and queue are saved in the folder selected during setup. The default is `%LOCALAPPDATA%\Reforger Mod Downloader\downloads`.

To use an existing installation, close its legacy dashboard and put the executable next to its `armar-server` and `data` folders. To update the desktop app, close it and replace the executable. Your queue, engine, and installed mods carry over.

Active downloads can finish in the background after you close the app. To stop them first, select **Pause** and then close the window.

## If something gets stuck

- **The Windows app won’t open.** Check that the WebView2 Runtime is installed. Startup errors are saved in `%LOCALAPPDATA%\Reforger Mod Downloader\desktop.log`.
- **Downloads won’t start.** Check the dashboard message and whether another dedicated server is running.
- **One mod stays in the queue.** Refresh its server and click **Start / Resume**. The downloader can retry an incomplete installation.
- **A preset doesn’t appear.** Close the game and run **Make preset** again. The game writes its settings when it exits.

## Development

Run `powershell -NoProfile -ExecutionPolicy Bypass -File desktop\Build.ps1` to build `dist\ReforgerModDownloader.exe`. The executable bundles the existing PowerShell scripts, the interface, and the WebView2 SDK files. It uses a private process stream for desktop requests.

Build the Linux archive with `sh linux/package.sh`.

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

# Arma Reforger Mod Downloader

Pick a server and download its missing Workshop mods before you join. The downloader runs on Windows 10 or 11 with PowerShell 5.1. It uses the free Arma Reforger dedicated server to fetch the files and puts them in the same addons folder your game already uses.

## Get started

1. Download **arma-reforger-mod-downloader.zip** from the [latest release](../../releases/latest). Extract it to a folder you plan to keep.
2. Double-click **1 - Setup.cmd**. Allow about 20 GB of free space for setup. The dedicated server takes roughly 12 GB, and the mods you choose need space of their own.
3. Run **Start Mods Download.cmd** and leave its console window open. The dashboard opens in your browser at <http://localhost:8123>.
4. Under **Find a server**, search for the server you want and click **Add server**. Its missing mods appear in **Queue**. Click **Start / Resume** to download them.

For a single addon, use **Find a Workshop mod**. You can search by name, author, or the 16-character mod ID.

## Managing downloads

**Download status** shows overall progress. **Downloading now** shows which files are coming in, and **Queue** shows what’s left. Use **Pause** to take a break and **Start / Resume** to pick up again.

Under **Tracked servers**, use **Queue first** to prioritize a server. **Refresh** checks its current mod list and queues new additions. **Remove** takes the server off your list. Its queued downloads and installed mods stay where they are.

Once the downloads finish, close Arma Reforger and click **Make preset** next to the server. The preset includes its installed mods. Click it again after downloading more to update the same preset.

## Files, updates, and shutdown

Your mods live in `Documents\My Games\ArmaReforger\addons`. Inside the downloader folder, `serverprofile\addons` links to that directory, `armar-server` holds the dedicated server, and `data` holds the queue and tracked servers.

Run **2 - Update.cmd** to install the latest release over the existing scripts. Your queue, engine, and installed mods carry over. The start script also checks for updates when you launch it.

Closing the browser tab leaves the downloader running. To shut it down, pause downloads, close the dashboard console, and run **Stop Mods Download.cmd** to stop this installation’s background helpers.

## If something gets stuck

- **The dashboard won’t open.** Check that the console is still open, then visit <http://localhost:8123>. Another program using port 8123 can prevent the dashboard from starting.
- **Downloads won’t start.** Check the dashboard message and whether another dedicated server is running.
- **One mod stays in the queue.** Refresh its server and click **Start / Resume**. The downloader can retry an incomplete installation.
- **A preset doesn’t appear.** Close the game and run **Make preset** again. The game writes its settings when it exits.

## Development

Run `powershell -File tools\audit.ps1` for the local checks. Exit codes are 0 for pass, 1 for failure, and 2 when a required check could not run. For the offline unit suite alone, run `powershell -File test-units.ps1`. The live dashboard tests change the running download session. See the [testing guide](docs/TESTING.md) before running them.

[Architecture](docs/ARCHITECTURE.md) · [Engineering audit](docs/ENGINEERING_AUDIT.md) · [Security audit](docs/SECURITY_AUDIT.md) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)

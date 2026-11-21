# Arma Reforger Mod Downloader

Downloads a whole server's mods into your game's `addons` folder, with a local web
page as the control panel. Windows 10/11, PowerShell 5.1, MIT.

## Quick start

1. Download the newest `.zip` from [Releases](../../releases/latest) and unpack it anywhere.
2. Run `1 - Setup.cmd` once. It installs the free dedicated server (~12 GB) that does
   the downloading. Keep ~20 GB free.
3. Run `Start Mods Download.cmd`. The page opens at <http://localhost:8123>.
4. Search for a server, press **Add server**, then **Start / Resume**.

## The page

| Button / panel | What it does |
| --- | --- |
| Server browser | Search live servers, add one, its missing mods are queued |
| Queue | Only mods still missing; row buttons: Queue first, Make preset, Refresh, Remove |
| Downloading now | Per-mod progress and speed |
| Completed | Every mod the tool has assembled |
| Add individual mods | Workshop search by name, author, or mod id |
| Start / Pause / Verify / Clear queue / Queue all missing | The main actions |
| Make preset | Launcher preset with that server's installed mods; press again to update it |
| Refresh (row or Refresh all) | Pull the modlist again, queue what is new, report a changed list |
| Remove | Drops the server from the list only; mods stay on disk and in the queue |

## Where things go

| What | Where |
| --- | --- |
| Mods (the game reads these) | `Documents\My Games\ArmaReforger\addons` |
| Download engine | `armar-server\` in the tool's folder |
| Engine output folder | `serverprofile\addons` - a directory link to the game folder |
| State (queue, sizes, servers) | `data\` |

Each mod is stored once, straight in the folder the game reads.

## Updating

`2 - Update.cmd` installs the newest release over the scripts. `Start Mods Download.cmd`
checks once at startup. The engine, your queue and your mods are never touched.

## Problems

- **Nothing downloads.** Another `ArmaReforgerServer.exe` is running; close it and press Start.
- **A mod stays missing.** Press Refresh, then Start. A partial download the engine would
  skip is deleted and fetched again.
- **Make preset does nothing.** Close the game first - it rewrites its settings file on exit.
- **The page will not open.** Something else uses port 8123, or the console window is closed.

## Tests

- `powershell -File test-units.ps1` - offline checks of the shared rules, about a second.
- `powershell -File test-torture.ps1` - beats on a running dashboard: every route, wrong
  ids, a wrong action token, parallel polling, state-file damage. Add `-ServerRoundTrip`
  for the remove/re-add test (needs the Workshop API).

## Docs

[Architecture](docs/ARCHITECTURE.md) · [Engineering audit](docs/ENGINEERING_AUDIT.md) ·
[Security](docs/SECURITY_AUDIT.md) · [Testing](docs/TESTING.md) · [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).

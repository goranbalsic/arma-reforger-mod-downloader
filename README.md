# Reforger Mod Manager

Downloads Arma Reforger Workshop mods to your PC and puts them where the game
reads them. Two ways to use it:

- **A whole server** — pick a server, and every mod it runs is queued.
- **Individual mods** — search the Workshop by name, author, or mod id and add
  just what you want. Dependencies come along.

It can also write a launcher preset, so the launcher shows the right mod set for a
server in one click.

Windows 10 or 11. No Steam account. No game launch needed.

---

## Install

1. Open [Releases](../../releases) and download the newest `.zip`.
2. Right-click the zip, **Extract All**, and put the folder anywhere (Desktop is
   fine). Do not run it from inside the zip.
3. Double-click **`1 - Setup.cmd`**. Wait for "Ready."
4. Double-click **`Start Mods Download.cmd`**.

If Windows says "Windows protected your PC", click **More info**, then
**Run anyway**. That appears because the files are new and unsigned, not because
anything is wrong with them.

A browser opens at `http://localhost:8123/`. Keep the black window open while the
tool runs; that window is the program.

### What setup does

It downloads about 1.4 GB once: SteamCMD, then the free Arma Reforger dedicated
server. The tool uses that server as its download engine.

It needs it because the Workshop has no public download link. Files go only to a
signed-in game or to the dedicated server. The server installs with Steam's
anonymous login, so no account is used.

---

## Download a server's mods

1. In **Server browser**, type part of a server name and press Enter.
2. Press **Add server** on the one you want. Its mods are queued at the end.
3. Press **Start**.

The tool downloads each mod, checks every file against the mod's own file list,
then copies it into your game's addons folder.

## Download single mods

1. In **Download individual mods**, type a mod name, an author name, or the
   16-character mod id from a workshop link.
2. Press **Add** on a result. It joins the Queue, and its dependencies are added
   with it.
3. Press **Start**.

## Reading the screen

| What you see | What it means |
| --- | --- |
| `86.78 GB / 86.78 GB` | size of the mods you picked, as they sit in your addons folder |
| `in your addons folder: 86.9 GB` | the folder itself, read from disk |
| ⟳ next to a queue row | that mod is downloading right now |
| `mods assembled` | mods that passed the file check |
| **Verify mods** | re-checks everything against the Workshop sizes |

**Pause** stops the downloader and keeps everything downloaded so far.
**Start** continues. **Clear queue** empties the queue and never deletes files.

## Presets

Press **Make preset** on a server row. The tool writes a launcher preset with the
mods of that server that you actually have installed, so the launcher can load
them in one click. Presets are only written when the game is closed.

---

## Where things go

| What | Where |
| --- | --- |
| Mods (what the game reads) | `Documents\My Games\ArmaReforger\addons` |
| Download engine | `armar-server\` in the tool's folder |
| Working copy of downloads | `serverprofile\` in the tool's folder |
| Saved lists and sizes | `data\` in the tool's folder |

Moving or deleting the tool's folder does not touch your installed mods.

---

## If something goes wrong

**Setup fails.** Run `1 - Setup.cmd` again; the download resumes. Check that you
are online and have ~2 GB free.

**Nothing opens in the browser.** Type `http://localhost:8123/` yourself.

**A mod never finishes.** The Workshop sometimes refuses a single mod. The tool
skips a mod after three refusals and names it on the page. Remove it from the
queue and carry on.

**A downloaded mod does not appear in the game.** Open the addons folder and look
for a folder ending in that mod's id. If it is missing, press Start again; only
the missing mods are fetched.

**Antivirus flags `Start Mods Download.cmd`.** It is a one-line file that starts
PowerShell. You can open any `.ps1` file here in Notepad and read it.

---

## Advanced

Two environment variables move the big folders (optional):

```
set RFMM_HOME=D:\reforger\home     REM engine + working copy
set RFMM_DATA=D:\reforger\data     REM saved lists and sizes
```

Set them in the same window you start the tool from.

## Uninstall

Delete the tool's folder. Your mods stay in
`Documents\My Games\ArmaReforger\addons`; delete the ones you no longer want
there.

---

## Notes

- Mods come from the official Workshop, through the official dedicated server.
  Nothing is re-hosted.
- No telemetry. The tool talks to the Workshop API for search and sizes, and to
  Steam for the engine.
- Windows PowerShell 5.1 is enough; it ships with Windows.
- MIT licensed. Issues and pull requests welcome.

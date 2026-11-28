import importlib.machinery
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
from threading import Thread
import time
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit
from unittest.mock import Mock, patch


SERVER_ID = "11111111-1111-1111-1111-111111111111"
MOD_ID = "BBBBBBBBBBBBBBBB"
SERVER = {
    "id": SERVER_ID, "name": "North Coast | Conflict", "scenarioName": "Conflict - Everon",
    "players": 87, "maxPlayers": 128, "region": "london", "platforms": ["pc", "xbox", "psn"],
    "modCount": 1, "online": True, "battlEye": True,
    "mods": [{"id": MOD_ID, "name": "Field Radio", "version": "1.4.0", "size": 1048576}],
}
MOD = {
    "id": MOD_ID, "name": "Field Radio", "author": "Équipe Everon", "version": "1.5.0",
    "size": 1048576, "summary": "Voice and text channels for squads.", "tags": ["SYSTEMS"],
    "subscriberCount": 1500, "description": 'Field radio <em data-rfmm-fixture>markup</em> & “quotes”.',
    "dependencies": [], "screenshots": ["https://example.invalid/image/foreign.jpg"],
}


class SlowWorkshop(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if query.get("search") == ["latency-test"]:
            time.sleep(2)
        routes = {
            "/v2/servers": {"data": [SERVER], "meta": {"totalServers": 1, "totalPages": 1}},
            f"/v2/servers/{SERVER_ID}": {"server": SERVER},
            f"/v2/servers/{SERVER_ID}/history": {"points": [{"t": 1700000000, "avg": 54, "max": 104}]},
            "/v2/mods": {"data": [MOD], "meta": {"totalMods": 1, "totalPages": 1}},
            f"/v2/mods/{MOD_ID}": {"mod": MOD},
            f"/v2/mods/{MOD_ID}/versions": {"data": {"versions": [{"version": "1.5.0", "published": True}]}},
            f"/v2/mods/{MOD_ID}/versions/1.5.0": {"data": {"version": "1.5.0", "changelog": "Improved radios.\nUpdated UI."}},
        }
        reply = json.dumps(routes.get(url.path, {}), ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)
        except (BrokenPipeError, ConnectionResetError):
            # The smoke test closes the app while this request is still pending.
            pass

    def log_message(self, *_args):
        pass


with tempfile.TemporaryDirectory(prefix="reforger-linux-") as fixture:
    os.environ["RFMM_HOME"] = fixture
    os.environ["RFMM_DATA"] = str(Path(fixture) / "data")
    os.environ.pop("RFMM_GAME_PROFILE", None)
    workshop = ThreadingHTTPServer(("127.0.0.1", 0), SlowWorkshop)
    Thread(target=workshop.serve_forever, daemon=True).start()
    os.environ["RFMM_API"] = f"http://127.0.0.1:{workshop.server_port}/v2"
    os.environ["RFMM_TEST_ALLOW_HTTP"] = "1"
    launcher = Path(__file__).with_name("ReforgerModDownloader")
    loader = importlib.machinery.SourceFileLoader("reforger", str(launcher))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    app = importlib.util.module_from_spec(spec)
    loader.exec_module(app)

    steamcmd = Path(fixture) / "fixture-steamcmd"
    steamcmd.write_text("""#!/usr/bin/python3
import os
from pathlib import Path
import sys

args = sys.argv[1:]
target = Path(args[args.index("+force_install_dir") + 1])
attempts = target / "attempts.txt"
attempt = int(attempts.read_text()) + 1 if attempts.exists() else 1
attempts.write_text(str(attempt))
if "+app_info_update" not in args or os.readlink("/proc/self/fd/0") != "/dev/null":
    sys.exit(2)
if attempt == 1:
    print("Missing configuration")
    sys.exit(3)
engine = target / "ArmaReforgerServer"
engine.touch()
engine.chmod(0o755)
sys.exit(3)
""", encoding="utf-8")
    steamcmd.chmod(0o755)
    setup = app.Downloader()
    setup.update_progress = Mock(return_value=False)
    with patch.object(app.shutil, "disk_usage", return_value=SimpleNamespace(free=24 * 1024**3)):
        setup.install_engine(str(steamcmd))
    if (app.ENGINE.parent / "attempts.txt").read_text() != "2" or not os.access(app.ENGINE, os.X_OK):
        raise SystemExit("SteamCMD did not retry setup and report the installed engine.")

    # Discover a native Steam engine in a second library before installing another copy.
    profile = Path(fixture) / "user"
    apps = profile / ".local/share/Steam/steamapps"
    apps.mkdir(parents=True)
    other = Path(fixture) / "Steam Library"
    native = other / "steamapps/common/Reforger Server/ArmaReforgerServer"
    native.parent.mkdir(parents=True)
    native.touch(mode=0o755)
    (apps / "libraryfolders.vdf").write_text(f'"path" "{other}"')
    (other / "steamapps/appmanifest_1874900.acf").write_text('"installdir" "Reforger Server"')
    with patch.dict(os.environ, {"HOME": str(profile)}), patch.object(app, "ENGINE", Path(fixture) / "uninstalled"):
        if app.find_engine() != native:
            raise SystemExit("Could not detect the native engine in a Steam library.")
        (other / "steamapps/appmanifest_1874900.acf").unlink()
        default_folder = native.parent.with_name("Arma Reforger Server")
        native.parent.rename(default_folder)
        native = default_folder / native.name
        if app.find_engine() != native:
            raise SystemExit("Could not detect the native engine without a Steam manifest.")
        native.chmod(0o644)
        if app.find_engine() is not None:
            raise SystemExit("An engine without execute permissions was accepted.")
        proton = "steamapps/compatdata/1874880/pfx/drive_c/users/steamuser/Documents/My Games/ArmaReforger"
        assert app.find_game_profile() == profile / ".local/share/Steam" / proton
        (other / "steamapps/appmanifest_1874880.acf").touch()
        assert app.find_game_profile() == other / proton and not app.find_game_profile().exists()

    for remove_engine in (False, True):
        uninstall = Path(fixture) / f"uninstall-{remove_engine}"
        launcher = uninstall / "package/ReforgerModDownloader"
        manifest = launcher.parent / "lib/.package-files"
        manifest.parent.mkdir(parents=True)
        manifest.write_text("page.html\n")
        (manifest.parent / "page.html").touch()
        launcher.touch()
        home = uninstall / "home"
        data = home / "data"
        data.mkdir(parents=True)
        (data / "batch1-serverconfig.json").touch()
        unrelated = data / "keep.txt"
        unrelated.touch()
        engine = home / "armar-server/ArmaReforgerServer"
        engine.parent.mkdir()
        engine.touch()
        game = uninstall / "game"
        game.mkdir()
        (game / "keep.pak").touch()
        private = home / "serverprofile"
        private.mkdir()
        (private / "addons").symlink_to(game, target_is_directory=True)
        app.uninstall_package(launcher, manifest, home, data, game, remove_engine)
        assert not launcher.exists() and not private.exists() and not (data / "batch1-serverconfig.json").exists()
        assert engine.exists() != remove_engine and (game / "keep.pak").is_file() and unrelated.is_file()

    app.DATA.mkdir(exist_ok=True)
    (app.DATA / "batch1-serverconfig.json").write_text(json.dumps({
        "game": {"name": "Test", "scenarioId": "fixture", "mods": [
            {"modId": "ABCDEF0123456789", "name": "Linux fixture", "size": 128}
        ]}
    }), encoding="utf-8")

    class SmokeTest(app.Downloader):
        passed = False
        probe_started = False
        screenshots_started = False
        screenshots_done = False
        observed = "The WebView has not evaluated a document yet."

        def do_activate(self):
            # A server installed while setup is open must take the place of setup.
            with patch.object(app, "find_engine", return_value=None):
                super().do_activate()
            self.install.clicked()

        def open_dashboard(self):
            super().open_dashboard()
            if self.window.get_child() is not self.view or not self.view.get_visible():
                self.observed = "The downloader did not replace engine setup."
                self.quit()
                return
            app.GLib.timeout_add(500, self.check_queue)

        def check_queue(self):
            self.view.evaluate_javascript(
                "JSON.stringify({uri:location.href, queue:document.getElementById('queue')?.textContent,"
                " notice:document.getElementById('say')?.textContent, title:document.title,"
                " bridge:typeof window.receiveReply, text:document.body?.textContent.slice(0, 100),"
                " probe:window.statusProbe, checking:document.getElementById('gbtxt')?.textContent.startsWith('Checking')})",
                -1, None, app.ORIGIN, None, self.check_result, None,
            )
            return not self.passed

        def check_result(self, view, result, _data):
            try:
                self.observed = view.evaluate_javascript_finish(result).to_string()
            except app.GLib.Error as error:
                self.observed = str(error)
                return
            state = json.loads(self.observed)
            probe = state.get("probe")
            if probe and probe.get("finished") and not probe.get("passed"):
                self.window.close()
            elif probe and probe.get("passed"):
                if self.screenshots_done:
                    self.passed = True
                    self.window.close()
                elif not self.screenshots_started:
                    self.screenshots_started = True
                    self.capture_layouts()
            elif ("Linux fixture" in state.get("queue", "") and not state.get("notice")
                  and not state.get("checking") and not self.probe_started):
                self.probe_started = True
                self.view.evaluate_javascript("""
                    (() => {
                      const probe = window.statusProbe = {actionDone:false, finished:false};
                      const transfer = (amount, id='one') => ({queueRevision:'a',running:true,active:[{id,b:amount}]});
                      const initial = sampleTransferRate(null,transfer(0),0);
                      const firstRate = sampleTransferRate(initial,transfer(524288),250);
                      const changedMod = sampleTransferRate(firstRate,transfer(10485760,'two'),500);
                      const idleRate = sampleTransferRate(firstRate,transfer(524288),3000);
                      const resumedRate = sampleTransferRate(idleRate,transfer(1048576),3250);
                      probe.speed = firstRate.speed === 2097152 && changedMod.speed === 0 &&
                                    idleRate.speed === 0 && resumedRate.speed === 2097152;
                      const name = '<em data-rfmm-fixture>text</em> & "quotes" and ' + String.fromCodePoint(0x2028);
                      const id = 'BBBBBBBBBBBBBBBB';
                      probe.sharedPoll = tick() === tick();
                      const inText = selector => {
                        const target = document.querySelector(selector);
                        return target.textContent.includes(name) && !target.querySelector('[data-rfmm-fixture]');
                      };
                      renderActive([{id, name, b:12}]);
                      const activeBar = document.querySelector('#act [role="progressbar"]');
                      probe.unknownSize = !activeBar.hasAttribute('aria-valuenow') &&
                                          document.getElementById('act').textContent.includes('12 B transferred');
                      renderQueue([{id, name}], {});
                      renderRec([{id, name, b:1}]);
                      BR = [{id, name, players:0, maxPlayers:1, modCount:1}];
                      renderBrowse();
                      SRV = {servers:[{id, name, haveCount:0, mods:[{id, name}]}]};
                      renderSrv({[id]:1}, {}, {});
                      probe.liveServerCount = document.querySelector('#srv summary').textContent.includes('1 / 1 downloaded');
                      renderSrv({}, {}, {});
                      MRES = {mods:[{id, name, author:name, size:1}], page:1, pages:1, total:1};
                      renderMods();
                      probe.mediaOrigins =
                        cdnImage('https://ar-gcp-cdn.bistudio.com/image/test/file.jpg') !== '' &&
                        cdnImage('https://ar-gcp-cdn.bistudio.com.attacker.invalid/image/test/file.jpg') === '' &&
                        cdnImage('https://ar-gcp-cdn.bistudio.com/image/../elsewhere') === '' &&
                        cdnImage('https://user@ar-gcp-cdn.bistudio.com/image/test/file.jpg') === '';
                      availableUpdates = [{modId:id, name, version:'2.0.0'}];
                      renderAvailableUpdates();
                      probe.textOnly = ['#act','#queue','#rec','#bs','#srv','#mres','#availableUpdatesList'].every(inText);
                      probe.updateControls = document.getElementById('applyAllUpdates').textContent === 'Update all' &&
                          document.querySelector('#availableUpdatesList button').dataset.id === id;
                      probe.noInlineHandlers = ![...document.querySelectorAll('*')].some(element =>
                        [...element.attributes].some(attr => /^on[a-z]+$/i.test(attr.name)));
                      const dialog = document.getElementById('confirmAction');
                      document.getElementById('bclear').click();
                      probe.confirmed = dialog.open;
                      dialog.querySelector('[value="cancel"]').click();
                      renderAll();
                      fetch('/search-mods?q=latency-test').then(() => { probe.actionDone = true; });
                      setTimeout(async () => {
                        const start = performance.now();
                        const response = await fetch('/status');
                        probe.elapsed = performance.now() - start;
                        const statusPassed = response.ok && !probe.actionDone && probe.elapsed < 1000 &&
                                       probe.textOnly && probe.noInlineHandlers && probe.confirmed && probe.speed &&
                                       probe.sharedPoll && probe.unknownSize && probe.liveServerCount && probe.updateControls &&
                                       probe.mediaOrigins;
                        try {
                          await checkDirectory();
                          probe.passed = statusPassed;
                        } catch (error) {
                          probe.discoveryError = String(error);
                        } finally {
                          probe.finished = true;
                        }
                      }, 150);
                      async function waitFor(selector,expectedText) {
                        for (let attempt = 0; attempt < 80; attempt++) {
                          const element = document.querySelector(selector);
                          if (element && (!expectedText || element.textContent.includes(expectedText))) return element;
                          await new Promise(resolve => setTimeout(resolve, 75));
                        }
                        throw new Error('Did not render ' + selector);
                      }
                      async function checkDirectory() {
                        document.querySelector('nav a[href="#servers"]').click();
                        const serverId = '11111111-1111-1111-1111-111111111111';
                        const server = await waitFor('#bs [data-id="' + serverId + '"]');
                        if (!server.textContent.includes('North Coast')) throw new Error('Server name changed.');
                        if (document.querySelector('#bstatus span').textContent !== '1 server') throw new Error('Server count label is incorrect.');
                        server.click();
                        await waitFor('#historyPlot canvas');
                        const filter = await waitFor('#serverModFilter');
                        filter.value = 'nothing matches';
                        filter.dispatchEvent(new Event('input', {bubbles:true}));
                        if (!document.querySelector('[data-mod-row]').hidden) throw new Error('Mod filter did not hide its row.');
                        filter.value = '';
                        filter.dispatchEvent(new Event('input', {bubbles:true}));
                        document.querySelector('[data-action=export-config]').click();
                        const config = JSON.parse(document.querySelector('.export-config').value);
                        if (config.game.mods[0].version !== '1.4.0') throw new Error('Export changed the server version.');
                        document.querySelector('[data-mod-row] [data-action=mod-details]').click();
                        const description = await waitFor('#inspection .description');
                        if (description.querySelector('[data-rfmm-fixture]') || !description.textContent.includes('<em ') ||
                            !document.getElementById('inspectionBody').textContent.includes('Équipe')) {
                          throw new Error('Workshop details broke text escaping or UTF-8.');
                        }
                        document.getElementById('modVersions').open = true;
                        (await waitFor('[data-action=version-notes]')).click();
                        await waitFor('.changelog[data-loaded]');
                        if (!document.querySelector('.changelog').textContent.includes('Updated UI.')) throw new Error('Release notes did not load.');
                        document.getElementById('inspection').close();
                        document.querySelector('nav a[href="#discover"]').click();
                        await waitFor('#mres .mod-card [data-id="BBBBBBBBBBBBBBBB"]', 'Field Radio');
                        if (!document.getElementById('mres').textContent.includes('Équipe')) throw new Error('Workshop name is unreadable.');
                        if (document.querySelector('#mstatus span').textContent !== '1 mod') throw new Error('Workshop count label is incorrect.');
                        document.querySelector('nav a[href="#downloads"]').click();
                      }
                    })()
                """, -1, None, app.ORIGIN, None, None, None)

        def capture_layouts(self):
            folder = os.environ.get("RFMM_SCREENSHOTS")
            if not folder:
                self.screenshots_done = True
                return
            directory = Path(folder)
            directory.mkdir(parents=True, exist_ok=True)
            layouts = [
                (view, label, width)
                for label, width in (("wide", 1024), ("narrow", 420))
                for view in ("downloads", "servers", "discover", "library")
            ]
            self.capture_next(directory, iter(layouts))

        def capture_next(self, directory, layouts):
            next_layout = next(layouts, None)
            if not next_layout:
                self.screenshots_done = True
                return False
            view, label, width = next_layout
            self.window.resize(width, 740)
            self.view.evaluate_javascript(
                f'document.querySelector(\'nav a[href="#{view}"]\').click()',
                -1, None, app.ORIGIN, None, None, None,
            )

            def take_screenshot():
                self.save_layout(directory / f"{view}-{label}.png")
                return self.capture_next(directory, layouts)

            app.GLib.timeout_add(350, take_screenshot)
            return False
        def save_layout(self, path):
            from gi.repository import Gdk
            width, height = self.window.get_size()
            pixbuf = Gdk.pixbuf_get_from_window(self.window.get_window(), 0, 0, width, height)
            pixbuf.savev(str(path), "png", [], [])

    test = SmokeTest()
    app.GLib.timeout_add_seconds(65, lambda: (test.quit(), False)[1])
    test.run([sys.argv[0]])
    workshop.shutdown()
    workshop.server_close()
    if not test.passed:
        log = app.DATA / "desktop.log"
        raise SystemExit(f"Linux dashboard did not load: {test.observed}\n{log.read_text() if log.exists() else ''}")
    if not (app.DATA / "queue-revision.txt").exists():
        raise SystemExit("Closing the Linux desktop did not pause the queue.")
    print("Linux desktop passed render, dialog, concurrent status, and shutdown checks.")

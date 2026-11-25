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
from unittest.mock import Mock, patch


class SlowWorkshop(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(2)
        reply = b'{"data":[],"meta":{"totalMods":0,"totalPages":1}}'
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

    app.DATA.mkdir(exist_ok=True)
    (app.DATA / "batch1-serverconfig.json").write_text(json.dumps({
        "game": {"name": "Test", "scenarioId": "fixture", "mods": [
            {"modId": "ABCDEF0123456789", "name": "Linux fixture", "size": 128}
        ]}
    }), encoding="utf-8")

    class SmokeTest(app.Downloader):
        passed = False
        probe_started = False
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
            elif probe and probe.get("passed") and self.screenshots_done:
                self.passed = True
                self.window.close()
            elif ("Linux fixture" in state.get("queue", "") and not state.get("notice")
                  and not state.get("checking") and not self.probe_started):
                self.probe_started = True
                self.capture_layouts()
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
                      probe.textOnly = ['#act','#queue','#rec','#bs','#srv','#mres'].every(inText);
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
                        probe.passed = response.ok && !probe.actionDone && probe.elapsed < 1000 &&
                                       probe.textOnly && probe.noInlineHandlers && probe.confirmed && probe.speed &&
                                       probe.sharedPoll && probe.unknownSize && probe.liveServerCount;
                        probe.finished = true;
                      }, 150);
                    })()
                """, -1, None, app.ORIGIN, None, None, None)

        def capture_layouts(self):
            folder = os.environ.get("RFMM_SCREENSHOTS")
            if not folder:
                self.screenshots_done = True
                return
            directory = Path(folder)
            directory.mkdir(parents=True, exist_ok=True)
            self.save_layout(directory / "downloads-wide.png")
            self.window.resize(420, 720)
            app.GLib.timeout_add(900, self.save_narrow_layout, directory)

        def save_layout(self, path):
            from gi.repository import Gdk
            width, height = self.window.get_size()
            pixbuf = Gdk.pixbuf_get_from_window(self.window.get_window(), 0, 0, width, height)
            pixbuf.savev(str(path), "png", [], [])

        def save_narrow_layout(self, directory):
            self.save_layout(directory / "downloads-narrow.png")
            self.screenshots_done = True
            return False

    test = SmokeTest()
    app.GLib.timeout_add_seconds(50, lambda: (test.quit(), False)[1])
    test.run([sys.argv[0]])
    workshop.shutdown()
    workshop.server_close()
    if not test.passed:
        log = app.DATA / "desktop.log"
        raise SystemExit(f"Linux dashboard did not load: {test.observed}\n{log.read_text() if log.exists() else ''}")
    if not (app.DATA / "queue-revision.txt").exists():
        raise SystemExit("Closing the Linux desktop did not pause the queue.")
    print("Linux desktop passed render, dialog, concurrent status, and shutdown checks.")

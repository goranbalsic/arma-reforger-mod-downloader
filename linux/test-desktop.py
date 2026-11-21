import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


with tempfile.TemporaryDirectory(prefix="reforger-linux-") as fixture:
    os.environ["RFMM_HOME"] = fixture
    os.environ["RFMM_DATA"] = str(Path(fixture) / "data")
    os.environ.pop("RFMM_GAME_PROFILE", None)
    launcher = Path(__file__).with_name("ReforgerModDownloader")
    loader = importlib.machinery.SourceFileLoader("reforger", str(launcher))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    app = importlib.util.module_from_spec(spec)
    loader.exec_module(app)

    app.ENGINE.parent.mkdir(parents=True)
    app.ENGINE.touch()
    app.DATA.mkdir()
    (app.DATA / "paused.flag").touch()
    (app.DATA / "batch1-serverconfig.json").write_text(json.dumps({
        "game": {"name": "Test", "scenarioId": "fixture", "mods": [
            {"modId": "ABCDEF0123456789", "name": "Linux fixture", "size": 128}
        ]}
    }), encoding="utf-8")

    class SmokeTest(app.Downloader):
        passed = False
        observed = "The WebView has not evaluated a document yet."

        def open_dashboard(self):
            super().open_dashboard()
            app.GLib.timeout_add(500, self.check_queue)

        def check_queue(self):
            self.view.evaluate_javascript(
                "JSON.stringify({uri:location.href, queue:document.getElementById('queue')?.textContent,"
                " notice:document.getElementById('say')?.textContent, title:document.title,"
                " bridge:typeof window.receiveReply, text:document.body?.textContent.slice(0, 100)})",
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
            if "Linux fixture" in state.get("queue", "") and not state.get("notice"):
                self.passed = True
                self.window.close()

    test = SmokeTest()
    app.GLib.timeout_add_seconds(50, lambda: (test.quit(), False)[1])
    test.run([sys.argv[0]])
    if not test.passed:
        log = app.DATA / "desktop.log"
        raise SystemExit(f"Linux dashboard did not load: {test.observed}\n{log.read_text() if log.exists() else ''}")
    if not (app.DATA / "queue-revision.txt").exists():
        raise SystemExit("Closing the Linux desktop did not pause the queue.")
    print("Linux desktop loaded and paused the fixture queue.")

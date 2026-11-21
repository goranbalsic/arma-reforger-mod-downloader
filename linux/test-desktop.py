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

        def open_dashboard(self):
            super().open_dashboard()
            app.GLib.timeout_add(500, self.check_queue)

        def check_queue(self):
            self.view.evaluate_javascript(
                "(document.getElementById('queue')?.textContent.includes('Linux fixture') ?? false)"
                " && !document.getElementById('say')?.textContent",
                -1, None, app.ORIGIN, None, self.check_result, None,
            )
            return not self.passed

        def check_result(self, view, result, _data):
            if view.evaluate_javascript_finish(result).to_boolean():
                self.passed = True
                self.quit()

    test = SmokeTest()
    app.GLib.timeout_add_seconds(20, lambda: (test.quit(), False)[1])
    test.run([sys.argv[0]])
    if not test.passed:
        log = app.DATA / "desktop.log"
        raise SystemExit(log.read_text() if log.exists() else "Linux dashboard did not load.")
    print("Linux desktop window loaded the fixture queue.")

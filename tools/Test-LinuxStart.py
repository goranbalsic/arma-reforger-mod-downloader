"""Exercise Start, Pause, trim, and watchdog restart against the Linux worker."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
from queue import Queue
import signal
import subprocess
import tempfile
from threading import Thread
import time


def wait_for(description, predicate, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(description)


def fixture_engines(binary):
    expected = os.fsencode(binary)
    for cmdline in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            if cmdline.read_bytes().split(b"\0", 1)[0] == expected:
                yield int(cmdline.parent.name)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue


def receive_lines(stream, replies):
    for line in stream:
        if line.startswith("RFMM "):
            replies.put(line[5:])
    replies.put(None)


def request(worker, replies, path, method="GET"):
    worker.stdin.write(json.dumps({"path": path, "method": method}) + "\n")
    worker.stdin.flush()
    message = replies.get(timeout=15)
    assert message is not None, f"Worker exited during {path.split('?')[0]}"
    return json.loads(message)


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def test_preset(lib, root, env):
    game_profile = root / "preset-profile"
    addon = game_profile / "addons" / "Fixture_BBBBBBBBBBBBBBBB"
    addon.mkdir(parents=True)
    (addon / "data.pak").write_bytes(b"x")
    (addon / "meta").write_text('{"meta":{"versions":[{"package":{"files":[{"name":"data.pak","size":1}]}}]}}',
                               encoding="utf-8")
    save_dir = game_profile / "profile" / ".save"
    save_dir.mkdir(parents=True)
    settings = save_dir / "ReforgerGameSettings.conf"
    settings.write_text('GameUserSettings {\n  SCR_WorkshopAddonManagerPresetStorage '
                        'SCR_WorkshopAddonManagerPresetStorage "{6AEA4081FE80EE32}" {\n  }\n}\n',
                        encoding="utf-8")
    server_id = "11111111-1111-1111-1111-111111111111"
    servers = Path(env["RFMM_DATA"]) / "batch1-servers.json"
    servers.write_text(json.dumps({"servers": [{"id": server_id, "name": "Fixture",
                                               "mods": [{"id": "BBBBBBBBBBBBBBBB", "name": "Fixture"}]}]}),
                       encoding="utf-8")
    preset = subprocess.run(["pwsh", "-NoProfile", "-File", str(lib / "make-preset.ps1"), "-ServerId", server_id],
                            env=dict(env, RFMM_GAME_PROFILE=str(game_profile)), capture_output=True,
                            text=True, timeout=12)
    assert preset.returncode == 0, preset.stderr
    assert 'm_sName "Fixture"' in settings.read_text(encoding="utf-8")
    print("PASS Make preset while the dedicated engine runs.")


def test_queue_completion(command, env, root, mod_id, worker_log):
    addon = Path(env["RFMM_GAME_PROFILE"]) / "addons" / f"Fixture_{mod_id}"
    scratch = addon / "temp"
    scratch.mkdir(parents=True)
    (addon / "data.pak").write_bytes(b"x")
    (addon / "meta").write_text(
        '{"meta":{"selectedRev":0,"versions":[{"version":"1.0.0","package":{"files":[{"name":"data.pak","size":1}]}}]}}',
        encoding="utf-8",
    )
    log = root / "serverprofile" / "logs" / "finish" / "console.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    log.write_text(f"{stamp} BACKEND : Addon Download started {mod_id} - Fixture\n", encoding="utf-8")
    replies = Queue()
    reader = subprocess.Popen(command + ["-Desktop", "-ReadOnly", "-NoHelpers"],
                              env=dict(env, RFMM_DESKTOP_SESSION_TOKEN="a" * 32), text=True,
                              encoding="utf-8", stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=worker_log)
    Thread(target=receive_lines, args=(reader.stdout, replies), daemon=True).start()

    def status():
        reply = request(reader, replies, "/status")
        assert reply["status"] == 200, reply["body"]
        return json.loads(reply["body"])

    try:
        def indexed_status():
            snapshot = status()
            return snapshot if not snapshot["inventoryPending"] else None

        before = wait_for("The read-only library scan never finished", indexed_status, timeout=10)
        assert any(row["id"] == mod_id for row in before["queue"]), before
        scratch.rmdir()
        after = status()
        assert not after["queue"] and mod_id in after["installedIds"], after
        completed = json.loads(request(reader, replies, "/completed")["body"])
        assert completed["rev"] == after["recentRev"] and completed["recent"][0]["id"] == mod_id, completed
        print("PASS The first status poll after assembly removes the mod from the queue and updates Completed.")
    finally:
        stop(reader)


def run(lib, root):
    data = root / "data"
    data.mkdir()
    config = data / "batch1-serverconfig.json"
    valid = {"modId": "AAAAAAAAAAAAAAAA", "name": "Pending", "size": 100}
    config.write_text(json.dumps({"game": {
        "name": "Fixture", "scenarioId": "{59AD59368755F41A}Missions/21_GM_Eden.conf",
        "mods": [valid, {"modId": "invalid", "name": "Remove me"}],
    }}), encoding="utf-8")
    source = root / "engine.c"
    source.write_text("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n", encoding="utf-8")
    binary = root / "ArmaReforgerServer"
    subprocess.run(["cc", "-o", binary, source], check=True)
    game_profile = root / "not yet installed"
    env = dict(os.environ, RFMM_HOME=str(root), RFMM_DATA=str(data),
               RFMM_ENGINE_EXE=str(binary), RFMM_GAME_PROFILE=str(game_profile))
    addons = game_profile / "addons"
    command = ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(lib / "download-web.ps1")]
    watchdog = None
    replies = Queue()
    with (root / "worker.log").open("w+") as logs:
        worker = subprocess.Popen(command + ["-Desktop", "-NoHelpers"], env=env, text=True,
                                  encoding="utf-8", stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=logs)
        Thread(target=receive_lines, args=(worker.stdout, replies), daemon=True).start()
        try:
            initial = request(worker, replies, "/status")
            token = json.loads(initial["body"])["tok"]
            saved = json.loads((data / "desktop-token.json").read_text(encoding="utf-8-sig"))
            assert saved["token"] == token
            start = request(worker, replies, f"/start?t={token}", "POST")
            assert start["status"] == 200, start["body"]
            first = wait_for("Start did not launch the fixture ELF engine", lambda: next(fixture_engines(binary), None))
            assert addons.is_dir() and not addons.is_symlink() and not (root / "serverprofile" / "addons").exists()
            arguments = (Path("/proc") / str(first) / "cmdline").read_bytes().split(b"\0")
            assert arguments[arguments.index(b"-addonDownloadDir") + 1] == os.fsencode(game_profile)
            trimmed = json.loads(config.read_text(encoding="utf-8-sig"))
            assert trimmed["game"]["mods"] == [valid], trimmed
            assert trimmed["bindAddress"] == "127.0.0.1"
            assert trimmed["game"]["visible"] is False and trimmed["game"]["maxPlayers"] == 1
            print("PASS Start returned 200, trimmed the queue, and launched the ELF engine.")

            guard = subprocess.run(["pwsh", "-NoProfile", "-File", str(lib / "trim-config.ps1")],
                                   env=env, capture_output=True, text=True, timeout=12)
            assert guard.returncode == 1 and "engine is running" in guard.stdout, guard
            assert json.loads(config.read_text(encoding="utf-8-sig")) == trimmed
            print("PASS trim leaves the active engine and its queue alone.")
            test_preset(lib, root, env)

            pause = request(worker, replies, f"/pause?t={token}", "POST")
            assert pause["status"] == 200 and (data / "paused.flag").exists(), pause["body"]
            wait_for("Pause did not stop the fixture engine", lambda: not list(fixture_engines(binary)))
            print("PASS Pause stopped the engine.")

            resume = request(worker, replies, f"/start?t={token}", "POST")
            assert resume["status"] == 200, resume["body"]
            resumed = wait_for("Resume did not start another engine", lambda: next(fixture_engines(binary), None))
            assert resumed != first
            watchdog = subprocess.Popen(["pwsh", "-NoProfile", "-File", str(lib / "watchdog.ps1")],
                                        env=env, stdout=logs, stderr=logs)
            time.sleep(18)
            assert watchdog.poll() is None and list(fixture_engines(binary)) == [resumed], (
                "Watchdog restarted a newly launched engine that has not written its first log."
            )
            print("PASS Watchdog gives a newly launched engine time to produce its first log.")
            os.kill(resumed, signal.SIGTERM)
            restarted = wait_for("Watchdog did not promptly restart the engine",
                                 lambda: next((pid for pid in fixture_engines(binary) if pid != resumed), None),
                                 timeout=6)
            assert restarted != first
            assert json.loads(config.read_text(encoding="utf-8-sig"))["game"]["mods"] == [valid]
            print("PASS Resume and watchdog restart each launched a new engine.")
            test_queue_completion(command, env, root, valid["modId"], logs)
        except Exception:
            logs.seek(0)
            print(logs.read(), end="")
            raise
        finally:
            stop(watchdog)
            stop(worker)
            for pid in fixture_engines(binary):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lib", type=Path, help="Source directory or the packaged app's lib directory")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rfmm-linux-start-") as fixture:
        run(args.lib.resolve(strict=True), Path(fixture))

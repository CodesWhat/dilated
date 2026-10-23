#!/usr/bin/env python3
"""Exercise the packaged app and CLI using disposable state and bounded commands."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/Dilated.app/Contents/MacOS/DilatedApp"
CLI = APP.with_name("dilated")


def eventually(check, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Condition wasn't reached before the deadline")


def main():
    assert APP.is_file() and CLI.is_file(), "Build the app first"
    with tempfile.TemporaryDirectory(prefix="dilated-smoke-") as temporary:
        state = Path(temporary)
        environment = dict(os.environ, DILATED_STATE_DIR=temporary)
        (state / "settings.json").write_text(json.dumps({"onboardingComplete": True}))
        log = (state / "app.log").open("w")
        running = []
        app = None
        digest = hashlib.sha256(str(state).encode()).hexdigest()[:16]
        socket_directory = Path(f"/tmp/com.codeswhat.dilated-{os.getuid()}-{digest}")

        def command(*args, expected=0):
            result = subprocess.run([str(CLI), *args], env=environment, capture_output=True, text=True, timeout=10)
            assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
            return result

        def status():
            result = subprocess.run([str(CLI), "status", "--json"], env=environment, capture_output=True, text=True, timeout=5)
            return json.loads(result.stdout) if result.returncode == 0 else None

        def start_app():
            process = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log)
            running.append(process)
            eventually(status)
            return process

        def stop_app(process):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        def has_assertion(pid):
            text = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True, timeout=5).stdout
            return any(f"pid {pid}(" in line and "Dilated:" in line for line in text.splitlines())

        try:
            app = start_app()
            first = command("on", "--for", "4s", "--display-awake", "--label", "M1 smoke").stdout.strip()
            assert len(first) == 36
            eventually(lambda: has_assertion(app.pid))
            lease = command("hold", "--ttl", "2s", "--label", "same label").stdout.strip()
            other = command("hold", "--ttl", "2s", "--label", "same label").stdout.strip()
            assert lease != other
            command("hold", "--id", lease, "--ttl", "5s")
            command("release", "--id", other)
            assert {hold["id"] for hold in status()["snapshot"]["holds"]} == {first, lease}
            command("release", "--id", lease)
            eventually(lambda: not status()["snapshot"]["holds"])
            eventually(lambda: not has_assertion(app.pid))
            print("PASS timers, independent leases, renewal/release, expiry and native assertion readback")

            if "--expect-no-helper" in sys.argv:
                helper = subprocess.run(["launchctl", "print", "system/com.codeswhat.dilated.helper"],
                                        capture_output=True, timeout=5)
                assert helper.returncode != 0, "This check requires an uninstalled helper"
                helper_status = json.loads(command("helper", "status", "--json").stdout)
                assert helper_status['helperInstallation'] in ('notRegistered', 'notFound')
                setup = json.loads(command("helper", "setup", "--json", expected=1).stdout)
                assert 'Applications' in setup['message']
                if helper_status['helperInstallation'] == 'notRegistered':
                    removed = json.loads(command("helper", "remove", "--json").stdout)
                    assert removed['ok'] and removed['helperInstallation'] == 'notRegistered'
                else:
                    removed = json.loads(command("helper", "remove", "--json", expected=1).stdout)
                    assert not removed['ok'] and removed['code'] == 'helperFailure'
                print("PASS helper status, install-location validation and conservative removal")
                rejected = command("on", "--for", "30s", "--lid", "--json", expected=1)
                assert json.loads(rejected.stdout)["code"] == "helperFailure"
                assert not status()["snapshot"]["holds"], "Failed closed-lid left an awake hold"
                forbidden_lid = state / "closed-lid-command-must-not-start"
                command("run", "--lid", "--", "/usr/bin/touch", str(forbidden_lid), expected=1)
                assert not forbidden_lid.exists()
                assert not status()["snapshot"]["holds"]
                print("PASS unavailable helper rejects closed-lid without leaving holds or starting work")

            command("run", "--", "/bin/sh", "-c", "exit 7", expected=7)
            runner = subprocess.Popen([str(CLI), "run", "--label", "bounded runner", "--", sys.executable,
                                       "-c", "import time; time.sleep(4); print('command completed')"],
                                      env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            running.append(runner)
            eventually(lambda: any(hold["source"] == "runner" for hold in status()["snapshot"]["holds"]))
            command("off")
            assert runner.poll() is None, "Stop terminated the wrapped command"
            eventually(lambda: not has_assertion(runner.pid), seconds=3)
            result = command("on", "--for", "10s", "--json", expected=4)
            assert json.loads(result.stdout)["code"] == "automationPaused"
            stdout, stderr = runner.communicate(timeout=8)
            assert runner.returncode == 0 and "command completed" in stdout, (stdout, stderr)
            assert not status()["snapshot"]["holds"]
            print("PASS run exit status, Stop releases awake claims without killing work, paused starts rejected")

            app.kill()
            app.wait(timeout=5)
            app = start_app()
            assert status()["snapshot"]["automationPaused"]
            command("hold", "--ttl", "5s", expected=4)
            print("PASS Stop pause survives process death and relaunch")

            stop_app(app)
            (state / "holds.json").write_text(json.dumps({"automationPaused": False, "holds": []}))
            app = start_app()
            timer = command("on", "--for", "30s").stdout.strip()
            command("on", "--label", "indefinite")
            deadline = next(hold["expiry"] for hold in status()["snapshot"]["holds"] if hold["id"] == timer)
            app.kill()
            app.wait(timeout=5)
            app = start_app()
            restored = status()["snapshot"]["holds"]
            assert len(restored) == 1 and restored[0]["id"] == timer and restored[0]["expiry"] == deadline
            print("PASS crash restores unexpired timer with original deadline and drops indefinite hold")

            stop_app(app)
            standalone = subprocess.Popen([str(CLI), "run", "--", sys.executable, "-c", "import time; time.sleep(2); raise SystemExit(9)"],
                                          env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            running.append(standalone)
            eventually(lambda: has_assertion(standalone.pid), seconds=2)
            standalone.communicate(timeout=6)
            assert standalone.returncode == 9
            print("PASS standalone run assertion and child exit status without app")

            (state / "holds.json").write_text(json.dumps({"automationPaused": True, "holds": []}))
            forbidden = state / "should-not-exist"
            command("run", "--", "/usr/bin/touch", str(forbidden), expected=1)
            assert not forbidden.exists()
            print("PASS standalone run respects persisted automation pause")
        finally:
            for process in reversed(running):
                stop_app(process)
            log.close()
            if socket_directory.exists():
                (socket_directory / "control.sock").unlink(missing_ok=True)
                socket_directory.rmdir()
            assert all(process.poll() is not None for process in running), "A QA process survived cleanup"


if __name__ == "__main__":
    main()

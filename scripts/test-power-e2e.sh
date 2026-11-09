#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
cd "$repo_root"
build_flags=()
if [[ -n "${KITH_BUILD_SYSTEM:-}" ]]; then
    build_flags+=(--build-system "$KITH_BUILD_SYSTEM")
fi
swift build "${build_flags[@]}"
binary_dir="$(swift build "${build_flags[@]}" --show-bin-path)"
python3 - "$repo_root" "$binary_dir" <<'PY'
import datetime
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

repo = pathlib.Path(sys.argv[1])
binaries = pathlib.Path(sys.argv[2])
home = pathlib.Path(tempfile.mkdtemp(prefix="kith-e2e-", dir="/tmp"))
app = home / "Kith E2E.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Resources/Kith-Info.plist").read_bytes())
info.update(CFBundleExecutable="KithApp", CFBundleIdentifier="app.trykith.kith.e2e",
            CFBundleName="Kith E2E", CFBundleDisplayName="Kith E2E", LSMinimumSystemVersion="14.0")
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
for name in ("KithApp", "kith", "kith-event"):
    shutil.copy2(binaries / name, contents / "MacOS" / name)
for name in ("Kith.icns", "KithMenuBarTemplate.png"):
    shutil.copy2(repo / "Resources" / name, contents / "Resources" / name)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
environment = dict(os.environ, KITH_HOME=str(home), KITH_E2E="1")
preferences = dict(maximumSeconds=14400, batteryWarning=20, batteryFloor=10,
    keepDisplayAwake=True, saveEnergy=False, lowPowerFloor=40, lowPowerWithLidClosed=False,
    muteWithLidClosed=False, networkAlerts=True, browserDiagnostics=False)
(home / "power-preferences.json").write_text(json.dumps(preferences))
fixture = dict(revision=0, status="ready", batteryPercent=80, batteryUnreadable=False,
               onAC=True, heat=0, lidClosed=False, networkAvailable=True, armFinishAction=False)
app_process = None
log_path = repo / ".build/power-e2e-app.log"
app_log = log_path.open("w")
checks = []
passed_all = False

def change(**values):
    fixture.update(values)
    fixture["revision"] += 1
    temporary = home / "fixture.tmp"
    temporary.write_text(json.dumps(fixture))
    temporary.replace(home / "fixture.json")

def launch():
    global app_process
    app_process = subprocess.Popen([str(contents / "MacOS/KithApp")], env=environment,
                                  stdout=app_log, stderr=app_log)

def stop():
    if app_process and app_process.poll() is None:
        app_process.terminate()
        app_process.wait(timeout=10)
    if app_process:
        subprocess.run(["defaults", "delete", f"app.trykith.kith.e2e.{app_process.pid}"], capture_output=True)

def command(*arguments, ok=True):
    result = subprocess.run([str(contents / "MacOS/kith"), "power", *arguments, "--json"],
                            env=environment, capture_output=True, text=True, timeout=15)
    if not result.stdout:
        raise AssertionError(f"CLI returned no JSON: {result.stderr}")
    reply = json.loads(result.stdout)
    assert reply["ok"] is ok, reply
    assert (result.returncode == 0) is ok, reply
    return reply.get("status", reply)

def wait_for(predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if app_process.poll() is not None:
            raise AssertionError("App exited: " + log_path.read_text()[-3000:])
        state = command("status")
        if predicate(state):
            return state
        time.sleep(0.1)
    raise AssertionError(f"State did not converge: {state}")

def passed(name):
    checks.append(name)
    print("PASS " + name, flush=True)

def date(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))

try:
    change()
    launch()
    state = wait_for(lambda state: not state["idleHoldActive"])
    passed("idle app starts without a wake hold")

    state = command("start", "--for", "2m")
    assert state["manual"] and state["idleHoldActive"] and state["displayHoldActive"], state
    original = date(state["deadline"])
    state = command("extend", "--for", "1m")
    assert (date(state["deadline"]) - original).total_seconds() == 60, state
    command("start", "--for", "25h", ok=False)
    command("start", "--for", "-1s", ok=False)
    passed("manual start, display wake, extension and invalid duration acknowledgments")

    duplicate = subprocess.Popen([str(contents / "MacOS/KithApp")], env=environment,
                                 stdout=app_log, stderr=app_log)
    try:
        time.sleep(1)
        change(status="needsInput")
        state = command("status")
        time.sleep(2)
        stored = json.loads((home / "power.json").read_text())
        stored_deadline = stored["period"]["deadline"] + 978307200
        assert abs(stored_deadline - date(state["deadline"]).timestamp()) < 1, stored
    finally:
        duplicate.terminate()
        duplicate.wait(timeout=10)
        subprocess.run(["defaults", "delete", f"app.trykith.kith.e2e.{duplicate.pid}"], capture_output=True)
    passed("a second app instance cannot replace the current wake period")

    state = command("end")
    assert not state["idleHoldActive"] and not state["displayHoldActive"] and state["stopped"] == "user", state
    command("resume")
    change(status="needsInput")
    state = wait_for(lambda state: state["idleHoldActive"])
    deadline = state["deadline"]
    change(status="running")
    state = command("status")
    assert state["deadline"] == deadline, state
    passed("waiting and working agents share a bounded wake period")

    change(armFinishAction=True)
    wait_for(lambda state: state["finishActionArmed"])
    state = command("start", "--for", "2m")
    assert not state["finishActionArmed"], state
    change(armFinishAction=False)
    passed("manual start cancels an armed finish action")

    command("start", "--for", "2s")
    state = wait_for(lambda state: state.get("stopped") == "deadline")
    assert not state["idleHoldActive"] and not state["displayHoldActive"], state
    stop()
    launch()
    state = wait_for(lambda state: state.get("stopped") == "deadline")
    assert not state["idleHoldActive"], state
    passed("deadline releases all holds and remains stopped after process restart")

    state = command("resume")
    deadline = state["deadline"]
    stop()
    launch()
    state = wait_for(lambda state: state["idleHoldActive"])
    assert state["deadline"] == deadline, state
    passed("restart preserves an unexpired deadline")

    change(onAC=False, batteryPercent=9)
    state = wait_for(lambda state: state.get("stopped") == "battery")
    assert not state["idleHoldActive"] and not state["displayHoldActive"], state
    change(onAC=True, batteryPercent=80)
    state = command("status")
    assert state.get("stopped") == "battery", state
    command("resume")
    passed("low battery releases holds and AC recovery requires explicit resume")

    change(heat=3)
    wait_for(lambda state: state.get("stopped") == "heat")
    command("resume", ok=False)
    change(heat=0)
    wait_for(lambda state: state["conditions"]["heat"] == 0)
    command("resume")
    passed("critical heat stops protection and blocks unsafe resume")

    change(onAC=False, batteryUnreadable=True)
    wait_for(lambda state: state["conditions"]["onAC"] is False)
    change(batteryUnreadable=True)
    wait_for(lambda state: state.get("stopped") == "batteryUnreadable")
    change(onAC=True, batteryUnreadable=False)
    wait_for(lambda state: state["conditions"]["onAC"] is True)
    command("resume")
    passed("consecutive unreadable battery observations stop protection")

    change(networkAvailable=False)
    wait_for(lambda state: state["networkWarning"])
    change(networkAvailable=True)
    wait_for(lambda state: not state["networkWarning"])
    passed("network loss is debounced and recovery clears its warning")

    assert (home / "power.json").stat().st_mode & 0o777 == 0o600
    assert (home / "power-control").stat().st_mode & 0o777 == 0o700
    command("end")
    passed("private state permissions and final cleanup")
    (repo / ".build/power-e2e-results.json").write_text(json.dumps(dict(
        checks=checks, app="debug bundle", effects="simulated OS power effects", passed=True), indent=2))
    print(f"{len(checks)} end-to-end scenarios passed", flush=True)
    passed_all = True
finally:
    if passed_all and os.environ.get("KITH_E2E_KEEP_APP") == "1":
        (repo / ".build/power-e2e-sandbox.json").write_text(json.dumps(dict(home=str(home), app=str(app), pid=app_process.pid)))
        print("E2E sandbox retained for UI verification: " + str(app), flush=True)
    else:
        stop()
        shutil.rmtree(home, ignore_errors=True)
    app_log.close()
PY

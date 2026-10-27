#!/usr/bin/env python3
"""A dose schedule whose pulse is not shorter than its interval must not stop
the bioreactor's motor writes (anolishq/anolis-projects#103).

Runs the bioreactor-v1 automation config and behavior tree on a local
anolis-runtime, against anolis-provider-bread in mock mode, then:

1. puts dose 1 mid-pulse with the impeller running;
2. gives the disabled dose 2 an invalid schedule, and expects the impeller
   still to turn off and on: a disabled channel cannot fail the tree;
3. sets dose1_interval_s below dose1_pulse_s, and expects dcmt1 motor 1
   (dose 1) to be commanded to 0;
4. turns the impeller off, and expects dcmt0 motor 2 to be commanded to 0,
   so the other writes still run;
5. with dose 1 still invalid, starts dose 2 and expects dcmt1 motor 2 to run.

What a motor was commanded is read back from the mock DCMT, whose GET_STATE
follows its SETs in the release of anolis-provider-bread that carries
anolishq/anolis-provider-bread#204.
Needs an anolis-runtime built with automation, and PyYAML.

Usage:
  check_invalid_dose_schedule.py --runtime PATH --bread PATH [--port N] [--tree PATH]

Exit status: 0 if every check passes, 1 if one fails, 2 on a setup error.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import yaml

PROJECT = pathlib.Path(__file__).resolve().parent.parent
AUTOMATION_CONFIG = PROJECT / "config" / "anolis-runtime.bioreactor.automation.yaml"
BREAD_CONFIG = PROJECT / "config" / "provider-bread.bioreactor.yaml"
TREE = PROJECT / "behaviors" / "bioreactor_stir_dual_dosing.xml"


def write_configs(workdir: pathlib.Path, bread: str, port: int, tree: pathlib.Path) -> pathlib.Path:
    bread_doc = yaml.safe_load(BREAD_CONFIG.read_text(encoding="utf-8"))
    bread_doc["hardware"]["bus_path"] = "mock://bioreactor-dose-check"
    bread_doc["hardware"].pop("max_bus_hz", None)
    for device in bread_doc["devices"]:
        device.pop("command_watchdog_ms", None)
    bread_path = workdir / "provider-bread.yaml"
    bread_path.write_text(yaml.safe_dump(bread_doc, sort_keys=False), encoding="utf-8")

    doc = yaml.safe_load(AUTOMATION_CONFIG.read_text(encoding="utf-8"))
    doc["runtime"]["data_dir"] = str(workdir / "data")
    doc["http"]["port"] = port
    doc["providers"] = [
        {
            "id": "bread0",
            "command": bread,
            "args": ["--config", str(bread_path)],
            "timeout_ms": 5000,
            "hello_timeout_ms": 2000,
            "ready_timeout_ms": 10000,
        }
    ]
    doc["telemetry"] = {"enabled": False}
    doc.pop("health", None)
    doc["automation"]["behavior_tree"] = str(tree.resolve())
    runtime_path = workdir / "runtime.yaml"
    runtime_path.write_text(yaml.safe_dump(doc, sort_keys=False), encoding="utf-8")
    return runtime_path


class Api:
    def __init__(self, port: int) -> None:
        self.base = f"http://127.0.0.1:{port}"

    def get(self, path: str) -> dict:
        with urllib.request.urlopen(self.base + path, timeout=5) as resp:
            return json.loads(resp.read())

    def post(self, path: str, body: dict) -> dict:
        req = urllib.request.Request(
            self.base + path,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())

    def set_param(self, name: str, value: object) -> None:
        self.post("/v0/parameters", {"name": name, "value": value})

    def motor(self, device: str, signal: str) -> int | None:
        state = self.get(f"/v0/state/bread0/{device}")
        for value in state.get("values", []):
            if value.get("signal_id") == signal:
                return int(value["value"]["int64"])
        return None


def eventually(what: str, check, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last is True:
                print(f"PASS {what}")
                return True
        except (urllib.error.URLError, OSError, KeyError, ValueError) as error:
            last = error
        time.sleep(0.5)
    print(f"FAIL {what} (last: {last})")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", required=True, help="anolis-runtime binary, built with automation")
    parser.add_argument("--bread", required=True, help="anolis-provider-bread binary")
    parser.add_argument("--port", type=int, default=18491)
    parser.add_argument("--tree", type=pathlib.Path, default=TREE, help="behavior tree to run (default: this project's)")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="bioreactor-dose-check-") as tmp:
        workdir = pathlib.Path(tmp)
        config = write_configs(workdir, args.bread, args.port, args.tree)
        log = (workdir / "runtime.log").open("w")
        proc = subprocess.Popen([args.runtime, "--config", str(config)], stdout=log, stderr=subprocess.STDOUT)
        api = Api(args.port)
        try:
            if not eventually("the runtime answers", lambda: api.get("/v0/runtime/status")["status"]["code"] == "OK", 30):
                return 2
            for name, value in [
                ("impeller_enable", True),
                ("impeller_pwm", 100),
                ("dose1_enable", True),
                ("dose1_startup_delay_s", 0),
                ("dose1_interval_s", 120),
                ("dose1_pulse_s", 60),
                ("command_keepalive_s", 2),
            ]:
                api.set_param(name, value)
            api.post("/v0/mode", {"mode": "MANUAL"})
            api.post("/v0/mode", {"mode": "AUTO"})

            ok = eventually("dose 1 is mid-pulse (dcmt1 motor 1 at 240)", lambda: api.motor("dcmt1", "motor1_value") == 240, 15)
            ok &= eventually("the impeller runs (dcmt0 motor 2 at 100)", lambda: api.motor("dcmt0", "motor2_value") == 100, 15)
            if not ok:
                return 2

            # A disabled channel's schedule inputs cannot fail the tree.
            api.set_param("dose2_interval_s", 2)  # below dose2_pulse_s = 5, on a disabled channel
            api.set_param("impeller_enable", False)
            ok = eventually(
                "with a disabled dose 2 scheduled invalidly, the impeller can be turned off (dcmt0 motor 2 at 0)",
                lambda: api.motor("dcmt0", "motor2_value") == 0,
                10,
            )
            api.set_param("dose2_interval_s", 900)
            api.set_param("impeller_enable", True)
            ok &= eventually("the impeller runs again (dcmt0 motor 2 at 100)", lambda: api.motor("dcmt0", "motor2_value") == 100, 10)

            # An invalid schedule on an enabled channel turns that channel off.
            api.set_param("dose1_interval_s", 3)  # below dose1_pulse_s = 60
            ok &= eventually(
                "with dose1_pulse_s > dose1_interval_s, dose 1 is commanded off (dcmt1 motor 1 at 0)",
                lambda: api.motor("dcmt1", "motor1_value") == 0,
                10,
            )
            api.set_param("impeller_enable", False)
            ok &= eventually(
                "the impeller can still be turned off (dcmt0 motor 2 at 0)",
                lambda: api.motor("dcmt0", "motor2_value") == 0,
                10,
            )
            for name, value in [
                ("dose2_enable", True),
                ("dose2_startup_delay_s", 0),
                ("dose2_interval_s", 120),
                ("dose2_pulse_s", 60),
            ]:
                api.set_param(name, value)
            ok &= eventually(
                "with dose 1 still invalid, dose 2 runs (dcmt1 motor 2 at 240)",
                lambda: api.motor("dcmt1", "motor2_value") == 240,
                10,
            )
            mode = api.get("/v0/mode").get("mode")
            print(f"INFO mode at the end: {mode}")
            return 0 if ok else 1
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            log.close()


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The behavior tree holds the heater and sets the probes' compensation.

Runs the bioreactor-v1 automation config and behavior tree on a local
anolis-runtime, against anolis-provider-bread and anolis-provider-ezo in mock
mode, then:

1. enters AUTO with the defaults, and expects the heater off (open loop,
   setpoint 0, relay off) and both probes set to compensate for 25 C. The
   runtime's startup safe state has already turned the heater off, so step 5
   is the one that shows the tree turning it off;
2. turns the heater on at a 58 C pad setpoint, and expects period 10000 ms,
   thermocouple select 2 / 1 and gains 255 / 10 / 0 sent before the loop is
   closed at 58 C, and rlht0 to read back channel 1 on thermocouple 2;
3. moves the pad setpoint and the compensation temperature, and expects
   both followed;
4. leaves AUTO for MANUAL, and expects the heater left as it was;
5. turns the heater off in AUTO, and expects it off;
6. turns it back on and enters FAULT, and expects the heater off.

The mock RLHT reads back mode, setpoints, relay state and thermocouple
select (anolis-provider-bread with #224), but not period or gains, so those
and the compensation calls are read from the runtime's call log. The log skips a tree call
identical to the last, so the keepalive is not checked here.
Needs an anolis-runtime built with automation, and PyYAML.

Usage:
  check_heater.py --runtime PATH --bread PATH --ezo PATH [--port N]

Exit status: 0 if every check passes, 1 if one fails, 2 on a setup error.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
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
EZO_CONFIG = PROJECT / "config" / "provider-ezo.bioreactor.yaml"
TREE = PROJECT / "behaviors" / "bioreactor_stir_dual_dosing.xml"


def write_configs(workdir: pathlib.Path, bread: str, ezo: str, port: int) -> pathlib.Path:
    bread_doc = yaml.safe_load(BREAD_CONFIG.read_text(encoding="utf-8"))
    bread_doc["hardware"]["bus_path"] = "mock://bioreactor-heater-check"
    bread_doc["hardware"].pop("max_bus_hz", None)
    for device in bread_doc["devices"]:
        device.pop("command_watchdog_ms", None)
    bread_path = workdir / "provider-bread.yaml"
    bread_path.write_text(yaml.safe_dump(bread_doc, sort_keys=False), encoding="utf-8")

    ezo_doc = yaml.safe_load(EZO_CONFIG.read_text(encoding="utf-8"))
    ezo_doc["hardware"]["bus_path"] = "mock://bioreactor-heater-check-ezo"
    ezo_path = workdir / "provider-ezo.yaml"
    ezo_path.write_text(yaml.safe_dump(ezo_doc, sort_keys=False), encoding="utf-8")

    doc = yaml.safe_load(AUTOMATION_CONFIG.read_text(encoding="utf-8"))
    doc["runtime"]["data_dir"] = str(workdir / "data")
    doc["http"]["port"] = port
    provider = {"timeout_ms": 5000, "hello_timeout_ms": 5000, "ready_timeout_ms": 10000}
    doc["providers"] = [
        {"id": "bread0", "command": bread, "args": ["--config", str(bread_path)], **provider},
        {"id": "ezo0", "command": ezo, "args": ["--config", str(ezo_path)], **provider},
    ]
    doc["telemetry"] = {"enabled": False}
    doc.pop("health", None)
    doc["automation"]["behavior_tree"] = str(TREE)
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
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())

    def set_param(self, name: str, value: object) -> None:
        self.post("/v0/parameters", {"name": name, "value": value})

    def mode(self, mode: str) -> None:
        self.post("/v0/mode", {"mode": mode})

    def rlht(self) -> dict:
        out = {}
        for value in self.get("/v0/state/bread0/rlht0").get("values", []):
            v = value.get("value") or {}
            raw = v.get(v.get("type", ""))
            # int64 and uint64 arrive as JSON strings.
            out[value["signal_id"]] = int(raw) if v.get("type") in ("int64", "uint64") and raw is not None else raw
        return out


def eventually(what: str, check, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last is True:
                print(f"PASS {what}")
                return True
        except (urllib.error.URLError, OSError, KeyError, ValueError, TypeError) as error:
            last = error
        time.sleep(0.5)
    print(f"FAIL {what} (last: {last})")
    return False


def heater(api: Api, mode: str, setpoint: float, relay: bool | None = None):
    def check():
        s = api.rlht()
        ok = s.get("mode") == mode and abs(float(s.get("setpoint1_c")) - setpoint) < 0.05
        if relay is not None:
            ok = ok and bool(s.get("relay1_on")) == relay
        return True if ok else {k: s.get(k) for k in ("mode", "setpoint1_c", "relay1_on")}

    return check


class Log:
    """The runtime's call records, read from where the last read ended."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.offset = 0

    def calls(self) -> list[str]:
        with self.path.open() as fh:
            fh.seek(self.offset)
            text = fh.read()
            self.offset = fh.tell()
        return re.findall(r"\[CallRouter\] (call .*)", text)


def logged(log: Log, seen: list[str], wanted: list[str]):
    """True once every wanted pattern has matched a record, in order."""

    def check():
        seen.extend(log.calls())
        i = 0
        for record in seen:
            if i < len(wanted) and re.search(wanted[i], record):
                i += 1
        if i == len(wanted):
            return True
        function = re.match(r"[\w/]+ (\w+)", wanted[i]).group(1)
        return f"matched {i} of {len(wanted)}; next {wanted[i]!r}; {function} records: {[r for r in seen if function in r][-3:]}"

    return check


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", required=True, help="anolis-runtime binary, built with automation")
    parser.add_argument("--bread", required=True, help="anolis-provider-bread binary")
    parser.add_argument("--ezo", required=True, help="anolis-provider-ezo binary")
    parser.add_argument("--port", type=int, default=18492)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="bioreactor-heater-check-") as tmp:
        workdir = pathlib.Path(tmp)
        config = write_configs(workdir, args.bread, args.ezo, args.port)
        log_path = workdir / "runtime.log"
        log_fh = log_path.open("w")
        proc = subprocess.Popen([args.runtime, "--config", str(config)], stdout=log_fh, stderr=subprocess.STDOUT)
        api = Api(args.port)
        log = Log(log_path)
        try:
            if not eventually("the runtime answers", lambda: api.get("/v0/runtime/status")["status"]["code"] == "OK", 30):
                return 2
            if not eventually("rlht0 reads", lambda: "mode" in api.rlht(), 15):
                return 2
            api.set_param("command_keepalive_s", 2)
            api.mode("MANUAL")
            api.mode("AUTO")

            seen: list[str] = []
            ok = eventually("defaults: the heater is off (open loop, setpoint 0, relay off)", heater(api, "open_loop", 0.0, relay=False), 15)
            ok &= eventually(
                "defaults: both probes compensate for 25 C",
                logged(log, seen, [
                    r"ezo0/ph0 set_compensation\(temperature_c=25(\.0+)?\) .*: OK",
                    r"ezo0/do0 set_compensation\(temperature_c=25(\.0+)?\) .*: OK",
                ]),
                15,
            )

            seen = []
            api.set_param("heater_pad_setpoint_c", 58.0)
            api.set_param("heater_enable", True)
            ok &= eventually("on: the loop closes at a 58 C pad setpoint", heater(api, "closed_loop", 58.0), 15)
            ok &= eventually(
                "on: period, thermocouple 2 / 1 and gains are sent before the loop closes",
                logged(log, seen, [
                    r"bread0/rlht0 set_periods_ms\(period1_ms=10000, period2_ms=10000\) .*: OK",
                    r"bread0/rlht0 set_tc_select\(channel1_thermocouple=2, channel2_thermocouple=1\) .*: OK",
                    r"bread0/rlht0 set_pid_x10\(kd1_x10=0, kd2_x10=0, ki1_x10=10, ki2_x10=0, kp1_x10=255, kp2_x10=0\) .*: OK",
                    r'bread0/rlht0 set_mode\(mode="closed_loop"\) .*: OK',
                    r"bread0/rlht0 set_setpoints\(setpoint1_c=58(\.0+)?, setpoint2_c=0(\.0+)?\) .*: OK",
                ]),
                15,
            )

            ok &= eventually(
                "on: rlht0 reads back channel 1 on thermocouple 2 and channel 2 on 1",
                lambda: (lambda s: True if (s.get("channel1_thermocouple"), s.get("channel2_thermocouple")) == (2, 1)
                         else {k: s.get(k) for k in ("channel1_thermocouple", "channel2_thermocouple")})(api.rlht()),
                15,
            )

            seen = []
            api.set_param("heater_pad_setpoint_c", 50.0)
            api.set_param("compensation_temp_c", 30.0)
            ok &= eventually("a new pad setpoint is followed (50 C)", heater(api, "closed_loop", 50.0), 15)
            ok &= eventually(
                "a new compensation temperature is sent to both probes (30 C)",
                logged(log, seen, [
                    r"ezo0/ph0 set_compensation\(temperature_c=30(\.0+)?\) .*: OK",
                    r"ezo0/do0 set_compensation\(temperature_c=30(\.0+)?\) .*: OK",
                ]),
                15,
            )

            api.mode("MANUAL")
            time.sleep(3)
            ok &= eventually("AUTO -> MANUAL leaves the heater on (closed loop, 50 C)", heater(api, "closed_loop", 50.0), 5)

            api.mode("AUTO")
            api.set_param("heater_enable", False)
            ok &= eventually("heater_enable off in AUTO turns it off", heater(api, "open_loop", 0.0, relay=False), 15)

            api.set_param("heater_enable", True)
            ok &= eventually("back on in AUTO", heater(api, "closed_loop", 50.0), 15)
            api.mode("FAULT")
            ok &= eventually("FAULT turns the heater off", heater(api, "open_loop", 0.0, relay=False), 15)

            failures = [r for r in seen + log.calls() if not r.endswith(": OK")]
            for record in failures:
                print(f"INFO not OK: {record}")
            print(f"INFO mode at the end: {api.get('/v0/mode').get('mode')}")
            return 0 if ok else 1
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            log_fh.close()


if __name__ == "__main__":
    sys.exit(main())

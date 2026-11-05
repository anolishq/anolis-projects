#!/usr/bin/env python3
"""Supervise an unattended heater run on rlht0, outside anolis's own logic.

The gen1 RLHT firmware has no over-temperature or no-rise check, and the
runtime has no signal thresholds, so nothing else stops a heater whose loop
or thermocouple has gone wrong. This script polls the runtime every
--period seconds, appends a CSV row, and sends the software e-stop
(POST /v0/estop, whose safe-state hooks turn the heater off) when:

- the pad (t2_c) is above --pad-max;
- the liquid (t1_c) is above --liquid-max;
- either thermocouple is not OK, or the read fails, for --stale seconds;
- the pad reads more than --detach-delta below the liquid for
  --detach-seconds after the relay has been on. A pad thermocouple that has
  come off the pad reads ambient, so the loop runs at full power blind.

After sending the e-stop it reads the latch back from /v0/runtime/status
and retries until the latch is confirmed. The request can time out while
the safe-state hooks wait on an unreachable device. It sends nothing else.
If the runtime itself is down, the slice's command watchdog turns the heater
off.

Run it on the runtime host, under the runtime's environment
(ANOLIS_API_TOKEN), so that it outlives the shell, for example:

  sudo systemd-run --unit=heater-guard \\
    --property=EnvironmentFile=/etc/anolis/runtime.env \\
    /usr/bin/python3 -u heater_guard.py ~/heater-run.csv --pad-max 70

Exit status: 2 after a confirmed stop; the script does not exit otherwise.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request

FIELDS = ["time", "runtime_mode", "t1_c", "t2_c", "setpoint1_c", "relay1_on", "mode", "period1_ms", "estop", "event"]


class Api:
    def __init__(self, base: str, token: str) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{self.base}{path}",
            data=data,
            method=method,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}

    def rlht(self, handle: str) -> dict:
        values = {v["signal_id"]: v for v in self.call("GET", f"/v0/state/{handle}").get("values", [])}

        def ok(sig: str):
            v = values.get(sig)
            if v is None or v.get("quality") != "OK":
                return None
            val = v.get("value") or {}
            for key in ("double", "int64", "uint64", "bool", "string"):
                if key in val:
                    return val[key]
            return None

        return {sig: ok(sig) for sig in ("t1_c", "t2_c", "setpoint1_c", "relay1_on", "mode", "period1_ms", "estop")}

    def latched(self) -> bool:
        try:
            return bool((self.call("GET", "/v0/runtime/status").get("estop") or {}).get("latched"))
        except (urllib.error.URLError, OSError, ValueError):
            return False


class Guard:
    """The stop decisions, separate from the polling loop so they can be checked."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.last_good = time.monotonic()
        self.detach_since: float | None = None
        self.relay_seen = False

    def reason(self, row: dict, read_ok: bool, now: float) -> str | None:
        a = self.args
        t1, t2 = row.get("t1_c"), row.get("t2_c")
        if read_ok and t1 is not None and t2 is not None:
            self.last_good = now
        elif now - self.last_good > a.stale:
            return f"no good t1/t2 reading for {a.stale:.0f} s"
        if t2 is not None and t2 > a.pad_max:
            return f"pad t2_c {t2} C above {a.pad_max} C"
        if t1 is not None and t1 > a.liquid_max:
            return f"liquid t1_c {t1} C above {a.liquid_max} C"
        self.relay_seen = self.relay_seen or bool(row.get("relay1_on"))
        if self.relay_seen and t1 is not None and t2 is not None and t2 < t1 - a.detach_delta:
            self.detach_since = self.detach_since if self.detach_since is not None else now
            if now - self.detach_since > a.detach_seconds:
                return f"pad t2_c {t2} below liquid t1_c {t1} for {a.detach_seconds:.0f} s: pad thermocouple off the pad?"
        else:
            self.detach_since = None
        return None


def stop(api: Api, writer: csv.DictWriter, fh, reason: str, retry_s: float = 30.0) -> None:
    attempt = 0
    while True:
        attempt += 1
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        try:
            api.call("POST", "/v0/estop", {"reason": f"heater_guard: {reason}"})
            sent = "estop sent"
        except (urllib.error.URLError, OSError, ValueError) as exc:
            sent = f"estop request error: {exc}"
        for _ in range(12):
            if api.latched():
                break
            time.sleep(5)
        ok = api.latched()
        event = f"STOP {reason}; {sent}; latched={ok}; attempt {attempt}"
        writer.writerow({"time": stamp, "event": event})
        fh.flush()
        print(stamp, event, flush=True)
        if ok:
            sys.exit(2)
        time.sleep(retry_s)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("csv", help="CSV file to append to")
    p.add_argument("--device", default="bread0/rlht0", help="RLHT device handle (default: bread0/rlht0)")
    p.add_argument("--base", default="http://127.0.0.1:8080", help="runtime base URL")
    p.add_argument("--pad-max", type=float, default=70.0, help="pad (t2_c) limit, C (default 70)")
    p.add_argument("--liquid-max", type=float, default=45.0, help="liquid (t1_c) limit, C (default 45)")
    p.add_argument("--stale", type=float, default=120.0, help="seconds without a good reading (default 120)")
    p.add_argument("--detach-delta", type=float, default=3.0, help="pad below liquid by this much, C (default 3)")
    p.add_argument("--detach-seconds", type=float, default=1800.0, help="for this long (default 1800)")
    p.add_argument("--period", type=float, default=30.0, help="poll period, s (default 30)")
    return p.parse_args(argv)


def main() -> None:
    args = parse_args()
    token = os.environ.get("ANOLIS_API_TOKEN")
    if not token:
        sys.exit("ANOLIS_API_TOKEN is not set; run under the runtime's environment")
    api = Api(args.base, token)
    guard = Guard(args)
    new = not os.path.exists(args.csv)
    with open(args.csv, "a", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDS)
        if new:
            writer.writeheader()
        while True:
            row: dict = {"time": time.strftime("%Y-%m-%dT%H:%M:%S")}
            read_ok = True
            try:
                row["runtime_mode"] = api.call("GET", "/v0/mode").get("mode")
                row.update(api.rlht(args.device))
                row["event"] = ""
            except (urllib.error.URLError, OSError, ValueError) as exc:
                read_ok = False
                row["event"] = f"read failed: {exc}"
            writer.writerow(row)
            fh.flush()
            reason = guard.reason(row, read_ok, time.monotonic())
            if reason:
                stop(api, writer, fh, reason)
            time.sleep(args.period)


if __name__ == "__main__":
    main()

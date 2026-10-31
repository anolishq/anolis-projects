#!/usr/bin/env python3
"""The periodic sampler drives dcmt0 motor 1 beside the impeller on motor 2
(anolishq/anolis-projects#127).

Runs the bioreactor-v1 automation config and behavior tree on a local
anolis-runtime, against anolis-provider-bread in mock mode, as
check_invalid_dose_schedule.py does, then:

1. with the impeller running, enables the sampler on a short schedule and
   expects dcmt0 motor 1 at sample_pwm while motor 2 stays at impeller_pwm;
2. expects motor 1 back at 0 between pulses, the impeller still running;
3. disables the sampler and expects motor 1 to stay at 0;
4. gives the enabled sampler an invalid schedule (pulse longer than the
   interval), expects motor 1 at 0, and the impeller still to turn off.

Needs an anolis-runtime built with automation, and PyYAML.

Usage:
  check_sampler.py --runtime PATH --bread PATH [--port N] [--tree PATH]

Exit status: 0 if every check passes, 1 if one fails, 2 on a setup error.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error

from check_invalid_dose_schedule import TREE, Api, eventually, write_configs


def stays(what: str, check, seconds: float) -> bool:
    """`check` holds on every read for `seconds`."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check() is not True:
            print(f"FAIL {what}")
            return False
        time.sleep(0.5)
    print(f"PASS {what}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", required=True, help="anolis-runtime binary, built with automation")
    parser.add_argument("--bread", required=True, help="anolis-provider-bread binary")
    parser.add_argument("--port", type=int, default=18492)
    parser.add_argument("--tree", type=pathlib.Path, default=TREE, help="behavior tree to run (default: this project's)")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="bioreactor-sampler-check-") as tmp:
        workdir = pathlib.Path(tmp)
        config = write_configs(workdir, args.bread, args.port, args.tree)
        log = (workdir / "runtime.log").open("w")
        proc = subprocess.Popen([args.runtime, "--config", str(config)], stdout=log, stderr=subprocess.STDOUT)
        api = Api(args.port)
        motor1 = lambda: api.motor("dcmt0", "motor1_value")  # noqa: E731
        motor2 = lambda: api.motor("dcmt0", "motor2_value")  # noqa: E731
        try:
            if not eventually("the runtime answers", lambda: api.get("/v0/runtime/status")["status"]["code"] == "OK", 30):
                return 2
            try:
                for name, value in [
                    ("impeller_enable", True),
                    ("impeller_pwm", 100),
                    ("sample_pwm", 200),
                    ("sample_startup_delay_s", 0),
                    ("sample_interval_s", 6),
                    ("sample_pulse_s", 3),
                    ("command_keepalive_s", 2),
                ]:
                    api.set_param(name, value)
            except urllib.error.HTTPError as error:
                print(f"FAIL the sampler's parameters are declared ({error})")
                return 1
            api.post("/v0/mode", {"mode": "MANUAL"})
            api.post("/v0/mode", {"mode": "AUTO"})
            if not eventually("the impeller runs (dcmt0 motor 2 at 100)", lambda: motor2() == 100, 15):
                return 2

            api.set_param("sample_enable", True)
            ok = eventually(
                "the sampler pulses with the impeller running (dcmt0 motor 1 at 200, motor 2 at 100)",
                lambda: motor1() == 200 and motor2() == 100,
                10,
            )
            ok &= eventually(
                "between pulses the sample pump stops and the impeller runs on (motor 1 at 0, motor 2 at 100)",
                lambda: motor1() == 0 and motor2() == 100,
                10,
            )

            api.set_param("sample_enable", False)
            time.sleep(1)
            ok &= stays("disabled, the sample pump stays off (motor 1 at 0)", lambda: motor1() == 0, 8)

            api.set_param("sample_enable", True)
            api.set_param("sample_interval_s", 2)  # below sample_pulse_s = 3
            time.sleep(1)
            ok &= stays(
                "with sample_pulse_s > sample_interval_s, the sample pump stays off (motor 1 at 0)",
                lambda: motor1() == 0,
                8,
            )
            api.set_param("impeller_enable", False)
            ok &= eventually(
                "the impeller can still be turned off (dcmt0 motor 2 at 0)", lambda: motor2() == 0, 10
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

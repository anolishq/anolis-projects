#!/usr/bin/env python3
"""On-demand sampling: each "Sample now" press runs the sample pump once,
beside the periodic sampler, on dcmt0 motor 1.

Runs the bioreactor-v1 automation config and behavior tree on a local
anolis-runtime (0.9.0+, for RequestedPulseWindow), against
anolis-provider-bread in mock mode, as check_sampler.py does, then, with the
impeller running and the periodic sampler off:

1. expects no pulse before any request;
2. increases sample_requests, as the button does, and expects dcmt0 motor 1
   at sample_pwm after sample_request_delay_s, motor 2 still at impeller_pwm;
3. expects motor 1 back at 0 after sample_request_pulse_s, and no second
   pulse without a second request;
4. presses three times at once and expects one pulse (max_queued 1);
5. starts a long periodic pulse, presses during it, and expects motor 1 to
   stay at sample_pwm after the requested pulse ends, until the periodic one
   ends: either window on keeps the pump on, and neither turns it off.

Needs an anolis-runtime built with automation, and PyYAML.

Usage:
  check_sample_now.py --runtime PATH --bread PATH [--port N] [--tree PATH]

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
from check_sampler import stays


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", required=True, help="anolis-runtime binary, built with automation")
    parser.add_argument("--bread", required=True, help="anolis-provider-bread binary")
    parser.add_argument("--port", type=int, default=18493)
    parser.add_argument("--tree", type=pathlib.Path, default=TREE, help="behavior tree to run (default: this project's)")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="bioreactor-sample-now-check-") as tmp:
        workdir = pathlib.Path(tmp)
        config = write_configs(workdir, args.bread, args.port, args.tree)
        log = (workdir / "runtime.log").open("w")
        proc = subprocess.Popen([args.runtime, "--config", str(config)], stdout=log, stderr=subprocess.STDOUT)
        api = Api(args.port)
        motor1 = lambda: api.motor("dcmt0", "motor1_value")  # noqa: E731
        motor2 = lambda: api.motor("dcmt0", "motor2_value")  # noqa: E731
        requests = 0

        def press(times: int = 1) -> None:
            nonlocal requests
            for _ in range(times):
                requests += 1
                api.set_param("sample_requests", requests)

        try:
            if not eventually("the runtime answers", lambda: api.get("/v0/runtime/status")["status"]["code"] == "OK", 30):
                print((workdir / "runtime.log").read_text()[-2000:])
                return 2
            try:
                for name, value in [
                    ("impeller_enable", True),
                    ("impeller_pwm", 100),
                    ("sample_enable", False),
                    ("sample_pwm", 200),
                    ("sample_request_delay_s", 2),
                    ("sample_request_pulse_s", 3),
                    ("sample_requests", 0),
                    ("command_keepalive_s", 2),
                ]:
                    api.set_param(name, value)
            except urllib.error.HTTPError as error:
                print(f"FAIL the on-demand sampler's parameters are declared ({error})")
                return 1
            api.post("/v0/mode", {"mode": "MANUAL"})
            api.post("/v0/mode", {"mode": "AUTO"})
            if not eventually("the impeller runs (dcmt0 motor 2 at 100)", lambda: motor2() == 100, 15):
                print((workdir / "runtime.log").read_text()[-2000:])
                return 2

            ok = stays("no request: the sample pump stays off (motor 1 at 0)", lambda: motor1() == 0, 3)

            t0 = time.monotonic()
            press()
            ok &= eventually(
                "one request: the sample pump runs (motor 1 at 200, motor 2 at 100)",
                lambda: motor1() == 200 and motor2() == 100,
                10,
            )
            print(f"INFO on after {time.monotonic() - t0:.1f} s (sample_request_delay_s 2)")
            ok &= eventually("and stops after its pulse (motor 1 at 0)", lambda: motor1() == 0, 10)
            ok &= stays("no second pulse without a second request", lambda: motor1() == 0, 5)

            press(3)
            ok &= eventually("three presses at once: the pump runs", lambda: motor1() == 200, 10)
            ok &= eventually("and stops", lambda: motor1() == 0, 10)
            ok &= stays("three presses at once run one pulse (max_queued 1)", lambda: motor1() == 0, 7)

            api.set_param("sample_request_delay_s", 0)
            api.set_param("sample_startup_delay_s", 0)
            api.set_param("sample_interval_s", 60)
            api.set_param("sample_pulse_s", 10)
            api.set_param("sample_enable", True)
            ok &= eventually("a periodic pulse runs the pump (motor 1 at 200)", lambda: motor1() == 200, 5)
            press()
            ok &= stays(
                "a request during it, ending first, leaves the pump on (motor 1 at 200)",
                lambda: motor1() == 200,
                5,
            )
            ok &= eventually("the pump stops when the periodic pulse ends (motor 1 at 0)", lambda: motor1() == 0, 10)
            api.set_param("sample_enable", False)

            press()
            ok &= eventually("with the periodic sampler off again, a request still runs the pump", lambda: motor1() == 200, 5)
            ok &= eventually("and stops", lambda: motor1() == 0, 10)

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

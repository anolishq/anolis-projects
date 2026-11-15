#!/usr/bin/env python3
"""Tell a heartbeat service, once, whether the bioreactor run is healthy.

Meant for a systemd timer every minute during an unattended run (host/
run-heartbeat.timer). It reads the runtime's API and pings HEARTBEAT_URL when
the run is healthy, or HEARTBEAT_URL/fail with the reasons when it is not:

- the runtime does not answer, or answers with an error;
- the mode is not AUTO;
- the software stop is latched, or a device-loss latch is held;
- a provider is not AVAILABLE;
- a device's health is not OK, or it reports watchdog_tripped=true.

The heartbeat service (healthchecks.io, or a self-hosted Healthchecks) alerts
on a fail ping, and on silence: a Pi that lost power, network or its disk sends
nothing, which a message sent from the Pi could not report. Only the ping and
the reasons leave the Pi.

Environment: HEARTBEAT_URL (the check's ping URL, a secret), ANOLIS_API_TOKEN
(from /etc/anolis/runtime.env), ANOLIS_API (default http://127.0.0.1:8080).

Exit status: 0 when the ping was sent, whatever it said; 1 when it could not
be sent; 2 on a setup error.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT_S = 10


def get(base: str, token: str, path: str) -> dict:
    request = urllib.request.Request(base.rstrip("/") + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
        return json.load(response)


def problems(status: dict, health: dict) -> list[str]:
    """What is wrong with the run, from /v0/runtime/status and /v0/providers/health."""
    found: list[str] = []
    mode = status.get("mode")
    if mode != "AUTO":
        found.append(f"mode={mode}")
    if (status.get("estop") or {}).get("latched"):
        found.append("software stop latched")
    latched = status.get("device_loss_latched") or []
    if latched:
        found.append("device loss latched: " + ", ".join(sorted(latched)))
    for provider in health.get("providers") or []:
        provider_id = provider.get("provider_id")
        if provider.get("state") != "AVAILABLE":
            found.append(f"{provider_id} state={provider.get('state')}")
        for device in provider.get("devices") or []:
            handle = f"{provider_id}/{device.get('device_id')}"
            if device.get("health") != "OK":
                found.append(f"{handle} health={device.get('health')}")
            metrics = (device.get("reported") or {}).get("metrics") or {}
            if metrics.get("watchdog_tripped") == "true":
                found.append(f"{handle} watchdog tripped")
    return found


def ping(url: str, failure: str | None) -> None:
    target = url.rstrip("/") + ("/fail" if failure else "")
    body = (failure or "ok").encode()
    request = urllib.request.Request(target, data=body, method="POST", headers={"User-Agent": "claude-code-agent/1.0"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_S):
        pass


def main() -> int:
    url = os.environ.get("HEARTBEAT_URL", "")
    token = os.environ.get("ANOLIS_API_TOKEN", "")
    base = os.environ.get("ANOLIS_API", "http://127.0.0.1:8080")
    if not url or not token:
        print("run_heartbeat: HEARTBEAT_URL and ANOLIS_API_TOKEN must be set", file=sys.stderr)
        return 2

    try:
        status = get(base, token, "/v0/runtime/status")
        health = get(base, token, "/v0/providers/health")
        found = problems(status, health)
    except (urllib.error.URLError, OSError, ValueError) as error:
        found = [f"runtime not answering: {error}"]
    failure = "; ".join(found) or None

    try:
        ping(url, failure)
    except (urllib.error.URLError, OSError) as error:
        print(f"run_heartbeat: ping not sent: {error}", file=sys.stderr)
        return 1
    print(f"run_heartbeat: {failure or 'ok'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

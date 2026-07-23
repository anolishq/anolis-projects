# Bioreactor quickstart — fresh Pi → running experiment (workbench on the Pi)

**Audience:** operator sitting at the Pi. **Outcome:** anolis running the
bioreactor-v1 profile with observability, operated from the workbench, driving a
real experiment safely. Topology: the workbench runs **on the Pi** (you reach it
in a browser); you operate the runtime over **loopback**, so no tokens/SSH.

> ⚠️ **SAFETY FIRST — read before running any actuator (live culture!).**
> - **Hardware e-stop within reach at all times.** On this rig it cuts backplane
>   power — the strongest stop, no software trust required. When in doubt, hit it.
> - Actuators are zeroed on stop **only** by the `automation`/`full` runtime
>   variant's safe-state hooks. **§3 makes that variant active — do not skip it.**
>   The default install variant (`manual`) does NOT zero actuators and has no
>   telemetry. There is **no software e-stop button yet.**
> - Mode ladder is strict: **IDLE → MANUAL → AUTO**. To stop, descend
>   **AUTO → MANUAL → IDLE** — the AUTO→MANUAL transition is what zeros the motors.
>   `AUTO → IDLE` directly is invalid.
> - All `*_enable` params default **false** — nothing actuates until you enable it.
> - For the actual staged run (single motor → both → dosing → AUTO), follow the
>   proven **actuation runbook** (`anolis/working/actuation-bench-runbook.md`);
>   this quickstart gets you *to* that point safely.

---

## 0. Prerequisites + get these files onto the Pi

Raspberry Pi OS Bookworm (desktop, so you have a browser). Hardware already wired:
bread + ezo on I²C bus 1 at `0x0A, 0x14, 0x15, 0x61, 0x63`.

```bash
sudo apt update && sudo apt install -y i2c-tools git curl
sudo raspi-config nonint do_i2c 0          # enable I²C (0 = enable)
i2cdetect -y 1                             # EXPECT: 0a 14 15 61 63 (0x76 = non-anolis, ignore)

# Clone this project — it carries this guide, the bootstrap script, and the config:
mkdir -p ~/anolis && cd ~/anolis
git clone --depth 1 https://github.com/anolishq/anolis-projects.git
export PROJ=~/anolis/anolis-projects/projects/bioreactor-v1
```

- [ ] `i2cdetect` shows **0a 14 15 61 63** — if any are missing, fix wiring/power
      before continuing (a missing address = a silently-excluded device later).

## 1. Install + launch the workbench (on the Pi)

There is no Pi desktop installer; the workbench runs as a local server you open in
a browser. The bootstrap installs it into an isolated venv (Bookworm blocks bare
`pip install`) from the pure-python PyPI wheel:

```bash
bash "$PROJ/scripts/install-workbench-pi.sh"   # installs + launches; browser opens at :3010
# later:  anolis-workbench                      # (then open http://127.0.0.1:3010)
```

- [ ] Workbench UI loads at **http://127.0.0.1:3010**.

## 2. Provision the runtime + providers + observability

> We provision the **canonical, bench-proven bioreactor-v1 config** directly
> (the workbench's Compose→generate path currently strips the safe-state hooks,
> so we don't use it to drive live actuation). The workbench is our **operate +
> monitor** surface. `--with-observability` installs InfluxDB + Grafana natively
> and wires the tokens automatically.

```bash
cd ~/anolis
curl -fsSLO https://github.com/anolishq/anolis/releases/download/v0.1.37/install.sh
sudo bash install.sh --project "$PROJ" --with-observability 2>&1 | tee ~/anolis/install.log
echo "exit=${PIPESTATUS[0]}"     # NOT $?  (that reads tee)
```

- [ ] install exits **0** ("Anolis installation complete"); it pins runtime
      0.1.37 / bread 0.3.7 / ezo 0.3.3 and starts one `anolis-runtime.service`.

## 3. ⚠️ Activate the SAFE variant (safe-state hooks + telemetry) — REQUIRED

`install.sh` lands the `manual` variant by default (no actuator-zeroing, no
telemetry). Switch to `automation` (safe-state hooks + telemetry) and restart:

```bash
sudo cp /opt/anolis/projects/bioreactor-v1/config/anolis-runtime.bioreactor.automation.yaml \
        /opt/anolis/config/runtime.yaml
sudo systemctl restart anolis-runtime
```

- [ ] `grep -c mode_transition_hooks /opt/anolis/config/runtime.yaml` → **≥1**
      (safe-state hooks present — motors zero on AUTO→MANUAL and *→IDLE).
- [ ] `grep -A1 'telemetry:' /opt/anolis/config/runtime.yaml | grep enabled` → **true**.

## 4. Verify bring-up

```bash
curl -fsS localhost:8080/v0/runtime/status | python3 -m json.tool          # 0.1.37, mode IDLE, 5 devices
curl -fsS localhost:8080/v0/providers/health | python3 -c "
import json,sys
for p in json.load(sys.stdin)['providers']:
    for d in p['devices']:
        m=(d.get('reported') or {}).get('metrics',{})
        if 'io_ok' in m: print(d['device_id'],'io_ok',m.get('io_ok'),'io_failed',m.get('io_failed'),'wd',m.get('watchdog_tripped'),d.get('health'))"
```

- [ ] 5/5 devices, both providers **AVAILABLE**, `io_failed` low/flat, watchdogs
      not tripped.
- [ ] **Grafana** at `http://<pi-ip>:3000` (default admin login — change it); the
      `io-health` + `signal-history` dashboards show live data.

## 5. Operate from the workbench

The workbench runs on the Pi; point its Operate view at the **provisioned**
runtime on loopback (no token needed — loopback is auth-exempt). Launch it with:

```bash
ANOLIS_WORKBENCH_RUNTIME_URL=http://127.0.0.1:8080 anolis-workbench
```

In **Operate** you get: the mode ladder, live signal tables (pH, DO, temp, motor
state), device health, parameter get/set (min/max honored), device-function
calls, the automation/behavior-tree outline + fault view, an SSE event trace, and
the embedded Grafana panel.

> **Known friction:** without the `ANOLIS_WORKBENCH_RUNTIME_URL` env var the
> Operate view targets a *dev-launch* runtime, not the systemd one running the
> culture. There's no in-UI field for this yet. The env var above points it at the
> real runtime.

## 6. Run the experiment (follow the actuation runbook)

Do the actual run — staged escalation, load checks, AUTO dosing — via the proven
**`anolis/working/actuation-bench-runbook.md`** (single motor low-PWM → both →
dosing channels → AUTO), which encodes the abort criteria and the exact call
shapes. In brief, the happy path:

1. *(optional, for a provenance journal)* open a run: `POST /v0/runs {experiment_label,…}`.
2. Set params one at a time (impeller/dosing) — `POST /v0/parameters {name,value}`.
3. `IDLE → MANUAL` (`POST /v0/mode {"mode":"MANUAL"}`), verify manual control.
4. `MANUAL → AUTO` — the behavior tree begins ticking; manual calls are BLOCKED in AUTO.
5. Monitor: `/v0/automation/status`, SSE `/v0/events`, Grafana.

## 7. Stop safely (order matters)

```bash
# 1. disable behavior outputs while still in AUTO (tree zeroes on next tick):
for p in impeller_enable dose1_enable dose2_enable; do
  curl -s -X POST localhost:8080/v0/parameters -H 'content-type: application/json' -d "{\"name\":\"$p\",\"value\":false}"; done
sleep 3
# 2. AUTO → MANUAL — the safe-state hooks fire HERE and zero both DCMTs:
curl -s -X POST localhost:8080/v0/mode -H 'content-type: application/json' -d '{"mode":"MANUAL"}'
journalctl -u anolis-runtime -n 20 --no-pager | grep "transition hook"   # expect the hook-OK lines
# 3. MANUAL → IDLE:
curl -s -X POST localhost:8080/v0/mode -H 'content-type: application/json' -d '{"mode":"IDLE"}'
# 4. (if a run was opened) close it: POST /v0/runs/{id}/close
```

- [ ] motors verified at 0; mode IDLE; 5/5; hardware e-stop still available.

---

### Notes for the second (identical) reactor / novice handoff

This exact sequence reproduces on the second reactor **unchanged** — same
addresses, same profile, same steps. It IS the template. The two current rough
edges to warn them about: **§3** (must activate the `automation` variant —
provisioning doesn't do it for you) and **§5** (the `ANOLIS_WORKBENCH_RUNTIME_URL`
env var to point Operate at the real runtime). Both are tracked to be fixed in the
workbench so the next person doesn't need them.

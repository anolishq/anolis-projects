# Bioreactor quickstart — fresh Pi → running experiment (workbench on the Pi)

**Audience:** operator sitting at the Pi. **Outcome:** anolis running the
bioreactor-v1 profile with observability, operated from the workbench, driving a
real experiment safely. Topology: the workbench runs **on the Pi** (you reach it
in a browser); you operate the runtime over **loopback**, so no tokens/SSH.

> ⚠️ **SAFETY FIRST — read before running any actuator (live culture!).**
> - **Hardware e-stop within reach at all times.** On this rig it cuts backplane
>   power — the strongest stop, no software trust required. When in doubt, hit it.
> - **Two different mechanisms zero the actuators. Do not confuse them** — this
>   distinction hid a missing safe-state in this project for weeks:
>   - **`safety.safe_state`** is what the **software e-stop** (`POST /v0/estop`,
>     and the E-STOP button in the workbench's Operate view) runs. It is declared
>     in **every** variant including `manual`, so the e-stop drives outputs to
>     safe on any install.
>   - **`automation.mode_transition_hooks`** fire on **mode transitions**
>     (`AUTO→MANUAL`, `MANUAL→IDLE`, `*→FAULT`). These exist only in the
>     `automation`/`full` variants — another reason §3 matters.
> - **The software e-stop is not a substitute for the backplane cut.** It drives
>   the declared safe state and then *latches* actuation; clearing the latch does
>   **not** restart anything, and it cannot help if the runtime itself is wedged.
>   Verified on hardware 2026-08-03: with a safe state declared, pressing it
>   stopped a running impeller.
> - **The heater is not covered by the software safe state** (`bread0/rlht0`).
>   Its only actuating function takes `uint64` arguments, which a hook cannot
>   currently express — see anolishq/anolis#252. If you connect a heater load,
>   the backplane cut is its only stop.
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
sudo raspi-config nonint do_i2c 0          # enable I²C (0 = enable) — REQUIRED, see below
i2cdetect -y 1                             # EXPECT: 0a 14 15 61 63 (0x76 = non-anolis, ignore)

# Clone this project — it carries this guide, the bootstrap script, and the config:
mkdir -p ~/anolis && cd ~/anolis
git clone --depth 1 https://github.com/anolishq/anolis-projects.git
export PROJ=~/anolis/anolis-projects/projects/bioreactor-v1
```

- [ ] `i2cdetect` shows **0a 14 15 61 63** — if any are missing, fix wiring/power
      before continuing (a missing address = a silently-excluded device later).

> **Do not skip the `raspi-config` line.** `install.sh` claims to enable I²C for
> you and, on any Pi with HDMI attached, does not — its check globs `/dev/i2c-*`
> and matches the HDMI DDC buses (`i2c-20`, `i2c-21`), so it reports
> `✓ i2c: already enabled` while the GPIO bus `/dev/i2c-1` does not exist. The
> install then fails 30 s later with `health: runtime not responding` and never
> names the cause. Tracked as anolishq/anolis#249; until it is fixed, enabling
> I²C by hand here is what makes the install work.
>
> Symptom if you get it wrong, visible only in the journal:
> `failed to open I2C bus '/dev/i2c-1': No such file or directory`

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

> We provision the **canonical, bench-proven bioreactor-v1 config** directly, and
> use the workbench as the **operate + monitor** surface.
> `--with-observability` installs InfluxDB + Grafana natively and wires the tokens
> automatically.
>
> The reason for provisioning directly was that the workbench's Compose→generate
> path stripped the safe-state hooks. That predates the canonical-authoring flip
> (anolishq/anolis-workbench#255), which may well have fixed it — but **it has not
> been re-verified since**, so this guide keeps the direct path. Do not author a
> config for live actuation through Compose until someone confirms the hooks and
> the `safety:` block survive the round trip.

```bash
cd ~/anolis
curl -fsSLO https://github.com/anolishq/anolis/releases/download/v0.1.40/install.sh
sudo bash install.sh --project "$PROJ" --variant manual --with-observability 2>&1 | tee ~/anolis/install.log
echo "exit=${PIPESTATUS[0]}"     # NOT $?  (that reads tee)
```

- [ ] install exits **0** ("Anolis installation complete"); it pins runtime
      0.1.40 / bread 0.3.8 / ezo 0.3.4 and starts one `anolis-runtime.service`.

> **Read the exit code, not the banner.** `install.sh` prints a large
> "Anolis installation complete" box *before* reporting failure, so a failed
> install still shows a success-looking banner with `✗ Runtime did not come up`
> underneath it. Trust `exit=` and the `✓/✗` lines.
>
> `--variant manual` makes the machine **boot inert** — no autonomous actuation
> until you deliberately activate automation in §3.

## 3. ⚠️ Activate the automation variant (mode-transition hooks + telemetry)

`install.sh` lands the `manual` variant by default: boot-inert, no automation, no
telemetry. The **software e-stop works on `manual` too** (every variant declares
`safety.safe_state`), but `manual` has no `mode_transition_hooks`, so nothing is
zeroed on a mode change — and no telemetry is recorded. Switch to `automation`
and restart:

```bash
sudo cp /opt/anolis/projects/bioreactor-v1/config/anolis-runtime.bioreactor.automation.yaml \
        /opt/anolis/config/runtime.yaml
sudo systemctl restart anolis-runtime
```

- [ ] `grep -c mode_transition_hooks /opt/anolis/config/runtime.yaml` → **≥1**
      (mode hooks present — motors zero on AUTO→MANUAL, MANUAL→IDLE and *→FAULT).
- [ ] `grep -c '^safety:' /opt/anolis/config/runtime.yaml` → **1**
      (the e-stop safe state; should be present on every variant).
- [ ] `grep -A1 'telemetry:' /opt/anolis/config/runtime.yaml | grep enabled` → **true**.

## 4. Verify bring-up

```bash
curl -fsS localhost:8080/v0/runtime/status | python3 -m json.tool          # 0.1.40, mode IDLE, 5 devices
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

> **Known friction — the env var is load-bearing, not optional.** Re-verified on
> hardware 2026-08-03 with workbench 0.14.0. Without it the Operate proxy returns
> `503 {"error": "Runtime is not running"}` even though the systemd runtime is up
> and healthy on the same box. Two reasons, both in anolishq/anolis-workbench#277:
> the workbench's external-runtime discovery iterates `~/.anolis/systems`, which
> an `install.sh --project` machine never populates; and even after importing, it
> skips any runtime whose configured bind is not loopback — and `install.sh
> --project` always emits `bind: 0.0.0.0`.
>
> **The env var only fixes half of it.** It patches the proxy, so live data flows
> and the device tables work — but `launcher.get_status()` never consults it, so
> `/api/status` still reports `running: false, active_project: null`. Anything
> keyed on that (the not-running banner, active-project display, and the #264
> logic that hides the E-stop when a *different* project is running) stays wrong.
> Treat Operate's data as trustworthy and its chrome as not, until #277 lands.

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
addresses, same profile, same steps. It IS the template. Four rough edges to warn
them about, all tracked:

| Where | Rough edge | Tracked as |
|---|---|---|
| §0 | `install.sh` does not actually enable I²C on a Pi with HDMI — enable it by hand | anolishq/anolis#249 |
| §2 | "installation complete" banner prints even when the install failed — read the exit code | anolishq/anolis#249 |
| §3 | must activate the `automation` variant; provisioning does not do it for you | — |
| §5 | `ANOLIS_WORKBENCH_RUNTIME_URL` is required, and only fixes Operate's data, not its chrome | anolishq/anolis-workbench#277 |

Last walked end-to-end on real hardware **2026-08-03** (fresh wipe → install of
v0.1.40 → workbench 0.14.0 → software e-stop verified stopping a live impeller).

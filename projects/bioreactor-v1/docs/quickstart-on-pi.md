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
> - **The heater (`bread0/rlht0`) is turned off by the software safe state**
>   and, in the `automation`/`full` variants only, by the `MANUAL→IDLE` hook.
>   A call reported OK is a frame sent, not one applied
>   (anolishq/anolis-provider-bread#134), so read `rlht0` back after entering
>   IDLE. The backplane cut remains its emergency stop.
> - Mode ladder is strict: **IDLE → MANUAL → AUTO**. To stop, descend
>   **AUTO → MANUAL → IDLE** — the AUTO→MANUAL transition is what zeros the motors.
>   `AUTO → IDLE` directly is invalid.
> - All `*_enable` params default **false** — nothing actuates until you enable it.
> - For the actual staged run (single motor → both → dosing → AUTO), follow the
>   proven **actuation runbook** (`anolis/working/actuation-bench-runbook.md`);
>   this quickstart gets you *to* that point safely.

---

## 0. Prerequisites, host prep, and these files on the Pi

64-bit Raspberry Pi OS based on **Debian 13 (Trixie)**, desktop (so you have a
browser), on a Raspberry Pi 4. The released binaries need glibc 2.38 or newer, so a
Bookworm (Debian 12, glibc 2.36) image cannot run them; `install.sh` stops with the
loader's message if you try. Hardware already wired: bread + ezo on I²C bus 1 at
`0x0A, 0x14, 0x15, 0x61, 0x63`.

**Slice firmware.** Flash each Slice from the `main` branch of its repository
(feastorg/Slice_RLHT, feastorg/Slice_DCMT), from `firmware/`, with the gen1
environment: `pio run -e gen1_nano -t upload`. The RLHT defaults to 0x0A and the
DCMT to 0x15. Build the DCMT that goes at 0x14 with
`PLATFORMIO_BUILD_FLAGS=-DI2C_ADR=20`, and make sure the variable is unset for
the others. Two DCMTs on one address collide on the bus. The board generation
is a build flag and cannot be read over the bus, so check the environment before
you flash. Unplug the USB cable afterwards. A laptop left on a Slice's USB port
powers it, so a backplane power cut does not stop that board; this was seen on the
RLHT.

```bash
sudo apt update && sudo apt install -y i2c-tools git curl

# Clone this project — it carries this guide, the host prep, and the config:
mkdir -p ~/anolis && cd ~/anolis
git clone --depth 1 https://github.com/anolishq/anolis-projects.git
export PROJ=~/anolis/anolis-projects/projects/bioreactor-v1

# Host prep: I²C on, the 50 kHz bus clock with the core clock pinned, i2c-dev,
# and the anolis user with access to the bus. Safe to re-run.
sudo bash "$PROJ/host/prep-raspberrypi-os.sh"
sudo reboot                                # only if it printed REBOOT REQUIRED
```

After the reboot:

```bash
export PROJ=~/anolis/anolis-projects/projects/bioreactor-v1
sudo bash "$PROJ/host/prep-raspberrypi-os.sh" --check   # EXPECT: host prep: nothing to do
i2cdetect -y 1                                          # EXPECT: 0a 14 15 61 63 (0x76 = non-anolis, ignore)
```

- [ ] `--check` reports nothing to do, and `i2cdetect` shows **0a 14 15 61 63** —
      if any address is missing, fix wiring/power before continuing (a missing
      address = a silently-excluded device later).

The DO circuit reports mg/L only out of the box, and this project also reads %
saturation. Turn that output on once; the circuit stores it across power
cycles. Each command is written, then its reply read about 0.6 s later:

```bash
sudo i2ctransfer -y 1 w3@0x61 0x4f 0x2c 0x3f; sleep 0.6; sudo i2ctransfer -y 1 r20@0x61              # O,?
sudo i2ctransfer -y 1 w5@0x61 0x4f 0x2c 0x25 0x2c 0x31; sleep 0.6; sudo i2ctransfer -y 1 r20@0x61    # O,%,1
sudo i2ctransfer -y 1 w3@0x61 0x4f 0x2c 0x3f; sleep 0.6; sudo i2ctransfer -y 1 r20@0x61              # O,?
```

- [ ] The last reply starts `0x01 0x3f 0x4f 0x2c 0x4d 0x47 0x2c 0x25`
      (`?O,MG,%`). Without the `%` output, `do_saturation_pct` reads
      `UNAVAILABLE`. The configs leave it out of `do0`'s health (§4), so
      `do0` reads OK either way.

> **Why host prep exists.** anolis deploys software and does not set up the
> host's hardware (anolishq/anolis#318). The script sets three `config.txt` lines
> this machine needs: `dtparam=i2c_arm=on`, `dtparam=i2c_arm_baudrate=50000` and
> `core_freq_min=500`. On a Pi 4 the I²C clock follows the VPU core clock, so
> without the pin the configured rate is only a ceiling. The gen1 slices lost
> retried writes at 98 kHz and returned corrupted reads at 66–79 kHz; 49.7 kHz
> was clean (feastorg/CRUMBS#97).

## 1. Install + launch the workbench (on the Pi)

There is no Pi desktop installer; the workbench runs as a local server you open in
a browser. The bootstrap installs it into an isolated venv (Raspberry Pi OS blocks
bare `pip install`) from the pure-python PyPI wheel:

```bash
bash "$PROJ/scripts/install-workbench-pi.sh"   # installs + launches; browser opens at :3010
# later:  anolis-workbench                      # (then open http://127.0.0.1:3010)
```

The launch opens a browser on the Pi's desktop and keeps the terminal. Over SSH,
run the script with `--no-launch`, then start `anolis-workbench` from the
desktop session.

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
curl -fsSLO https://github.com/anolishq/anolis/releases/download/v0.1.45/install.sh
sudo bash install.sh --project "$PROJ" --variant manual --with-observability 2>&1 | tee ~/anolis/install.log
echo "exit=${PIPESTATUS[0]}"     # NOT $?  (that reads tee)
```

- [ ] install exits **0** ("Anolis installation complete"); it pins runtime
      0.1.45 / bread 0.5.2 / ezo 0.4.1 and starts one `anolis-runtime.service`.
- [ ] the **host preflight** lines read `✓ host preflight: bread0: host
      requirements met` and the same for `ezo0`.

> **The install renames the Pi** to `anolis-` plus the last eight characters of
> its serial number (`✓ hostname: anolis-…`). Reconnect by the new name or by IP
> address.
>
> **`⚠ observability: grafana health check timed out`** can appear on a first
> install while Grafana is still starting. `curl -fsS localhost:3000/api/health`
> reporting `"database": "ok"` afterwards means it came up.

> **Before anything starts, `install.sh` checks the host.** As `anolis` it runs
> every binary and asks each provider what it needs (`--check-host`): the bus
> node present and openable, and for bread the bus clock at or under 50 kHz. If
> something is unmet it stops and prints the fix — usually: re-run host prep and
> reboot. `--allow-unmet-host` installs anyway; those providers then start with no
> devices until the host is fixed and the service restarted.

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
curl -fsS localhost:8080/v0/runtime/status | python3 -m json.tool          # 0.1.45, mode IDLE, 5 devices
curl -fsS localhost:8080/v0/providers/health | python3 -c "
import json,sys
for p in json.load(sys.stdin)['providers']:
    for d in p['devices']:
        m=(d.get('reported') or {}).get('metrics',{})
        if 'io_ok' in m: print(d['device_id'],'io_ok',m.get('io_ok'),'io_failed',m.get('io_failed'),'wd',m.get('watchdog_tripped'),d.get('health'))"
```

- [ ] 5/5 devices, both providers **AVAILABLE**, `io_failed` low/flat, watchdogs
      not tripped, every device's health **OK**.
- [ ] `rlht0`'s `t1_c` reads room temperature. Exactly `0.0` with quality OK means
      the thermocouple is not reading: check the connector and polarity, then
      warm the junction with your fingers and watch it climb.
- [ ] **Grafana** binds `127.0.0.1:3000` on the Pi. From your machine, open a
      tunnel with `ssh -L 3000:127.0.0.1:3000 <user>@<pi>` and browse
      `http://localhost:3000`; the `io-health` + `signal-history` dashboards
      show live data. The `admin` password is `GRAFANA_ADMIN_PASSWORD` in
      `/etc/anolis/observability.env` (root only:
      `sudo grep GRAFANA_ADMIN_PASSWORD /etc/anolis/observability.env`).
      Adding `--with-grafana-network` to the §2 install line opens Grafana to
      the LAN instead.

> **Two signals are left out of device health.** The runtime configs'
> `health.excluded_signals` drops `t2_c` from `rlht0` (only TC1 has a
> thermocouple; the empty TC2 reads quality `FAULT`, open circuit) and
> `do_saturation_pct` from `do0` (it reads `UNAVAILABLE` while the circuit's `%`
> output is off). Both are still read, served and recorded with their own
> quality; only the device's health ignores them. If you fit a second
> thermocouple, delete the `bread0/rlht0` entry so a fault on TC2 shows again. A
> misspelt entry excludes nothing: the runtime logs a WARN naming it after
> discovery, and the device reads FAULT or STALE as before
> (anolishq/anolis#325).

## 5. Operate from the workbench

The workbench runs on the Pi; point its Operate view at the **provisioned**
runtime on loopback (no token needed — loopback is auth-exempt). Launch it with:

```bash
ANOLIS_WORKBENCH_RUNTIME_URL=http://127.0.0.1:8080 anolis-workbench
```

The Compose, Commission and Operate tabs stay disabled until a project is open.
On the home page, under **Import Machine Profile**, enter the project directory
(the value of `$PROJ`, e.g. `/home/<you>/anolis/anolis-projects/projects/bioreactor-v1`)
and import it. The workbench opens the project; then choose **Operate**.

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
> On 2026-10-12 (workbench 0.14.0) this held only until the project was imported:
> after the import the header read `Running: bioreactor-v1`.

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
addresses, same profile, same steps. It IS the template. Rough edges to warn
them about:

| Where | Rough edge | Tracked as |
|---|---|---|
| §0 | host prep comes before `install.sh`, and may need a reboot; `install.sh` no longer touches `config.txt` | anolishq/anolis#318 |
| §0 | the DO circuit's % saturation output is off out of the box; turn it on before installing | — |
| §2 | "installation complete" banner prints even when the install failed — read the exit code | anolishq/anolis#249 |
| §2 | the install renames the Pi to `anolis-<serial>` | — |
| §3 | must activate the `automation` variant; provisioning does not do it for you | — |
| §4 | `t2_c` and `do_saturation_pct` are left out of device health; delete the `rlht0` entry if a second thermocouple is fitted | anolishq/anolis#325 |
| §5 | Operate is disabled until the project is imported | — |
| §5 | `ANOLIS_WORKBENCH_RUNTIME_URL` is required for Operate's data | anolishq/anolis-workbench#277 |

Walked end-to-end on real hardware **2026-08-03** (fresh wipe → install of
v0.1.40 → workbench 0.14.0 → software e-stop verified stopping a live impeller).
This revision (host prep, anolis 0.1.43, bread 0.5.0, ezo 0.4.0) was walked
through §5 on a fresh card on **2026-10-12**, with workbench 0.14.0 and nothing
actuated; §6 and §7 were not run.

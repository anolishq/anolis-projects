# Bioreactor quickstart — fresh Pi → running experiment (workbench on the Pi)

**Audience:** operator sitting at the Pi. **Outcome:** anolis running the
bioreactor-v1 profile with observability, operated from the workbench, driving a
real experiment safely. Topology: the workbench runs **on the Pi** (you reach it
in a browser); you operate the runtime over **loopback**, so no SSH. The
runtime's API still needs its token (§4 shows how to send it).

> ⚠️ **SAFETY FIRST — read before running any actuator (live culture!).**
> - **Hardware e-stop within reach at all times.** On this rig it cuts backplane
>   power — the strongest stop, no software trust required. When in doubt, hit it.
> - **Two different mechanisms zero the actuators. Do not confuse them** — this
>   distinction hid a missing safe-state in this project for weeks:
>   - **`safety.safe_state`** is what the **software e-stop** (`POST /v0/estop`,
>     and the SOFTWARE STOP button in the workbench's Operate view) runs. It is declared
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
>   Whether a call reported OK was applied depends on the slice firmware:
>   `rlht0`'s `set_confirmation` health metric reads `acknowledged` (applied),
>   `delivery_only` (dispatched) or `unconfirmed` (a frame sent, not one
>   applied) (anolishq/anolis-provider-bread#134), so read `rlht0` back after
>   entering IDLE. The backplane cut remains its emergency stop.
> - Mode ladder is strict: **IDLE → MANUAL → AUTO**. To stop, descend
>   **AUTO → MANUAL → IDLE** — the AUTO→MANUAL transition is what zeros the motors.
>   `AUTO → IDLE` directly is invalid.
> - All `*_enable` params default **false** — nothing actuates until you enable it.
> - For the actual staged run (single motor → both → dosing → AUTO), follow the
>   steps in §6, with the parameters and defaults in
>   [`runbook.md`](./runbook.md); this quickstart gets you *to* that point safely.

---

## 0. Prerequisites, host prep, and these files on the Pi

64-bit Raspberry Pi OS based on **Debian 13 (Trixie)**, desktop (so you have a
browser), on a Raspberry Pi 4. The released binaries need glibc 2.38 or newer, so a
Bookworm (Debian 12, glibc 2.36) image cannot run them; `install.sh` stops with the
loader's message if you try. Hardware already wired: bread + ezo on I²C bus 1 at
`0x13, 0x14, 0x15, 0x61, 0x63`.

**Slice firmware.** Flash each Slice from the `main` branch of its repository
(feastorg/Slice_RLHT, feastorg/Slice_DCMT), from `firmware/`, with the gen1
environment: `pio run -e gen1_nano -t upload`. The RLHT defaults to 0x13 and the
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
# and the anolis user with access to the bus. Safe to re-run. Before its first
# change it saves config.txt as config.txt.host-prep.bak beside it, and it
# refuses a board that is not a Pi 4 (--any-board overrides).
sudo bash "$PROJ/host/prep-raspberrypi-os.sh"
sudo reboot                                # only if it printed REBOOT REQUIRED
```

After the reboot:

```bash
export PROJ=~/anolis/anolis-projects/projects/bioreactor-v1
sudo bash "$PROJ/host/prep-raspberrypi-os.sh" --check   # EXPECT: host prep: nothing to do
i2cdetect -y 1                                          # EXPECT: 13 14 15 61 63 (0x76 = non-anolis, ignore)
```

- [ ] `--check` reports nothing to do, and `i2cdetect` shows **13 14 15 61 63** —
      if any address is missing, fix wiring/power before continuing (a missing
      address = a device excluded later, reported missing in provider health).

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
      `UNAVAILABLE`.

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
bare `pip install`) from the pure-python PyPI wheel, at the version the script
pins (`WORKBENCH_VERSION`, 0.29.0 in this revision; Renovate bumps it). Set
`ANOLIS_WORKBENCH_VERSION` to install another:

```bash
bash "$PROJ/scripts/install-workbench-pi.sh"   # installs + starts the server at :3010
# later:  anolis-workbench                      # (then open http://127.0.0.1:3010)
```

The launch serves http://127.0.0.1:3010 and keeps the terminal. On a Pi it
does not open a browser by itself: open that address in the desktop browser, or
launch with `ANOLIS_WORKBENCH_OPEN_BROWSER=1`. Over SSH,
run the script with `--no-launch`, then start `anolis-workbench` from the
desktop session.

The script puts all four of the package's commands on PATH from its venv:
`anolis-workbench`, `anolis-provision`, `anolis-package` and `anolis-validate`.
This guide expects that venv. If the workbench is also installed with `pipx`,
the workbench README's other route, the script says so: remove that copy with
`pipx uninstall anolis-workbench`, so one install at one version answers for
all four.

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

The runtime version comes from the project itself, so this step never names one:
`install.sh` is downloaded from the release `machine-profile.yaml` pins under
`components.runtime`, and checked against that release's `SHA256SUMS`.

```bash
cd ~/anolis
RT=$(awk '/^components:/{c=1} c && /^  runtime:/{r=1} r && /version:/{gsub(/"/,"",$2); print $2; exit}' "$PROJ/machine-profile.yaml")
echo "runtime pin: $RT"
curl -fsSLO "https://github.com/anolishq/anolis/releases/download/v${RT}/install.sh"
curl -fsSLO "https://github.com/anolishq/anolis/releases/download/v${RT}/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS          # EXPECT: install.sh: OK
sudo bash install.sh --project "$PROJ" --variant manual --with-observability 2>&1 | tee ~/anolis/install.log
echo "exit=${PIPESTATUS[0]}"     # NOT $?  (that reads tee)
```

- [ ] install exits **0** ("Anolis installation complete"); it installs the
      runtime and provider versions pinned under `components` in
      `machine-profile.yaml` and starts one `anolis-runtime.service`.
- [ ] the **host preflight** lines read `✓ host preflight: bread0: host
      requirements met` and the same for `ezo0`.

> **On an upgrade, leave the runtime running.** `install.sh` restarts it once,
> near the end. Stopping it first leaves the boards' 5 s watchdogs unserviced for
> the whole install: every board trips, and the startup safe state is refused
> with `WATCHDOG_TRIP` (anolishq/anolis#711). If they did trip, clear each board
> in Operate, then restart the runtime to re-apply the safe state.

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

> **Read the exit code as well as the banner.** A failed install's banner reads
> "Anolis installed, but NOT ready", and its last line says why the install did
> NOT succeed. Trust `exit=` and the `✓/✗` lines.
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

- [ ] `grep -c '^  mode_transition_hooks:' /opt/anolis/config/runtime.yaml` → **1**
      (mode hooks present — motors zero on AUTO→MANUAL, MANUAL→IDLE and *→FAULT).
- [ ] `grep -c '^safety:' /opt/anolis/config/runtime.yaml` → **1**
      (the e-stop safe state; should be present on every variant).
- [ ] `grep -A1 'telemetry:' /opt/anolis/config/runtime.yaml | grep enabled` → **true**.
- [ ] `journalctl -u anolis-runtime -o cat | grep -F '[Config] Data dir:' | tail -1`
      ends **`/opt/anolis/anolis-data`**: the e-stop latch and the run journal are
      where `install.sh` put them. The variant names `data_dir: ../anolis-data`
      for this (anolishq/anolis#643).

## 4. Verify bring-up

Every runtime call needs the API token, from the device itself too: since anolis
0.1.48 loopback is not exempt, and a call without it gets `401`. `install.sh`
keeps the token in `/etc/anolis/runtime.env` (root only). `anolis_api` reads it
there and hands it to `curl` on stdin, so it never appears in a command line or
in your shell history. Define it once per shell:

```bash
anolis_api() {
  sudo sed -n 's/^ANOLIS_API_TOKEN=/Authorization: Bearer /p' /etc/anolis/runtime.env \
    | curl -fsS -H @- "$@"
}
```

```bash
anolis_api localhost:8080/v0/runtime/status | python3 -m json.tool          # version = $RT, mode IDLE, 5 devices
anolis_api localhost:8080/v0/providers/health | python3 -c "
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

> **`rlht0`'s `t2_c` is left out of device health.** Only TC1 has a
> thermocouple. The empty TC2 reads one of two ways, depending on how it is
> empty: quality `FAULT` when the MAX6675 sees an open probe, or `0.0` °C with
> quality `OK` when its MISO line is stuck low (feastorg/Slice_RLHT#48). On
> the reference rig it read `FAULT` on 2026-10-12, and `0.0` `OK` from
> 2026-10-16. Neither is a temperature, so the runtime configs'
> `health.excluded_signals` drops `t2_c` from `rlht0`'s health, and `rlht0`
> reads OK. `t2_c` is still read, served and recorded with its own
> quality. If you fit a second thermocouple, delete the `bread0/rlht0` entry so a
> fault on TC2 shows again. A misspelt entry excludes nothing: the runtime logs a
> WARN naming it after discovery, and `rlht0` reads FAULT as before
> (anolishq/anolis#325).

## 5. Operate from the workbench

Run the workbench as a service that holds the runtime's token.
`anolis-provision workbench-service` installs a systemd service for the
workbench, which starts at boot, runs as you and binds 127.0.0.1:3010. It copies
the runtime's API token alone into `/etc/anolis/workbench-runtime-token`, a
`0600` file owned by you, and asks for your sudo password to do it. The runtime
install is left as it is. The service needs no environment variables: the
workbench sends that token only to a runtime on this machine.

The service listens on the same port as the workbench §1 started, so stop that
one first (Ctrl+C in its terminal). Then:

```bash
anolis-provision workbench-service
```

It prints the ssh tunnel command for reaching the service from another
machine. On the Pi, open `http://127.0.0.1:3010`.

There is nothing to import. Each time it starts, the workbench imports the
project `install.sh` installed (`/opt/anolis/projects/bioreactor-v1`), read-only,
so **bioreactor-v1** is on the home page. Open it, then choose **Operate**. If a
project of your own is already called bioreactor-v1, it is kept, and the
installed one is `bioreactor-v1-installed`.

- [ ] Operate's Runtime Status reads the runtime's version and mode, and the
      header reads `Running: bioreactor-v1`.

In **Operate** you get: the mode ladder, live signal tables (pH, DO, temp, motor
state), device health, parameter get/set (min/max honored), device-function
calls, the automation/behavior-tree outline + fault view, an SSE event trace, and
the embedded Grafana panel.

> **After rotating the runtime's token,** run `anolis-provision workbench-service`
> again to refresh the copy.
>
> **To point the workbench at a runtime URL instead,** for a runtime on another
> machine or a development run, launch it with two environment variables. With
> `ANOLIS_WORKBENCH_RUNTIME_URL` set, the workbench sends only the token given in
> `ANOLIS_WORKBENCH_RUNTIME_TOKEN`, never the service's copy. For this Pi's
> runtime, from a terminal workbench rather than the service:
>
> ```bash
> ANOLIS_WORKBENCH_RUNTIME_URL=http://127.0.0.1:8080 \
> ANOLIS_WORKBENCH_RUNTIME_TOKEN="$(sudo sed -n 's/^ANOLIS_API_TOKEN=//p' /etc/anolis/runtime.env)" \
>   anolis-workbench
> ```
>
> The token is read into the workbench's environment, never into a command line
> or your shell history.

## 6. Run the experiment

Do the actual run — staged escalation, load checks, AUTO dosing — one stage at
a time (single motor low-PWM → both → dosing channels → AUTO), with the
parameters and defaults in [`runbook.md`](./runbook.md). Check each stage's
readings before the next, and at anything unexpected stop as §7 describes. In
brief, the happy path:

1. *(optional, for a provenance journal)* open a run: `POST /v0/runs {label,…}`.
2. Set params one at a time (impeller/dosing) — `POST /v0/parameters {name,value}`.
3. `IDLE → MANUAL` (`POST /v0/mode {"mode":"MANUAL"}`), verify manual control.
4. `MANUAL → AUTO` — the behavior tree begins ticking; manual calls are BLOCKED in AUTO.
5. Monitor: `/v0/automation/status`, SSE `/v0/events`, Grafana.

## 7. Stop safely (order matters)

```bash
# 1. disable behavior outputs while still in AUTO (tree zeroes on next tick):
# (anolis_api from §4: the token goes to curl on stdin)
for p in impeller_enable dose1_enable dose2_enable; do
  anolis_api -X POST localhost:8080/v0/parameters -H 'content-type: application/json' -d "{\"name\":\"$p\",\"value\":false}"; done
sleep 3
# 2. AUTO → MANUAL — the safe-state hooks fire HERE and zero both DCMTs:
anolis_api -X POST localhost:8080/v0/mode -H 'content-type: application/json' -d '{"mode":"MANUAL"}'
journalctl -u anolis-runtime -n 20 --no-pager | grep "transition hook"   # expect the hook-OK lines
# 3. MANUAL → IDLE:
anolis_api -X POST localhost:8080/v0/mode -H 'content-type: application/json' -d '{"mode":"IDLE"}'
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
| §2 | the install renames the Pi to `anolis-<serial>` | — |
| §3 | must activate the `automation` variant; provisioning does not do it for you | — |
| §4 | `rlht0`'s `t2_c` is left out of device health; delete that entry if a second thermocouple is fitted | anolishq/anolis#325 |

Walked end-to-end on real hardware **2026-08-03** (fresh wipe → install of
v0.1.40 → workbench 0.14.0 → software e-stop verified stopping a live impeller).
An earlier revision (host prep, anolis 0.1.43, bread 0.5.0, ezo 0.4.0, the RLHT
at 0x0A) was walked through §5 on a fresh card on **2026-10-12**, with workbench
0.14.0 and nothing actuated; §6 and §7 were not run. A revision pinning anolis
0.1.56, bread 0.9.3 and ezo 0.4.1 (the RLHT at 0x13, token-authenticated calls)
had §2 and §4 walked on the `manual` variant on **2026-10-27**, as an upgrade
from anolis 0.1.55 on an already-prepped host; §3, §5–§7 and dashboards with
live data were not. The next, pinning anolis 0.1.57, changed only the bundled
Grafana dashboards. This revision pins anolis 0.9.2, bread 0.10.0,
workbench 0.29.0 and telemetry-export 0.2.0. It had §0–§5 walked on
**2026-11-01** on the reference rig, in place on a host already running these
pins: every check passed, and §4's two dashboards showed live data. §0's
`i2cdetect` and DO commands were not run, because the running runtime held the
bus; §4's five devices and `do_saturation_pct` reading OK stood in for them.
§6–§7 were not run. The revision pinning anolis 0.6.0 and workbench 0.27.0 had §5
checked on **2026-10-30** on a Pi, with no
environment variables and no import by hand: at startup the workbench imported
bioreactor-v1 from `/opt/anolis`, and Operate's proxied runtime status answered
200. anolis 0.2.0 through
0.9.0 and bread 0.10.0 each change what an existing install does, so read
their upgrade notes before upgrading: browser origins not listed in
`http.cors_allowed_origins` are
refused, an install whose safe state cannot be planned fails, bread drives its
outputs safe each time it starts, `install.sh` resolves a relative
`runtime.data_dir` against the config's directory, which §3 relies on,
`install.sh --uninstall` refuses a `--prefix` its units don't run from and
keeps the workbench's `anolis-workbench.service`, a software stop on the
automation variant logs one INFO line for the FAULT hooks the latch holds where
it logged four ERRORs, Grafana stops updating its own plugins once install.sh
runs again with `--with-observability`, Signal History refreshes every 30 s,
the automation tree's result is logged once rather than on every tick, run
records are synced to storage before the API answers, a write InfluxDB rejects
is dropped rather than retried, a device call automation keeps failing puts the
runtime in FAULT (three in a row by default; a dose pump left braked in AUTO
now faults after three refused pulses), and the operator panel's
`experiment` is now `run`: with workbench 0.29.0, Start run runs the groups
ticked On and no longer switches them on itself. The
`automation` and `full` variants set `automation.on_terminal: repeat`, so the
tree is still ticked again after each pass, as before.

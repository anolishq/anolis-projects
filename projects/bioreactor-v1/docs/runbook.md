# Bioreactor v1 — Runbook

## Hardware

| Slot   | Device | Type                                 | I²C address |
| ------ | ------ | ------------------------------------ | ----------- |
| bread0 | rlht0  | RLHT (relay heater; TC1 in the liquid, TC2 on the heater pad) | 0x13 |
| bread0 | dcmt0  | DCMT (sample pump ch1, impeller ch2) | 0x14        |
| bread0 | dcmt1  | DCMT (dose1 ch1, dose2 ch2)          | 0x15        |
| ezo0   | ph0    | Atlas EZO-pH                         | 0x63        |
| ezo0   | do0    | Atlas EZO-DO                         | 0x61        |

- **Bus**: Raspberry Pi `/dev/i2c-1`, at 50 kHz with the core clock pinned. Run
  `host/prep-raspberrypi-os.sh` once on a new Pi (and reboot if it says so) before
  launching anything; `--check` reports without changing.
- **bread0**: CRUMBS controller — bread provider on I²C bus
- **ezo0**: EZO shield in I²C mode — ezo provider on the same bus

## Repository layout (sibling checkout)

```
<parent>/
├── anolis/                     ← runtime + build output
├── anolis-projects/            ← this repo
├── anolis-provider-bread/      ← bread provider binary
└── anolis-provider-ezo/        ← ezo provider binary
```

All repos must be direct siblings of a shared parent directory. The runtime YAML
files reference provider executables and configs with `../` relative paths.

## Build prerequisites

See each provider repo's README for build instructions:

- [anolis-provider-bread](../../../../anolis-provider-bread/README.md)
- [anolis-provider-ezo](../../../../anolis-provider-ezo/README.md)
- [anolis](../../../../anolis/README.md)

Target preset for hardware: `dev-release` (bread), `dev-linux-hardware-release` (ezo)

Expected binary paths (from inside `anolis/`):

```
../anolis-provider-bread/build/dev-release/anolis-provider-bread
../anolis-provider-ezo/build/dev-linux-hardware-release/anolis-provider-ezo
build/dev-release/core/anolis-runtime
```

## Launch sequence

Run from the `anolis/` directory:

### Manual (no telemetry, no automation)

```sh
./build/dev-release/core/anolis-runtime \
  --config ../anolis-projects/projects/bioreactor-v1/config/anolis-runtime.bioreactor.manual.yaml
```

### With telemetry (InfluxDB required)

The InfluxDB token comes from the `INFLUXDB_TOKEN` environment variable —
never from the config file, which is world-readable. On a provisioned device
`install.sh --with-observability` writes a write-scoped token into
`/etc/anolis/runtime.env`; on a dev bench export it yourself (e.g.
`export INFLUXDB_TOKEN=dev-token` against the compose stack's defaults).
Then:

```sh
./build/dev-release/core/anolis-runtime \
  --config ../anolis-projects/projects/bioreactor-v1/config/anolis-runtime.bioreactor.telemetry.yaml
```

### With automation

```sh
./build/dev-release/core/anolis-runtime \
  --config ../anolis-projects/projects/bioreactor-v1/config/anolis-runtime.bioreactor.automation.yaml
```

### Full (telemetry + automation)

```sh
./build/dev-release/core/anolis-runtime \
  --config ../anolis-projects/projects/bioreactor-v1/config/anolis-runtime.bioreactor.full.yaml
```

## Workbench (anolis-workbench)

Launch the workbench, then open <http://127.0.0.1:3010> and select/import this
project from the UI (the CLI has no `session`/`--system` flags; it only takes
`--host` / `--port` / `--no-browser` / `--version`):

```sh
anolis-workbench
```

For a fresh Raspberry Pi (workbench-on-Pi + provisioning), follow
[`docs/quickstart-on-pi.md`](./quickstart-on-pi.md).

## Probe calibration (pH and DO)

`ph0` and `do0` calibrate through their own functions, from Operate or the
runtime API. Needs anolis-provider-ezo 0.5.0 or later for `calibrate` and
`clear_calibration`, and 0.5.1 or later for the calibration-level signals used
below to check the result.

**Before you start**

- Never run the ADPP conformance harness against these probes: it calls
  `calibrate` and `clear_calibration` and overwrites their calibration.
- The software stop must be clear. While it is latched the runtime refuses both
  functions, like any CONFIG function.
- Let the probe reach its operating temperature (DO: about 10 minutes) and sit
  in the reference solution, or in air for DO atmospheric, until the reading in
  Operate's Readings panel or Grafana is steady. Calibrate only once it is.
- Use the value printed on the solution's label for `reference_ph`.
- Allow time. On the reference rig on 2026-11-02, pH took about 20 minutes to
  settle in each buffer, and DO 20 to 30 minutes in air, longer after the
  zero-oxygen solution. A reading still moving by more than its minute-to-minute
  noise is not ready.
- Check pH 10 buffer against an independent one before calibrating `high`. It
  degrades in air: two old bottles read 8.99 and 9.26 where a fresh lab buffer
  read 9.93, and calibrating `high` on them would have set a badly wrong
  alkaline slope.

**Mode.** Both functions run only in MANUAL.

- With automation enabled (the `automation` and `full` variants, and any
  installed `/opt/anolis/config/runtime.yaml` with `automation.enabled: true`):
  in Operate, set the mode to MANUAL. IDLE refuses every call, and so does
  AUTO under this project's `manual_gating_policy: BLOCK` ("Manual call blocked
  in AUTO mode"). The functions themselves also refuse any mode but MANUAL.
- With automation disabled (`manual`, `telemetry`) there is no mode manager and
  the runtime treats calls as MANUAL, so there is no mode step.

`install.sh` keeps an existing `runtime.yaml`, so check what is installed
rather than the variant you asked for: it says "`--variant ... NOT applied`"
when it kept one.

**Calibrate.** In Operate, open Devices, pick `ph0` or `do0`, then `calibrate`.

- pH: `mid` first, because calibrating the midpoint clears the low and high
  points. A full calibration is `mid`, then `low`, then `high`, each with the
  probe in that solution and `reference_ph` set to its printed value.
- DO: `atmospheric` alone is a valid single-point calibration. For two points,
  do `zero` (zero-oxygen solution) first, then `atmospheric`. In the zero
  solution the probe reads 0.0 as its floor, so its settling cannot be watched:
  give it a few minutes, then calibrate. `calibrate` runs at the default
  compensation (20 °C, salinity 0, 101.3 kPa), as the datasheet expects, then
  sends back the compensation set before (anolis-provider-ezo 0.6.0+).
- Compensation: in AUTO the tree sets both probes to `compensation_temp_c` on
  entering AUTO and whenever it changes, replacing any value set by hand in
  MANUAL.

**Check the result.**

- A rejected calibration fails the call with the device's error next to the
  form, for example "device rejected the command (response code 2, syntax
  error)". The probe's calibration is unchanged.
- `ph_calibration_level` (0 to 3) and `do_calibration_level` (0 to 2) show the
  points the probe now holds. After a pH `mid` it reads 1, after `low` 2, after
  `high` 3; after DO `atmospheric` alone, 1. If it reads unavailable, the
  provider could not read it back: the calibration may still have taken, so
  check the reading against the solution.
- Every call that reaches a provider is logged by the runtime.

**Clearing.** `clear_calibration` deletes every calibration point on the probe
in one click, with no confirmation (anolis-workbench#799). Use it only to start
over, and calibrate straight after.

**Finish.** Return the mode to where it was: IDLE, or AUTO to resume the
automation.

## Heater (rlht0)

rlht0 drives the heater pads through relay 1 (gen1 boards have one relay) and
reads two thermocouples: TC1 in the liquid (`t1_c`) and TC2 on the pad surface
(`t2_c`). Nothing in the runtime or the gen1 firmware limits temperature
beyond the loop's own setpoint (feastorg/Slice_RLHT#49). For an unattended
run, start `scripts/heater_guard.py` first; it is described at the end of this
section.

**Power.** Two 12 V / 20 W pads on an 8 L fill, measured on the reference rig
in November 2026:

| Wiring at 12 V | Current | Power | Result |
| --- | --- | --- | --- |
| Series | about 0.77 A | about 9 W | Liquid rose about 3 °C in 8 h, from room: too little to hold a culture temperature |
| Parallel | about 3 A | about 34 W | Liquid to about 41 °C at a 62 °C pad, stirred and aerated |

The supply must deliver the parallel current on top of the rest of the bus. An
undersized supply showed up as 2.6 A instead of 3 A.

**Control.** Close the loop on the pad, not the liquid. The pad setpoint
then caps the pad temperature, and an open pad thermocouple stops the heater.

In AUTO the behavior tree does this. On the operator panel, set the
**Heater** group's pad setpoint and turn it on. While it is on, the tree sends
the five settings below on entering AUTO, whenever the setpoint changes, and
again every `command_keepalive_s` (30 s), so a slice that lost power is set up
again within about 30 s. While it is off, the tree turns the heater off. The
heater's mode-transition behaviour:

- AUTO → MANUAL leaves the heater as the tree last set it, so a routine
  hand-off doesn't cool the culture;
- MANUAL → IDLE, FAULT and the software e-stop turn it off;
- Stop on the operator panel turns the heater setting off, as it does the
  motors.

After a hardware e-stop is released in AUTO, the heater comes back on with the
motors. `validation/check_heater.py` checks the tree and these hooks against
the mock providers.

In MANUAL, nothing re-sends the settings. Make these calls on rlht0, filling
every argument **by name**: Operate lists arguments alphabetically
(anolis-workbench#807), so entering them in order puts values in the wrong
boxes.

1. `set_periods_ms`: `period1_ms` 10000, `period2_ms` 10000. A 10 s window
   saves relay wear, and the liquid's response is hours, not seconds.
2. `set_tc_select`: `tc1_index` 2, `tc2_index` 1. `tc1_index` picks the
   thermocouple that **channel 1's** loop follows, so 2 means the pad. Channel
   2 has no relay on gen1. Don't send 2 / 2: firmware may come to refuse two
   channels on one thermocouple (feastorg/Slice_RLHT#52).
3. `set_pid_x10`: `kp1_x10` 255, `ki1_x10` 10, `kd1_x10` 0, and 0 for all
   three channel 2 gains.
4. `set_mode`: `closed_loop`.
5. `set_setpoints`: `setpoint1_c` = the pad setpoint, `setpoint2_c` 0.

**In MANUAL, after any power loss to the slices, send all five again.** That
covers a hardware e-stop, a supply change, or the Pi losing power. The slice
keeps them in RAM only, and boots with defaults: period 1000 ms, gains
1 / 0 / 0, each channel on its own thermocouple. Until the provider re-applies
them (anolis-provider-bread#220), check them by reading back `period1_ms` and
`mode`, and confirm the relay comes on. `set_tc_select` and the gains have no
readback yet (anolis-provider-bread#222). If the Pi boots before the slices
answer, rlht0 isn't registered at all: restart the runtime once the slices
are powered (anolis-provider-bread#168).

**Choosing the pad setpoint.** With the impeller running, the liquid settles
about 21 °C below the pad: a 62 °C pad gave about 41 °C liquid. For 37 °C
liquid, start near 58 °C and adjust from a reference thermometer. On 8 L it
takes several hours to settle. Keep the impeller on: unstirred, the vessel
stratifies by about 2 °C top to bottom, and the pad runs hotter for the same
heat delivered.

**Reading the liquid temperature.** On the reworked gen1 board, `t1_c` reads
about 1.2 °C high, measured between +0.9 and +1.5 °C against a mercury
thermometer under heater load. On an unreworked gen1 board it reads 2.5 °C
high or more, and higher still while the relay is on: the MAX6675's cold
junction is measured on a board warmer than the thermocouple terminals
(feastorg/Slice_RLHT#86). Check `t1_c` against a reference thermometer before
relying on it.

**Firmware.** Current Slice_RLHT firmware adds over-temperature, no-rise and
sensor faults. Its no-rise check needs about 1 °C/min at 90 % output or more,
and trips on this vessel in every configuration above
(feastorg/Slice_RLHT#88). Anolis can't read or clear those faults yet
(anolis-provider-bread#217). Don't update this rig's RLHT firmware until both
are resolved.

**The guard.** `scripts/heater_guard.py` polls rlht0 every 30 s and appends a
CSV row. It sends the software e-stop, whose safe-state hooks turn the heater
off, and confirms the latch, when:

- the pad goes over `--pad-max` (default 70 °C; use about setpoint + 15);
- the liquid goes over `--liquid-max` (default 45 °C);
- there is no good reading for 120 s;
- the pad reads below the liquid for 30 min, meaning its thermocouple is off
  the pad.

Run it under the runtime's environment, so it outlives your shell:

```bash
sudo systemd-run --unit=heater-guard \
  --property=EnvironmentFile=/etc/anolis/runtime.env \
  /usr/bin/python3 -u scripts/heater_guard.py ~/heater-run.csv --pad-max 70
# stop it after the run:
sudo systemctl stop heater-guard
```

It also stops when the slices lose power for 2 minutes: an e-stop, a supply
change, or rework. Restart it after.

## Automation parameter reference

All parameters are runtime-tunable over HTTP (`POST /v0/parameters` on the
runtime, directly or through the workbench and its `/v0` proxy) while running
the `automation` or `full` profile; there is no dedicated CLI for them.

| Parameter                   | Type  | Default | Description                           |
| --------------------------- | ----- | ------- | ------------------------------------- |
| `impeller_enable`           | bool  | false   | Enable impeller motor                 |
| `impeller_pwm`              | int64 | 100     | Impeller PWM (0–255); not maximal by design |
| `dose1_enable`              | bool  | false   | Enable dosing pump 1                  |
| `dose1_pwm`                 | int64 | 240     | Dose 1 PWM (0–255)                    |
| `dose1_startup_delay_s`     | int64 | 60      | Delay before first dose 1 pulse       |
| `dose1_interval_s`          | int64 | 900     | Interval between dose 1 pulses        |
| `dose1_pulse_s`             | int64 | 5       | Duration of dose 1 pulse; must be less than `dose1_interval_s` |
| `dose1_max_pulses_per_hour` | int64 | 0       | Rate cap for dose 1 (0 = unlimited)   |
| `dose2_enable`              | bool  | false   | Enable dosing pump 2                  |
| `dose2_pwm`                 | int64 | 240     | Dose 2 PWM (0–255)                    |
| `dose2_startup_delay_s`     | int64 | 60      | Delay before first dose 2 pulse       |
| `dose2_interval_s`          | int64 | 900     | Interval between dose 2 pulses        |
| `dose2_pulse_s`             | int64 | 5       | Duration of dose 2 pulse; must be less than `dose2_interval_s` |
| `dose2_max_pulses_per_hour` | int64 | 0       | Rate cap for dose 2 (0 = unlimited)   |
| `sample_enable`             | bool  | false   | Enable the sample pump's schedule     |
| `sample_pwm`                | int64 | 240     | Sample pump PWM (0–255)               |
| `sample_startup_delay_s`    | int64 | 60      | Delay before the first sample pulse   |
| `sample_interval_s`         | int64 | 900     | Interval between sample pulses        |
| `sample_pulse_s`            | int64 | 5       | Duration of a sample pulse; must be less than `sample_interval_s` |
| `sample_requests`           | int64 | 0       | "Sample now" counter: each increase runs one sample pulse |
| `sample_request_delay_s`    | int64 | 0       | Delay from a "Sample now" press to its pulse |
| `sample_request_pulse_s`    | int64 | 5       | Duration of a "Sample now" pulse      |
| `heater_enable`             | bool  | false   | Hold the heater at the pad setpoint; off turns the heater off (see "Heater") |
| `heater_pad_setpoint_c`     | double | 0.0    | Pad setpoint, 0–65 °C; 0 is off. The liquid settles well below it |
| `compensation_temp_c`       | double | 25.0   | Temperature the pH and DO probes compensate for, 0–100 °C; sent on entering AUTO and on change |
| `command_keepalive_s`       | int64 | 30      | Keepalive interval for motor and heater commands |
| `command_min_spacing_ms`    | int64 | 500     | Minimum spacing between commands      |

> **A dose or sample pulse must be shorter than its interval.** Each parameter
> is checked against its own range only, so `dose1_interval_s: 3` is accepted while
> `dose1_pulse_s` is 5. The tree then turns that dose channel off, whether or
> not it is enabled, and keeps writing the impeller and the other channel. The
> runtime stays in AUTO, and logs `[PeriodicPulseWindowNode] Invalid scheduling
> inputs` at ERROR every tick until the schedule is valid again
> (anolishq/anolis-projects#103). `validation/check_invalid_dose_schedule.py`
> checks this against a mock bread provider, and `validation/check_sampler.py`
> checks the sampler the same way (anolishq/anolis-projects#127).

> **"Sample now" runs the sample pump once per press**, beside the periodic
> schedule. The operator panel's button increases `sample_requests` by one; in
> AUTO the tree runs the pump at `sample_pwm`, `sample_request_delay_s` after
> the press, for `sample_request_pulse_s`. A press while a requested pulse is
> waiting or running adds nothing (`max_queued` 1). The panel refuses a press
> outside AUTO, since the tree reads presses only while it runs. The periodic and requested pulses share the pump: it runs
> while either is on and stops only when both are off, so neither cuts the
> other short. `sample_enable` switches only the periodic schedule. Start's
> sample-pump brake check applies while `sample_enable` is on, so with the
> periodic schedule off, check that brake by hand before pressing.
> `validation/check_sample_now.py` checks this against a mock bread provider.

> **Parameters are not persisted.** Every value above reverts to the default in
> this table whenever the runtime restarts — including across an upgrade. A
> setting you changed during a run is gone after a restart. At startup the
> runtime logs `[Runtime] Parameter '<name>' at config default <value>` for each
> parameter, and `GET /v0/parameters` reports `source: "default"` for every
> value not set since the restart. Re-apply anything you tuned before re-enabling
> actuation, and treat the defaults as what the machine will actually do the
> moment it comes back.
>
> The *current* value of every parameter, and whether it is a default or an
> operator value, is in `GET /v0/parameters`. While in AUTO, the behaviour tree
> also logs the six numeric parameters it reads with `GetParameter`
> (`impeller_pwm`, `dose1_pwm`, `dose2_pwm`, `sample_pwm`,
> `heater_pad_setpoint_c`, `compensation_temp_c`) on every tick; parameters read
> with `GetParameterBool` or `GetParameterInt64` are not logged:
>
> ```
> journalctl -u anolis-runtime -f | grep GetParameterNode
> # [GetParameterNode] Read parameter 'impeller_pwm' = 100
> ```
>
> At `tick_rate_hz: 2` that is twice a second. No `GetParameterNode` line is
> logged after a restart until an operator enters AUTO.

## DCMT channel map

| Device       | Channel | Assignment                                     |
| ------------ | ------- | ---------------------------------------------- |
| dcmt0 (0x14) | motor1  | Sample pump: `sample_*` schedule and "Sample now" in automation |
| dcmt0 (0x14) | motor2  | Impeller (stirring)                            |
| dcmt1 (0x15) | motor1  | Dosing pump 1                                  |
| dcmt1 (0x15) | motor2  | Dosing pump 2                                  |

# Bioreactor v1 — Runbook

## Hardware

| Slot   | Device | Type                                 | I²C address |
| ------ | ------ | ------------------------------------ | ----------- |
| bread0 | rlht0  | RLHT (relay heater + thermocouple temperature; TC1 only) | 0x13 |
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
| `command_keepalive_s`       | int64 | 30      | Keepalive interval for motor commands |
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
> also logs the four numeric parameters it reads with `GetParameter`
> (`impeller_pwm`, `dose1_pwm`, `dose2_pwm`, `sample_pwm`) on every tick; parameters read
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
| dcmt0 (0x14) | motor1  | Sample pump: `sample_*` schedule in automation |
| dcmt0 (0x14) | motor2  | Impeller (stirring)                            |
| dcmt1 (0x15) | motor1  | Dosing pump 1                                  |
| dcmt1 (0x15) | motor2  | Dosing pump 2                                  |

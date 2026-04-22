# Bioreactor v1 — Runbook

## Hardware

| Slot   | Device | Type                                 | I²C address |
| ------ | ------ | ------------------------------------ | ----------- |
| bread0 | rlht0  | RLHT (temp + humidity)               | 0x0A        |
| bread0 | dcmt0  | DCMT (sample pump ch1, impeller ch2) | 0x14        |
| bread0 | dcmt1  | DCMT (dose1 ch1, dose2 ch2)          | 0x15        |
| ezo0   | ph0    | Atlas EZO-pH                         | 0x63        |
| ezo0   | do0    | Atlas EZO-DO                         | 0x61        |

- **Bus**: Raspberry Pi `/dev/i2c-1`
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

- [anolis-provider-bread](../../../anolis-provider-bread/README.md)
- [anolis-provider-ezo](../../../anolis-provider-ezo/README.md)
- [anolis](../../../anolis/README.md)

Target preset for hardware: `dev-linux-hardware-release`

Expected binary paths (from inside `anolis/`):

```
../anolis-provider-bread/build/dev-linux-hardware-release/anolis-provider-bread
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

Edit `config/anolis-runtime.bioreactor.telemetry.yaml` to set your InfluxDB token,
then:

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

From the `anolis-workbench/` directory:

```sh
anolis-workbench session --system ../anolis-projects/projects/bioreactor-v1/workbench/system.json
```

## Automation parameter reference

All parameters are runtime-tunable via the workbench HTTP API or CLI after the
system is running in `automation` or `full` mode.

| Parameter                   | Type  | Default | Description                           |
| --------------------------- | ----- | ------- | ------------------------------------- |
| `impeller_enable`           | bool  | false   | Enable impeller motor                 |
| `impeller_pwm`              | int64 | 255     | Impeller PWM (0–255)                  |
| `dose1_enable`              | bool  | false   | Enable dosing pump 1                  |
| `dose1_pwm`                 | int64 | 240     | Dose 1 PWM (0–255)                    |
| `dose1_startup_delay_s`     | int64 | 60      | Delay before first dose 1 pulse       |
| `dose1_interval_s`          | int64 | 900     | Interval between dose 1 pulses        |
| `dose1_pulse_s`             | int64 | 5       | Duration of dose 1 pulse              |
| `dose1_max_pulses_per_hour` | int64 | 0       | Rate cap for dose 1 (0 = unlimited)   |
| `dose2_enable`              | bool  | false   | Enable dosing pump 2                  |
| `dose2_pwm`                 | int64 | 240     | Dose 2 PWM (0–255)                    |
| `dose2_startup_delay_s`     | int64 | 60      | Delay before first dose 2 pulse       |
| `dose2_interval_s`          | int64 | 900     | Interval between dose 2 pulses        |
| `dose2_pulse_s`             | int64 | 5       | Duration of dose 2 pulse              |
| `dose2_max_pulses_per_hour` | int64 | 0       | Rate cap for dose 2 (0 = unlimited)   |
| `command_keepalive_s`       | int64 | 30      | Keepalive interval for motor commands |
| `command_min_spacing_ms`    | int64 | 500     | Minimum spacing between commands      |

## DCMT channel map

| Device       | Channel | Assignment                                     |
| ------------ | ------- | ---------------------------------------------- |
| dcmt0 (0x14) | motor1  | Sample pump — **held at 0 in automation mode** |
| dcmt0 (0x14) | motor2  | Impeller (stirring)                            |
| dcmt1 (0x15) | motor1  | Dosing pump 1                                  |
| dcmt1 (0x15) | motor2  | Dosing pump 2                                  |

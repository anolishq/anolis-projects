# Bioreactor v1

Stirred bioreactor with dual dosing control, temperature monitoring, pH, and
dissolved oxygen sensing.

## Hardware topology

| Provider | Device | Role |
|---|---|---|
| bread0 (CRUMBS) | rlht0 (0x0A) | Temperature + humidity |
| bread0 (CRUMBS) | dcmt0 (0x14) | Sample pump (ch1), impeller/stirrer (ch2) |
| bread0 (CRUMBS) | dcmt1 (0x15) | Dosing pump 1 (ch1), dosing pump 2 (ch2) |
| ezo0 (EZO) | ph0 (0x63) | pH sensor |
| ezo0 (EZO) | do0 (0x61) | Dissolved oxygen sensor |

## Runtime variants

| Variant | Telemetry | Automation | Config file |
|---|---|---|---|
| manual | ✗ | ✗ | `config/anolis-runtime.bioreactor.manual.yaml` |
| telemetry | ✓ | ✗ | `config/anolis-runtime.bioreactor.telemetry.yaml` |
| automation | ✗ | ✓ | `config/anolis-runtime.bioreactor.automation.yaml` |
| full | ✓ | ✓ | `config/anolis-runtime.bioreactor.full.yaml` |

## Behavior tree

`behaviors/bioreactor_stir_dual_dosing.xml` — maintains impeller speed and runs
two independent periodic dosing schedules with configurable timing parameters.

## Quick start

See [docs/runbook.md](docs/runbook.md) for the full setup and launch sequence.

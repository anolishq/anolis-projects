# config-release/

Runtime configuration variants for **release binary installs**.

Use these configs when binaries are installed from GitHub Releases (pass 2 setup)
rather than built from source.

## Assumptions

- Binaries installed to `/usr/local/bin/` (standard release install prefix):
  ```
  /usr/local/bin/anolis-runtime
  /usr/local/bin/anolis-provider-bread
  /usr/local/bin/anolis-provider-ezo
  ```
- Runtime is launched **from the root of this repository**:
  ```bash
  cd ~/repos/anolis-projects
  anolis-runtime --config projects/bioreactor-v1/config-release/anolis-runtime.bioreactor.manual.yaml
  ```
  Provider config paths are relative to the launch directory.

## Files

| File | Description |
|---|---|
| `anolis-runtime.bioreactor.manual.yaml` | No telemetry, no automation |
| `anolis-runtime.bioreactor.telemetry.yaml` | Telemetry to InfluxDB, no automation |
| `anolis-runtime.bioreactor.full.yaml` | Telemetry + automation |
| `anolis-runtime.bioreactor.automation.yaml` | Automation + manual gating + telemetry |

The `provider-bread.bioreactor.yaml` and `provider-ezo.bioreactor.yaml` files
in `config/` are shared between source-build and release installs — they contain
no binary paths.

## Source-build configs

See `../config/` for the source-build variants that reference build-tree binaries.

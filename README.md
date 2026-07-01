# anolis-projects

Realization projects for the [anolis](https://github.com/anolishq/anolis) runtime platform.

Each subdirectory of `projects/` is an independent, self-contained application project: runtime config, provider configs, behavior trees, and workbench system descriptors for a specific physical deployment target.

## Projects

| Directory                                            | Description                                                          | Status |
| ---------------------------------------------------- | -------------------------------------------------------------------- | ------ |
| [`projects/bioreactor-v1/`](projects/bioreactor-v1/) | Stirred bioreactor with dual dosing, temperature, pH, and DO sensing | Active |

## Conventions

- **One directory per deployment target.** Each project owns its runtime YAML variants, provider YAML configs, behavior XML trees, and workbench `system.json`.
- **No generated artifacts committed.** `.anpkg` files are gitignored.
- **Schema lock CI.** Each project's `machine-profile.yaml` is validated against the local [`machine-profile.schema.json`](machine-profile.schema.json) (via `check-jsonschema`) on every push.
- **Provider binary paths.** Until Phase 5 (artifact-first provider resolution), runtime configs reference sibling-repo build outputs. See each project's `docs/runbook.md` for the full setup checklist.

## Deployment (systemd)

`systemd/` ships a **single** unit, `anolis-runtime.service`, which is installed and enabled
by `install.sh` and the bundle. This is deliberate: the runtime **spawns and supervises each
provider as a child subprocess** (via the `command`/`args` + `restart_policy` in the runtime
config, over the child's stdin/stdout). There is no connect-to-a-running-provider mode in the
runtime, so providers are **not** independent systemd services.

Do not add per-provider units. Running a provider as its own service alongside the runtime
double-spawns it and contends for the I2C bus. Provider children inherit the runtime unit's
`SupplementaryGroups=i2c gpio dialout` for hardware bus access, so one unit suffices.

## Getting Started

Clone this repo alongside the other anolis repos:

```
anolis/
anolis-projects/           ← this repo
anolis-provider-bread/
anolis-provider-ezo/
```

Follow the runbook in the project you want to deploy:

- [Bioreactor v1 runbook](projects/bioreactor-v1/docs/runbook.md)

## License

[MIT](LICENSE)

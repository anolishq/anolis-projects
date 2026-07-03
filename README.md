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
- **Schema CI.** Each project's `machine-profile.yaml` is validated against the **canonical** machine-profile schema (published with every [anolis](https://github.com/anolishq/anolis) release; this repo pins the release in [`schema-source.json`](schema-source.json), Renovate bumps it) on every push.
- **Provider binary paths.** Until Phase 5 (artifact-first provider resolution), runtime configs reference sibling-repo build outputs. See each project's `docs/runbook.md` for the full setup checklist.

## Deployment

This repo holds **only** deployment descriptors (examples/config). Building and
installing a deployment is handled by `install.sh` in the
[anolis](https://github.com/anolishq/anolis) repo — an online install driven by a
config, or `install.sh --stage` to build an offline bundle locally. No packaging
machinery (bundle CI, systemd units, config rendering) lives here.

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

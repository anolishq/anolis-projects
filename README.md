# anolis-projects

Realization projects for the [anolis](https://github.com/anolishq/anolis) runtime platform.

Each subdirectory of `projects/` is an independent, self-contained application project: a `machine-profile.yaml`, runtime configs, provider configs, and (where the project uses them) behavior trees for a specific physical deployment target.

## Projects

| Directory                                            | Description                                                          | Status |
| ---------------------------------------------------- | -------------------------------------------------------------------- | ------ |
| [`projects/bioreactor-v1/`](projects/bioreactor-v1/) | Stirred bioreactor with dual dosing, temperature, pH, and DO sensing | Active |
| [`projects/mixed-bus-dev/`](projects/mixed-bus-dev/) | `bread0` + `ezo0` shared-I2C development and validation profile      | Dev    |

## Conventions

- **One directory per deployment target.** Each project owns its runtime YAML variants and provider YAML configs, plus behavior XML trees where it uses them. `install.sh --project <dir>` reads a project's `machine-profile.yaml` (which must have a `components:` block), `config/` and `behaviors/`; the workbench imports a project's `machine-profile.yaml`, `config/`, `behaviors/` and any other top-level directory the profile references, verbatim.
- **No generated artifacts committed.** `.anpkg` files are gitignored.
- **Schema CI.** Each project's `machine-profile.yaml` is validated against the **canonical** machine-profile schema (published with every [anolis](https://github.com/anolishq/anolis) release; this repo pins the release in [`schema-source.json`](schema-source.json), Renovate bumps it) on every push to `main` and every pull request targeting `main`.
- **Provider binary paths.** Runtime configs under `config/` reference sibling-repo build outputs; for a project that pins `components:` (bioreactor-v1), `install.sh` fetches the provider binaries pinned in `machine-profile.yaml` and rewrites those paths. See each project's `README.md` (and, for bioreactor-v1, `docs/runbook.md`) for setup steps.

## Deployment

This repo holds deployment descriptors (examples/config) plus a few per-project helper scripts (host prep, workbench bootstrap, HTTP validation). Building and
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

[AGPL-3.0](LICENSE)

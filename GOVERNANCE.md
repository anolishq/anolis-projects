# Governance

## Project model

`anolis-projects` is the **realization layer** of the anolis platform. It holds the
machine-specific configuration that wires a physical deployment together:

- Runtime YAML variant (manual, telemetry, automation, full)
- Per-provider device YAML (bread, ezo, …)
- Machine profile (`machine-profile.yaml`) — the single source of truth for the
  deployment's identity, topology, and contract declarations
- Behavior trees (XML) that implement automation logic
- Workbench `system.json` used by `anolis-workbench` to spawn a local system session

Platform-generic fixtures (`demo.xml`, test harnesses, shared schemas) live in
`anolis` or `anolis-workbench` and are **not** copied here.

## Ownership convention

| Layer                               | Owner repo                                        |
| ----------------------------------- | ------------------------------------------------- |
| Runtime binary + scheduling engine  | `anolis`                                          |
| Provider binaries                   | `anolis-provider-bread`, `anolis-provider-ezo`, … |
| Protocol definitions                | `anolis-protocol`                                 |
| Schemas                             | `anolis` (published via `anolishq.github.io`)     |
| Machine-specific config + behaviors | **`anolis-projects`** (this repo)                 |
| Workbench application               | `anolis-workbench`                                |

## Adding a new project

1. Create `projects/<name>/` with at minimum:
   - `machine-profile.yaml`
   - At least one runtime YAML variant
   - One provider YAML per provider in the machine profile
   - `docs/runbook.md` — hardware setup, build instructions, launch sequence
2. If the project uses automation, add the behavior tree under `behaviors/`.
3. Add the project to the top-level `README.md` table.
4. CI will automatically validate `machine-profile.yaml` schema conformance.

## Generated artifact policy

`.anpkg` files are the output of `anolis-workbench pack`. They are:

- Generated, not authored
- Derived from the configs in this repo + provider binaries from their repos
- **Never committed** — they belong in a release artifact store (GitHub Releases,
  an S3 bucket, or equivalent)

The `.gitignore` enforces this at the repo level. CI validates that no `.anpkg`
files are staged.

## CI requirements

Every project directory must pass:

1. **YAML parse check** — all `.yaml` files in the project tree are valid YAML.
2. **machine-profile.yaml existence** — every project must have a `machine-profile.yaml`.
3. **Behavior tree reference check** — every behavior tree path listed in
   `machine-profile.yaml` must exist within the project directory.
4. **No generated artifacts** — no `.anpkg` files may be present.

Full schema validation against the published anolis machine-profile schema is a
Phase 2+ CI addition once the schema publication URL stabilizes.

## Provider binary path convention (pre-Phase-5)

Until artifact-first provider binary resolution is implemented (Phase 5), runtime
YAML configs reference provider binaries via sibling repo relative paths:

```
../anolis-provider-bread/build/dev-linux-hardware-release/anolis-provider-bread
```

This requires the anolis ecosystem repos to be cloned as siblings under a shared
parent directory. See each project's `docs/runbook.md` for the full sibling layout.
Phase 5 will replace these paths with versioned artifact resolution.

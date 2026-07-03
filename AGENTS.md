# AGENTS.md — anolis-projects

> Per-repo conventions for coding agents. The canonical cross-repo rules
> (Conventional Commits, minimal-first/YAGNI, no secrets, run checks before
> claiming success) live in the user's **global** `AGENTS.md` and are not
> repeated here. This file records only what is specific to this repo.

## Build / test

- **No compiled code.** CI installs `pyyaml` + `check-jsonschema` and validates
  every `projects/<name>/machine-profile.yaml` against the local
  `machine-profile.schema.json`. Run locally:
  `check-jsonschema --schemafile machine-profile.schema.json projects/*/machine-profile.yaml`.
- The required CI status check is the **`ok`** job; never merge red.

## Tooling

- Config/descriptor repo only — no language toolchain.

## Repo-specific gotchas

- **`projects/<name>/machine-profile.yaml` is the source of truth.** Each
  project directory MUST contain one; CI fails if missing or schema-invalid.
- Its exact shape is load-bearing beyond schema validation: the Renovate
  **regex customManager** bumps component versions pinned inside
  `machine-profile.yaml`, and `install.sh` (in the anolis repo) reads it to
  build/install a deployment. Don't rename keys/paths casually.
- **Behavior trees are XML** (`projects/*/behaviors/*.xml`); **configs are YAML**
  (`projects/*/config/*.yaml`). Keep the formats as-is.

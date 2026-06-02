# Repo Map — media-pipeline

> Inventory for company-os onboarding (#36). Non-destructive: records what exists.

## Layout

| Path | What |
|---|---|
| `lib/` | Flutter desktop app (drives the pipeline; dry-run-first UX) |
| `scripts/` | Bash + Python pipeline steps `00`–`12` (ingest → metadata → dedup → Immich load); `06_delete_duplicates.sh` (high-risk), `11_restore_from_trash.sh` (reversal path) |
| `immich/` | Immich Docker compose + `env.template` |
| `tests/`, `test/` | Python + Dart tests |
| `config/` | Configuration |
| `docs/` | HISTORY, CONTRIBUTING_GUIDE, IMMICH_* (external library, settings, dedup), MEMORY_* (curator/preview/adapter), app plans, PRIVATE_BETA_CHECKLIST |
| `linux/`, `macos/`, `windows/`, `build/` | Flutter desktop targets |
| `pubspec.yaml`, `analysis_options.yaml` | Flutter/Dart config |

## Stack & tooling

Dart/Flutter + Bash + Python (ruff-linted). Immich/Docker, rclone, exiftool, czkawka. Default branch: **`main`**.

## CI / hooks / config (preserve — do not alter without a work order)

`.github/workflows/`: `ci.yml`, `gitleaks.yml`, `pr-review.yml` (Cody), `release.yml`, `add-to-project.yml`. Plus `.pre-commit-config.yaml`, `.githooks/`, `.gitleaks.toml`, `.markdownlint-cli2.jsonc`, `.yamllint`, `.codex/`, `.agents/`.

## Environments & secrets (names only — never read/commit values)

`.env` (gitignored); `immich/env.template` is the committed template pattern. No secrets in source.

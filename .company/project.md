# Project — media-pipeline

> company-os-governed context. Canonical registry: company-os `projects.yaml`.

## What this repo is

A personal-media pipeline: a **Flutter desktop app** (`lib/`) driving **Bash + Python pipeline scripts** (`scripts/00`–`12`) that ingest Google Takeout / Drive media, stitch metadata (`exiftool`), de-duplicate (`czkawka`), and load into **Immich**. It moves large numbers of **real personal files** — **data-loss prevention is the first priority.**

## Stack

Dart/Flutter (desktop app) · Bash (pipeline scripts) · Python (metadata + tests, linted with `ruff`). Immich (Docker compose under `immich/`), rclone, exiftool, czkawka. **Not a Python package — no uv/build migration.**

## Owners (from `projects.yaml`)

Owner: Manu · Architecture: Otto · Technical lead: Sofie · Code review: Cody · Arch review: Astrid · QA: Theo · Controller: Conrad. **All releases require Leo approval.**

## Read first

`CLAUDE.md` (canonical), `GEMINI.md`, `AGENTS.md`, `docs/` (HISTORY, IMMICH_*, app plans), `README.md`, and `.company/{repo-map,test-commands,forbidden-actions,domain-context}.md`.

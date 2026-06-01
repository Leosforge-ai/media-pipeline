# CLAUDE.md — media-pipeline

> Conventions for Claude Code here. Follows company reusable-standards (company-os
> `standards/` + `templates/reusable-standards/`). Kept in sync with `GEMINI.md` and `AGENTS.md`.

## What This Repo Is

A personal-media pipeline: a **Flutter desktop app** (`lib/`) driving **Bash + Python pipeline
scripts** (`scripts/00`–`12`) that ingest Google Takeout / Drive media, stitch metadata
(`exiftool`), de-duplicate (`czkawka`), and load into **Immich**. It moves large numbers of
real personal files — **data-loss prevention is the first priority.**

## Stack

- Dart/Flutter (app), Bash (pipeline), Python (metadata + tests; linted with `ruff`).
- Immich (Docker compose under `immich/`), rclone, exiftool, czkawka.
- Not a Python package — **no uv/build migration**; Python here is scripts + tests.

---

## Safety Rules (highest priority — ported from prior review policy)

- **Dry-run first.** Destructive steps default to dry-run and require an explicit confirmation gate.
- **Never delete permanently.** Move files to `media_trash`, never `rm`. `11_restore_from_trash.sh` must remain a working reversal path.
- **`scripts/06_delete_duplicates.sh` is high-risk:** parse only real, absolute, quoted Czkawka paths — never treat report headers, dimensions, or sizes as file paths.
- **Immich storage separation:** Immich upload storage (`/data`) stays separate from the external library (`/library`); the external library is mounted **read-only** unless a documented user choice says otherwise.
- Preserve paths with spaces / non-English characters everywhere.

## Hard Rules

### Shell (`scripts/**/*.sh`)
- `set -euo pipefail`; quote all variable expansions; no destructive command without a confirmation gate.

### Python (`scripts/**/*.py`)
- Continue past individual corrupt media files where safe; log warnings clearly; don't load huge media into memory; preserve metadata behavior.

### Dart (`lib/**`)
- Preserve the dry-run-first workflow; never construct confirm commands implicitly; keep process output visible; never store secrets or personal paths in tracked files.

### Always
- Never commit secrets (`immich/env.template` is the pattern; real `.env` is ignored). Pin GitHub Actions to a commit SHA.
- Follow `docs/WRITING_STANDARDS.md`; update `docs/HISTORY.md` on pipeline/safety changes.
- No committed stubs; no self-merge; CI green before review.

---

## GitHub Issue Completion Protocol

Tied to an issue: save outputs → branch `<type>/<slug>` (never `main`) → commit
`type(scope): <what> — closes #N` → `gh pr create` (`Closes #N`, then What/Why/Test evidence) →
comment on the issue. Skip for exploratory chats and secret ops.

## Automated PR Review

`.github/workflows/pr-review.yml` runs **Cody** (correctness/security + the safety rules above);
CRITICAL/HIGH/MEDIUM request changes. Replaces CodeRabbit. (No Dalton — no SQL/data layer.)

## Reasoning Protocol

Lenses before non-trivial work: **Manu** (assumptions/scope/risk), **Cody** (security + data-loss/destructive-op safety), **Astrid** (architecture). Treat any change touching destructive scripts, Immich config, or file parsing as high-risk.

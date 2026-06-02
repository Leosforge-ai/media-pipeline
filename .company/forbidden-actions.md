# Forbidden Actions — media-pipeline

> Project guardrails, additional to company-os policies. Cannot be overridden at execution time.
> Owner: Manu/Otto · Reviewer: Conrad. **Data-loss prevention is the first priority.**

## Never (data safety — non-negotiable)

- Delete files permanently. Move to `media_trash`, **never `rm`**; keep `11_restore_from_trash.sh` working as the reversal path.
- Run destructive steps without a **dry-run default + explicit confirmation gate**.
- In `scripts/06_delete_duplicates.sh`, treat report headers/dimensions/sizes as file paths — parse only real, absolute, quoted Czkawka paths.
- Mix Immich upload storage (`/data`) with the external library (`/library`); the external library stays **read-only** unless a documented user choice says otherwise.
- Break preservation of paths with spaces / non-English characters.

## Never (general)

- Commit secrets (`immich/env.template` is the pattern; real `.env` ignored); store personal paths in tracked files.
- Shell without `set -euo pipefail` / unquoted expansions / implicit confirm commands.
- Pin-less GitHub Actions; committed stubs; self-merge; push to `main`; release without **Leo approval**.

## Always

- Python: continue past individual corrupt media where safe, log clearly, don't load huge media into memory, preserve metadata behavior.
- Dart: keep dry-run-first; never construct confirm commands implicitly; keep process output visible.
- Follow `docs/WRITING_STANDARDS.md`; update `docs/HISTORY.md` on pipeline/safety changes.

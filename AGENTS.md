# AGENTS.md — media-pipeline (Codex)

> Kept in sync with `CLAUDE.md` (canonical) and `GEMINI.md`. Product-repo convention:
> `AGENTS.md` is Codex's instruction file. The company roster lives in company-os `AGENTS.md`.

## What This Repo Is
Personal-media pipeline: Flutter desktop app + Bash/Python scripts (Takeout/Drive → metadata →
de-dupe → Immich). Moves real personal files — **data-loss prevention is the first priority.**

## Safety Rules (highest priority)
- Dry-run first; destructive steps need an explicit confirmation gate.
- Never delete permanently — move to `media_trash`, never `rm`; keep `11_restore_from_trash.sh` working.
- `scripts/06_delete_duplicates.sh`: parse only real, absolute, quoted Czkawka paths; never treat headers/dimensions/sizes as paths.
- Immich `/data` (upload) stays separate from `/library` (external, read-only unless documented).
- Preserve paths with spaces / non-English characters.

## Hard Rules
- Shell: `set -euo pipefail`, quote expansions, no destructive command without a gate.
- Python: tolerate corrupt media where safe, log warnings, no huge in-memory loads, preserve metadata.
- Dart: dry-run-first, no implicit confirm commands, output visible, no tracked secrets/personal paths.
- Never commit secrets; pin GitHub Actions to commit SHAs. No committed stubs; no self-merge.
- Follow `docs/WRITING_STANDARDS.md`; update `docs/HISTORY.md` on pipeline/safety changes.

## GitHub Issue Completion Protocol
Save outputs → branch `<type>/<slug>` (never `main`) → commit `type(scope): <what> — closes #N` → `gh pr create` (`Closes #N`, then What/Why/Test evidence) → comment on the issue. Skip for exploratory and secret ops.

## Automated PR Review
`pr-review.yml` runs Cody (correctness/security + safety rules); CRITICAL/HIGH/MEDIUM request changes. Replaces CodeRabbit. No Dalton (no data layer).

## Reasoning Protocol
Lenses: **Manu** (assumptions/scope/risk), **Cody** (security + data-loss safety), **Astrid** (architecture). Destructive-script / Immich / parsing changes are high-risk.

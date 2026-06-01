# GEMINI.md — media-pipeline (Gemini CLI)

> Kept in sync with `CLAUDE.md` (canonical) and `AGENTS.md`. Gemini operating rules:
> company-os `integrations/gemini-cli.md` + `THE_WAY.md`.

## What This Repo Is
Personal-media pipeline: Flutter desktop app driving Bash + Python scripts (Takeout/Drive →
metadata stitch → de-dupe → Immich). Moves real personal files — **data-loss prevention first.**

## Gemini CLI operating rules (read-only research)
- Context-anchor → grep-first → surgical reads. Research only — no code changes/commits/PRs.

## Safety Rules (highest priority)
- Dry-run first; explicit confirmation gate for destructive steps.
- Never `rm` — move to `media_trash`; keep `11_restore_from_trash.sh` working.
- `06_delete_duplicates.sh`: parse only real, absolute, quoted Czkawka paths.
- Immich `/data` (upload) separate from `/library` (external, read-only by default).
- Preserve paths with spaces / non-English characters.

## Hard Rules
- Shell: `set -euo pipefail`, quote expansions, no destructive command without a gate.
- Python: tolerate corrupt media where safe, log warnings, no huge in-memory loads, preserve metadata.
- Dart: dry-run-first, no implicit confirm commands, output visible, no secrets/personal paths tracked.
- Never commit secrets; pin actions to SHAs. Follow `docs/WRITING_STANDARDS.md`; update `docs/HISTORY.md`.

## GitHub Issue Completion Protocol
Save → branch `<type>/<slug>` → commit `— closes #N` → `gh pr create` (`Closes #N`) → comment. Skip for exploratory/secret work.

## Automated PR Review
`pr-review.yml` runs Cody (correctness/security + safety rules); CRITICAL/HIGH/MEDIUM request changes. Replaces CodeRabbit. No Dalton.

## Reasoning Protocol
Lenses: **Manu** (assumptions/scope/risk), **Cody** (security + data-loss safety), **Astrid** (architecture). Destructive-script / Immich / parsing changes are high-risk.

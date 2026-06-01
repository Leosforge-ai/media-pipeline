# Project History — media-pipeline

> Factual record of phases, decisions, and pivots. Newest at the bottom.
> Follows company-os `standards/history-standards.md`. Safety-affecting changes
> (destructive scripts, Immich config, parsing) should always get an entry.

## Phase 0 — Pipeline + desktop app bootstrap (pre-2026-06-01)

**Context:** Ingest personal media (Google Takeout/Drive) and load it into Immich, safely.
**Decisions:** Bash + Python pipeline (`scripts/00`–`12`) for system checks, metadata stitching
(`exiftool`), de-duplication (`czkawka` → move to `media_trash`, never delete), and Immich loading;
a Flutter desktop app to drive it dry-run-first. Strong CI (shellcheck, shfmt, ruff, pytest,
flutter analyze/test/build, actionlint) and safety review rules.
**Pivots:** None recorded.
**Outcome:** Working, safety-first media pipeline with a desktop driver.

## Phase 1 — Company standards adoption (2026-06-01)

**Context:** Adopt company reusable-standards (company-os #13, Phase 3).
**Decisions:** Add AI-instruction files (CLAUDE/GEMINI/AGENTS) carrying the ported safety policy
(dry-run-first, never-delete, Immich storage separation); writing/history standards; pre-commit
(shellcheck/markdownlint/gitleaks/ruff/commit-msg); gitleaks CLI; pin CI actions to SHAs; replace
CodeRabbit with an in-house **Cody** PR review (no Dalton — no data layer). Not a Python package,
so no uv migration.
**Pivots:** Review tooling — CodeRabbit → company pr-review (safety rules ported, not lost).
**Outcome:** Repo aligned with company-os standards; safety model preserved.

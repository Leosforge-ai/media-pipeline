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

## Phase 2 — company-os onboarding (2026-06-02)

**Context:** Formally bring the repository under company-os governance.
**Decisions:** Added `.company/` project context and aligned repo with company-wide operating standards.
**Outcome:** Repo is officially registered and governed by company-os.

## Phase 3 — Guided pipeline run (2026-07-12)

**Context:** Manually kicking off and reviewing ~7 separate steps for a single "clean and
import" run was the top pipeline-usability complaint (#48). Every step, including the fully
safe ones (system check, metadata stitching, duplicate scan, dry-run report, cleanup
verification, Immich sync), required its own manual trigger.
**Decisions:** Added a "guided run" consolidated mode alongside the existing per-step manual
mode (not replacing it). `pipeline_models.dart` defines `guidedRunStepIds` (the chain: system
check → metadata stitch → duplicate scan → dedup dry-run → cleanup verify → Immich sync) and
`guidedRunCheckpointStepIds` (`delete-dry-run`, `sync-immich`), with
`buildGuidedRunSteps()`/`buildGuidedRunSegments()` resolving and
segmenting the chain — throwing if a confirm-gated step is ever included, as defense in
depth; `media_pipeline_app.dart` calls `buildGuidedRunSteps()` (not just
`buildGuidedRunSegments()`) so that check runs live in the app, not only in tests.
Interactive/privileged one-time setup steps (`setup-dependencies`: `sudo` calls;
`configure-rclone`: interactive `rclone config` wizard on stdin/stdout, which
`PipelineRunner.run()` can't service since it closes child stdin whenever a step has no
`stdinText`) are excluded from the automatic chain for the same reason `setup-immich` /
`verify-immich` already were — they stay manual-only. `pipeline_runner.dart` adds
`GuidedRunController`, which runs one segment at a time,
stops immediately on any step failure, and refuses to execute a `PipelineRisk.confirmRequired`
step under any circumstance. The guided run therefore always stops before
`06_delete_duplicates.sh --confirm` and before an Immich rescan — those remain explicit,
separate, human-triggered actions via the unchanged manual step list. The Flutter UI adds a
"Guided Run" control card ahead of the per-step list, sharing the same `StepRunState`/log
plumbing as manual runs.
**Pivots:** None — the two real decision points named in #48 map directly onto
`guidedRunCheckpointStepIds`, so no design change was needed mid-implementation.
**Outcome:** Guided run reduces a full clean-and-import pass to two manual checkpoints
(dedup delete confirmation, Immich rescan trigger) instead of ~7 separate manual triggers,
while the confirm-gate safety invariant (`PipelineRisk.confirmRequired` steps always require
a separate explicit human action) is unchanged and covered by new automated tests.

## Phase 4 — Thumbnail-diff dedup review before confirm (2026-07-12)

**Context:** `06_delete_duplicates.sh`'s dry-run output is Czkawka text; trusting it before
`--confirm` meant manually grepping `Keep:`/`Would trash:` lines (#49). The repo owner was not
fully confident Czkawka's similarity grouping was trustworthy enough to act on from text alone.
**Decisions:** Added `lib/src/duplicate_report.dart`, a read-only, display-only parser that
reads back the exact `Keep: <path>` / `Would trash: <path>` announcement lines
`06_delete_duplicates.sh`'s own `process_czkawka_report`/`score_keep_path` logic already prints
to stdout in dry-run mode — never the raw Czkawka report files, and never re-deriving which
file would be kept. Any other line (the SAFETY NOTICE banner, `DRY RUN MODE`/`CONFIRM MODE`,
`==> Processing duplicate report: ...`, Czkawka `Found ...` headers, dimension/size lines,
`Missing, skipping: ...`, `Refusing outside staging: ...`, non-absolute paths) is never matched
and never treated as a path, per the existing `06_delete_duplicates.sh` parsing safety rule.
Large duplicate sets are sampled to at most 20 pairs with a fixed seed (reproducible across
reviews of the same output) and the dialog always shows an honest "Showing N of M pairs" count
— nothing is silently truncated. `media_pipeline_app.dart` renders the sampled pairs
side-by-side via `Image.file` for still-image formats, falling back to a file icon + filename
for video/unsupported formats or any image that fails to load (no video-thumbnail-generation
dependency was added).

The review is wired as an **additional, additive** condition on the existing `delete-confirm`
gate, never a replacement for it: `PipelineStep` gained `requiresDuplicateThumbnailReview`
(true only for `delete-confirm`), and `canRunStep()` now also requires an explicit
`duplicateThumbnailReviewAcknowledged: true` — defaulting to `false`, so the gate fails closed
for any caller that doesn't pass it. The app tracks this in `_dedupReviewAcknowledged`, set
when the review dialog is opened and reset to `false` whenever `delete-dry-run` starts running
again (manually or via the guided run), since a fresh dry run can produce a different duplicate
set. `restore-confirm` is unaffected.
**Pivots:** None — parsing the script's own dry-run stdout (already captured in the app's
`StepRunState.log`) instead of re-reading/re-parsing Czkawka report files from `REPORT_DIR` was
chosen deliberately: it guarantees the review always matches exactly what the dry-run step just
produced, and avoids re-implementing `06_delete_duplicates.sh`'s `score_keep_path` keep-scoring
heuristic in Dart (which would risk silent drift from the bash logic that actually decides what
moves).
**Outcome:** `06_delete_duplicates.sh` and its Czkawka-report parsing are unchanged. The
confirm-gate safety invariant is strictly strengthened, not weakened: `delete-confirm` now
requires both the dry-run succeeding and the thumbnail review having been shown, proven by a
dedicated test group in `test/pipeline_models_test.dart`, a real-script assertion in
`test/app_driven_simulation_test.dart`, and an end-to-end widget test
(`test/dedup_review_widget_test.dart`) using a fake `PipelineRunner` seam
(`MediaPipelineApp.runner`) that proves the confirm button stays disabled until the review
dialog is opened, and that re-running the dry-run invalidates a prior acknowledgment.

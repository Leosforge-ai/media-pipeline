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

## Phase 5 — First-time drive/Immich setup detection (2026-07-12)

**Context:** Getting from "drive shows up in `lsblk` with no mountpoint" to "Immich running"
was fully manual (#55): identify filesystem with `blkid`, reason about which mount driver to
use (ext4 vs `ntfs-3g` vs `exfat`), mount, verify contents, optionally persist via
`/etc/fstab`, then chain into `09_setup_immich.sh`. This was the same class of pre-mount
friction Phase 3's guided run already reduced for the post-mount pipeline.
**Decisions:** Added `scripts/00b_first_time_drive_setup.sh`, a new numbered script (not a
Flutter app change) that: (1) detects unmounted candidate partitions via `lsblk`/`blkid`,
filtered to >500GB (override via `SIZE_THRESHOLD_BYTES`) and excluding whatever disk backs `/`
(resolved via `findmnt / -no SOURCE` + `lsblk -no PKNAME`, so the boot disk can never be
misidentified as a candidate); (2) prints, but never silently runs, the exact
package-install/mount commands for the detected filesystem type (ext4/ext3/ext2 need no extra
package; `ntfs` needs `ntfs-3g`; `exfat` needs `exfatprogs`) — running them requires an
explicit interactive `y/n`; (3) offers an idempotent `/etc/fstab` append (checked via
`UUID=...` grep, `nofail` in the entry so a missing drive doesn't hang boot) behind its own
`y/n`, overridable via `FSTAB_PATH` for testing; (4) verifies the mounted path is writable and
that `immich_library/` (if present) is actually a directory before suggesting
`09_setup_immich.sh` — printing a warning and stopping otherwise, never auto-chaining. All
detection logic (filesystem→mount-command mapping, boot-disk exclusion filter, fstab
idempotency, structure verification) is factored into small functions guarded by a
`BASH_SOURCE`/`$0` check so the script can be sourced by tests without running `main()`.
**Pivots:** None — followed the print-don't-execute constraint from #55 as designed, so per
the issue's own risk note this only needed Cody review, not Astrid.
**Outcome:** `tests/test_first_time_drive_setup.py` adds 18 tests: pure-logic coverage of the
fs-type→command mapping and boot-disk-exclusion filter (fed canned `lsblk -P` text, including a
regression guard for a large unmounted partition that sits on the boot disk itself), idempotent
fstab-append against a temp file (never `/etc/fstab`), pipeline-structure verification, and two
full end-to-end runs of the script with `lsblk`/`blkid`/`findmnt` stubbed on `PATH` proving
quit/decline paths make zero filesystem changes. shellcheck/shfmt clean.

## Phase 6 — First-time drive setup: real-machine fixes (2026-07-12)

**Context:** The repo owner ran the just-merged `scripts/00b_first_time_drive_setup.sh`
(Phase 5) against a real machine and hit two bugs (#57). Bug 1: unprivileged `blkid -o value
-s TYPE` returned nothing for a real, valid ext4 partition even though `sudo blkid` correctly
reported it, so the script showed `filesystem=unknown` and aborted when the partition was
selected — unusable without a manual `sudo blkid` workaround. Bug 2: `root_boot_disk()`
printed malformed, duplicated multi-line output (`"==> Boot/root disk detected as: \n
nvme0n1\nnvme0n1 (always excluded from candidates)"` instead of a single clean line) — a
fragility risk on the script's top safety property (boot-disk exclusion), even though
exclusion still worked correctly in the reported case.
**Root causes:** Bug 1 — `blkid` needs root to reliably probe raw block devices for
filesystem type on at least some systems, and the script only ever tried the unprivileged
path. Bug 2 — `disk_name_from_partition()`'s parent-chain walk (added by the Phase 5 LVM/btrfs
fix) called `lsblk -no TYPE`/`-no PKNAME` on a device path without `-d`/`--nodeps`; for a
whole-disk device with children (e.g. `/dev/nvme0n1` with partitions), lsblk without `-d`
returns one line per child in addition to the disk's own line, and that multi-line string was
then treated as a single value by a `[[ "$type" == "disk" ]]` compare and a
`current="/dev/$pk"` concatenation — corrupting later loop iterations and the function's own
final stdout.
**Decisions:** Bug 2 fix landed first as the more foundational safety-property fix: added
`-d`/`--nodeps` to both `lsblk` calls in `disk_name_from_partition()` so each query is always
scoped to exactly one device, plus a defensive first-line truncation as a second layer. Bug 1
fix: added `detect_fstype()`, a shared helper (replacing the single duplicated `blkid` call
site that fed both the candidate-listing display and the cached mount-command-building path)
that tries `lsblk -no FSTYPE` first (sysfs/udev metadata, typically world-readable, no root
needed) and only falls back to `sudo blkid` if lsblk has no answer — printing a clear heads-up
before the sudo prompt can appear so it's never a surprise mid-run. The `sudo blkid` fallback
is a read-only detection query, not a mount/fstab/install action, so it remains exempt from
the print-don't-execute rule, consistent with the fix direction in #57.
**Pivots:** None — both fixes stayed within the read-only-detection / print-don't-execute
boundary established in Phase 5; no change to the confirmation-gated mount/fstab actions.
**Outcome:** `tests/test_first_time_drive_setup.py` grows from 18 to 39 tests. New coverage:
three regression tests for `root_boot_disk()`'s single-line-output guarantee across the
simple-partition, LVM-chain, and btrfs-subvolume scenarios (stubbing `lsblk` to reproduce the
exact multi-line pollution that occurs when `-d` is dropped, proving the fix); three tests for
`detect_fstype()` (lsblk success never invokes `sudo blkid`; the sudo-blkid fallback fires and
announces itself only when lsblk is empty; neither method finding an answer returns empty);
and the existing full-script end-to-end tests updated to stub `sudo`/`lsblk -no FSTYPE` so they
exercise the same fallback path. shellcheck/shfmt clean.

## Phase 6 — Live Photo still+video dedupe (2026-07-12)

**Context:** Google Takeout exports Apple Live Photos as two separate files with matching
basenames — a still and a short (1-3s) motion clip. Immich imports them as two disconnected
timeline assets instead of one Live Photo; this isn't caught by Immich's own CLIP-based
duplicate review (a still and its motion clip aren't necessarily visually similar), and it's a
different, structural problem from the localized `Fotos de YYYY` duplicates `12` already
handles (#60).
**Decisions:** Added `scripts/13_dedupe_live_photos.sh`, following `12`'s exact UX pattern
(dry-run default, typed `--confirm` phrase gate). A still and video are only paired when they
share a directory and basename, and the video's duration is verified via `ffprobe` (`<=5s`,
chosen with margin above Apple's ~3s Live Photo capture window and the 1-3s clips this repo's
own Takeout exports produced) — falling back to file-mtime proximity (`<=5s` apart) only when
`ffprobe` can't report a duration at all (corrupt file/missing metadata), never as a substitute
for a known-too-long duration. `ffprobe` is invoked via an overridable `$FFPROBE_BIN` so the
test suite can inject a stub instead of depending on a real `ffprobe` binary or real encoded
media on the test runner. Scans `$IMMICH_LIBRARY` by default (cleanup is typically discovered
post-import); `LIVE_PHOTO_SCAN_DIR` overrides to `$CLEANING_STAGING` for a pre-sync run.
Explicitly does not attempt to re-link the pair as a single Immich Live Photo asset (e.g.
`QuickTime:ContentIdentifier`) — out of scope per #60, the still stays a plain photo.
**Pivots:** Trash layout — the issue suggested reusing `12`'s timestamped `TRASH_BATCH`
subdirectory under `$MEDIA_TRASH`. Tracing through `11_restore_from_trash.sh` (which
reconstructs the original path by stripping only the `$MEDIA_TRASH/` prefix and prepending `/`)
showed that pattern breaks restore: the batch directory survives as an extra path segment, so
`11` would restore into a synthetic `/<batch-dir-name>/...` location instead of the real
original path. `13` instead mirrors the full original absolute path directly under
`$MEDIA_TRASH`, matching `06_delete_duplicates.sh`'s already-restore-compatible layout;
`$RUN_TIMESTAMP` is still recorded in the summary and per-move log lines for batch
identification. Verifying this round trip end-to-end (a real test now runs `13 --confirm` then
`11_restore_from_trash.sh --confirm` and asserts the file lands back at its exact original
path) also surfaced a real, previously-uncaught bug in `11`: its final statement,
`[[ "$DRY_RUN" -eq 1 ]] && echo ...`, is a bare `set -e` script's last command, so in confirm
mode (`DRY_RUN=0`) the false condition became the script's own exit code even on a fully
successful restore — no prior test exercised `11 --confirm` end-to-end. Fixed by rewriting it
as an explicit `if`/`fi`; no behavior change to what gets restored or printed.
**Outcome:** `tests/test_shell_scripts.py` adds a `LivePhotoDedupeTests` class covering
verified-pair dry-run output, rejection of an over-duration video, rejection when no paired
still exists, the duration-unknown timestamp-proximity fallback (both the close-enough and
too-far cases), the typed-confirmation gate, and the full confirm-then-restore round trip.
`docs/IMMICH_HELP_LIBRARY.md`'s Takeout Duplicates section and `README.md`'s pipeline steps and
Limitations sections document the new step. shellcheck/shfmt clean.

## Phase 7 — Fix script 12's trash layout so restore actually works (2026-07-13)

**Context:** #62, found during review of PR #61 (#60). `12_clean_immich_takeout_duplicates.sh`
was the one trash-producing script that hadn't been brought in line with `13`'s pivot in Phase
6: it still moved verified duplicates into a timestamped batch subdirectory
(`$MEDIA_TRASH/immich_library_fotos_de_duplicates_<timestamp>/<relative-path>`), while
`11_restore_from_trash.sh` reconstructs the original absolute path by only stripping the
`$MEDIA_TRASH/` prefix and prepending `/`. Restoring a script-12 batch therefore landed files at
a synthetic `/immich_library_fotos_de_duplicates_<timestamp>/...` path instead of their real
original location. This was confirmed against real data: a `12 --confirm` run on 2026-05-29
trashed a batch under exactly that broken layout on the repo owner's machine, and it is still
sitting there unrestored (not part of this repo — a manual one-time cleanup for the repo owner,
not covered by this fix; see the PR for #62).
**Decisions:** Changed `move_or_report_duplicate()` in `12_clean_immich_takeout_duplicates.sh`
to mirror each file's full original absolute path directly under `$MEDIA_TRASH`
(`rel="${duplicate#/}"; dst="$MEDIA_TRASH/$rel"`), dropping the `TRASH_BATCH` timestamped
subdirectory from the move destination entirely — the same pattern `06_delete_duplicates.sh`
and `13_dedupe_live_photos.sh` already use. `$RUN_TIMESTAMP` is kept, but only for
human-readable batch identification: printed in the summary (`Run timestamp: ...`, matching
`13`'s summary line) and prefixed on each per-move log line
(`[$RUN_TIMESTAMP] Moved duplicate: ...`), never in the actual move destination path. The
typed-confirmation gate (`MOVE TAKEOUT DUPLICATES`) and dry-run default are unchanged.
**Outcome:** Added a `test_immich_takeout_cleanup_confirm_and_restore_round_trip` regression
test to `tests/test_shell_scripts.py`, mirroring the round-trip test Phase 6 added for script
13: runs `12 --confirm` then `11_restore_from_trash.sh --confirm` and asserts the file lands
back at its exact original absolute path. The pre-existing
`test_immich_takeout_cleanup_confirm_moves_verified_duplicate_to_trash` test, which asserted
the old (broken) batch-subdirectory destination, was updated to assert the new full-path
destination instead — it was testing the bug's own layout, not the safety gate, so there was no
old-vs-new behavior to preserve there. All 13 tests in `tests/test_shell_scripts.py` pass;
`ruff check scripts` clean.

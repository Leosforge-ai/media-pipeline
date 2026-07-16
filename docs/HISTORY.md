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

## Phase 8 — Boot-disk resolution: isolated raw-parse tests + single-call primitive (2026-07-14)

**Context:** #59, a follow-up from Astrid's review of PR #58 (Phase 6). This was the third
safety-relevant fix to `disk_name_from_partition()` in one merge cycle — PR #56 fixed
single-hop-only LVM/btrfs chain walking, PR #58 fixed a missing `-d`/`--nodeps` flag that let
child-partition rows leak into boot-disk detection. During PR #58's review, Astrid empirically
proved (by testing three code variants) that the regression tests added for that fix only
exercised the defensive first-line-truncation backstop, not the `-d` flag fix itself — running
the tests with `-d` stripped (truncation kept) still passed all 29 tests silently, only failing
when both the flag and the truncation were removed. Two real bugs in the same
safety-critical function in one cycle suggested the underlying primitive — parsing `lsblk` text
output and manually walking a parent chain one PKNAME hop at a time — was fragile enough to be
worth reconsidering structurally, not just patching again.
**Investigation (part 2 of #59):** Evaluated alternatives to manual PKNAME chain-walking for
resolving a device to its top-level disk on Ubuntu/Debian (this repo's target, confirmed via
README Requirements): `lsblk -no PKNAME --list` filtering (still requires the same manual
per-hop loop, doesn't remove the bug class), `/sys/block/*` symlink parsing via `readlink -f`
(works but reintroduces hand-rolled text/path parsing of a different kind, same fragility
class), `udevadm info` chain queries (heavier, less directly aimed at "ancestor disk"), and
`lsblk -s`/`--inverse` (built into util-linux lsblk specifically to print a device's full
dependency chain in one call). Verified live on this repo's dev machine (Ubuntu 24.04,
util-linux 2.39.3): `lsblk -o NAME,TYPE -P -s /dev/vda1` returns the complete ancestor chain
(`vda1` then `vda`) in a single call, and confirmed a whole-disk device with children returns
only its own row (no child-row leakage) — the exact failure mode `-d` was patched to prevent,
eliminated structurally instead of by flag. `-s` has shipped since util-linux 2.21 (2012), well
within this repo's Ubuntu/Debian-family target.
**Decisions:** Replaced `disk_name_from_partition()`'s manual PKNAME-walking loop (hop counter,
per-hop `lsblk -d -no TYPE`/`-no PKNAME` calls, first-line-truncation backstop) with a single
`lsblk -o NAME,TYPE -P -s DEVICE` call, factored into its own `lsblk_ancestor_chain_raw()`
function so the raw parsing step is unit-testable independent of the "pick the TYPE=disk row"
filtering logic layered on top of it (part 1 of #59's ask: an isolated, lower-level test of the
raw parse step before any higher-level filtering is applied). This removes the entire bug class
both prior fixes patched — there is no loop, no hop counter, and no `-d` flag whose future
omission could reintroduce child-row pollution, because lsblk itself is now responsible for
building the correct ancestor chain in one call, the same way it already does internally to
render its own tree view.
**Pivots:** Part 1 of #59 asked specifically to isolate the old `-d`/`--nodeps` fix with a test
that strips only that flag; since part 2's investigation concluded to replace the manual
PKNAME-walking implementation entirely (removing `-d` from the code, not just testing around
it), the isolation principle was applied to the new implementation's own raw-parse boundary
instead: `test_lsblk_ancestor_chain_raw_isolation_catches_missing_dash_s_regression` mutates a
copy of the script (surgically dropping only the `-s` flag from the one lsblk call in
`lsblk_ancestor_chain_raw`) and proves, at that raw layer alone, the mutated call leaks child
rows — mirroring Astrid's proof methodology for the old bug, aimed at the primitive actually
shipped.
**Outcome:** `tests/test_first_time_drive_setup.py` goes from 29 to 28 tests (three
now-superseded #57-bug-2 regression tests, which asserted behavior of the removed manual loop,
replaced by two new isolated raw-parse-layer tests: one proving `lsblk_ancestor_chain_raw`
never leaks child rows for a whole-disk device, one proving a dropped-`-s` regression is caught
at that layer directly). All three known disk-layout scenarios (simple partition, LVM chain,
btrfs subvolume) remain covered end-to-end via `disk_name_from_partition`/`root_boot_disk`
tests, now stubbing the single `-s` call instead of per-hop TYPE/PKNAME calls. Full suite (45
tests across `tests/`) passes; `shellcheck -x -e SC1091 scripts/*.sh config/*.sh`, `shfmt -d`,
and `ruff check scripts tests` all clean. Verified live against this repo's own dev machine
(`root_boot_disk` correctly resolves to `vda`, the real boot disk).
## Phase 9 — Guided run: persist checkpoint state; retry from failed step (2026-07-14)

**Context:** #51, two deferred review notes from PR #50/#58 (guided pipeline run, #48).
Astrid: `_guidedSegmentIndex` in `media_pipeline_app.dart` lived only in widget state, so an app
restart mid-guided-run silently forgot which checkpoint had been reached and "Continue Guided
Run" started over from segment 0. Cody: `_runNextGuidedSegment()` always re-ran a failed
segment from its first step, even when most of that segment's steps had already succeeded.
Neither touches the confirm-gate safety invariant — `GuidedRunController.run()` still refuses
any `PipelineRisk.confirmRequired` step outright, unchanged by this work.
**Decisions:** Added `lib/src/guided_run_checkpoint_store.dart`, following
`ImmichChecklistStore`'s exact "small local JSON file, no secrets" pattern: a
`GuidedRunCheckpointStore` persists a single `GuidedRunCheckpoint` (`segmentIndex`, the
`hdPath`/`reportDir` settings in effect, and `updatedAt`). Staleness signal: a checkpoint is
ignored on restore if `hdPath`/`reportDir` no longer match the app's current settings (resuming
against a since-changed target could silently skip steps a new target never actually ran), or
if it's older than `guidedRunCheckpointMaxAge` (7 days — a simple, explainable cutoff favored
over trying to fingerprint script output/mtimes). `_PipelineHomePageState.initState()` now
restores `_guidedSegmentIndex` from a non-stale checkpoint; `_runNextGuidedSegment()` saves a
new checkpoint whenever a segment fully completes (and clears it once the whole guided run
finishes) — no checkpoint write on a step failure/abort, since the segment index hasn't moved.
For retry granularity, `_runNextGuidedSegment()` now tracks `_guidedSegmentCompletedCount` (how
many steps at the start of the current segment already succeeded, across possibly more than one
attempt) and `_guidedSegmentAttemptSettings` (the settings those successes actually ran
against). A retry resumes from the failed step — skipping the already-succeeded prefix — only
when the settings for the retry still match `_guidedSegmentAttemptSettings`; if the human edited
HD_PATH/REPORT_DIR in between, those earlier successes ran against a different target and can no
longer be trusted, so the segment restarts from its first step instead (the "re-validate
anything that could have changed" direction from the issue). `GuidedRunController.run()` itself
is untouched — the app only ever passes it a shorter, still-ordered slice of the same validated
`buildGuidedRunSteps()` chain, so the "never auto-run a confirm-gated step" check stays exactly
where it was.
**Pivots:** Widget tests exercising this initially used a real `GuidedRunCheckpointStore`
backed by a `Directory.systemTemp.createTemp()` temp directory, following
`immich_phone_checklist_store_test.dart`'s plain-`test()` pattern — but real `dart:io` file
operations awaited directly inside `testWidgets` hang indefinitely under flutter_test's
fake-async zone unless wrapped in `tester.runAsync()` (confirmed with an isolated repro: a bare
`Directory.systemTemp.createTemp()` inside `testWidgets` never returns). Switched to an
in-memory fake store (mirroring `widget_test.dart`'s existing `_FakeChecklistStore`), which is
both simpler and already the established pattern for widget-level tests here.
**Outcome:** Added `test/guided_run_checkpoint_store_test.dart` (save/load/clear round trip,
`GuidedRunCheckpoint.isStale` age and settings-mismatch cases) and
`test/guided_run_persistence_and_retry_widget_test.dart` (checkpoint restored across a simulated
app restart; a stale checkpoint is ignored; a mid-segment failure retries from the failed step
without re-running already-succeeded steps; editing HD_PATH before retrying restarts the segment
from its first step; retry-from-failed-step never reaches `delete-confirm`/`restore-confirm`).
Full suite: 86 tests pass (`flutter test`); `flutter analyze` clean.

## Phase 10 — Dedup review: surface sample coverage prominently (2026-07-14)

**Context:** #53, follow-up from Astrid's #52 review. Phase 4's thumbnail review dialog is
honest about sampling ("Showing N of M pairs", never silently truncated), but the
`delete-confirm` gate only ever required *opening* the dialog once — not reviewing a
representative share of pairs. For a large duplicate set (e.g. 20 of 143 shown ≈ 14%), a human
could reasonably feel "I reviewed the duplicates" while `--confirm` would act on all 143, not
just the reviewed sample.
**Decisions:** Combined both directions the issue floated, since together they're still simple
to reason about: (1) the "delete-confirm" step's detail panel — directly above the "Run
Confirm" button itself, not just inside a dialog a human could skim past — now states reviewed
count and percentage explicitly ("You reviewed 20 of 25 pairs (80%) before confirming.") in a
color-coded chip (red under 50%, orange 50-99%, primary at 100%); and (2) the review dialog
gained a "Review Another Sample" button that draws additional, non-overlapping batches from the
pairs not yet shown, so a human who wants more confidence than the first batch gives can keep
paging through the set. `duplicate_report.dart` gained
`sampleAdditionalDuplicateReviewPairs(pairs, alreadyReviewedIndices, {batchNumber})` (batch
`0` is `sampleDuplicateReviewPairs`'s new implementation), `DuplicateReviewSample.shownIndices`
(original-report indices, not path-based, so pairs that legitimately share a path can't be
miscounted) and `.coveragePercent` (always floored, never rounded up — this is a trust signal
next to a destructive action), and `duplicateReviewCoveragePercent(reviewed, total)`. The app
tracks `_dedupReviewedIndices` (a `Set<int>`, union across every batch opened for the current
dry-run output), reset alongside `_dedupReviewAcknowledged` whenever `delete-dry-run` reruns,
same invalidation rule as Phase 4.
Deliberately **not** touched: the confirm gate itself. `canRunStep()` and
`requiresDuplicateThumbnailReview`/`duplicateThumbnailReviewAcknowledged` are byte-for-byte
unchanged — opening the review dialog once still unlocks `delete-confirm`, exactly as in Phase
4. This is framing/information only, strictly additive on top of the existing gate: a
`_DedupReviewPanel` coverage banner can show "80%" and confirm is still enabled, by design (the
issue's own possible-directions list did not ask for a stricter gate, and CLAUDE.md's Safety
Rules call for not making the gate *harder* to reach — not for changing when it unlocks). Sofie
weighed a threshold-based stricter gate (e.g. "must review 50%+ before confirm") against this
and chose the informational approach: a hard threshold risks becoming exactly the kind of
brittle, hard-to-explain rule the review dialog was built to avoid (Phase 4's "explainable, no
silent truncation" ethos) — a human who's seen 3 confirmed near-duplicate JPEGs from the same
camera in a row may reasonably trust the rest without wanting to click through 143; making that
call impossible would trade one false-confidence risk for a worse one (training people to click
past a gate they feel is arbitrary). The coverage banner instead makes the tradeoff visible and
lets the human decide.
**Pivots:** The review dialog's `initState()` originally called the
`onReviewedIndicesChanged` callback synchronously to report the initial batch's coverage back
to the parent `_PipelineHomePageState`. This calls `setState()` on an ancestor widget while the
framework is still building the dialog's route — caught in an early widget-test run as a
`setState() called during build` failure. Deferred with
`WidgetsBinding.instance.addPostFrameCallback` instead, which is safe because by then the
current build pass has finished; the "Review Another Sample" button's own `setState` call is
triggered by a user tap outside any build phase, so it needed no such deferral. Also initially
compared a per-batch "is this batch incomplete" flag against the grand total (`totalPairs`)
rather than what was actually still unreviewed at draw time, which made a final "everything
that's left" batch incorrectly still report as sampled — fixed by adding
`DuplicateReviewSample`'s private `_remainingBeforeBatch` bookkeeping so `isSampled` compares
against the right denominator.
**Outcome:** `06_delete_duplicates.sh` and its Czkawka-report parsing are unchanged — Dart/UI
only, per the issue's own scope. `duplicate_report_test.dart` gained coverage for
`duplicateReviewCoveragePercent`'s flooring behavior, `shownIndices` correctness, and
`sampleAdditionalDuplicateReviewPairs`'s non-overlapping-batch/reproducibility/tail-handling
cases. `dedup_review_widget_test.dart` gained an end-to-end case proving the coverage banner
and "Review Another Sample" flow reach 100% cumulative coverage without ever re-showing a pair,
and a case proving the original Phase 4 gate behavior is unchanged (opening the dialog once
still unlocks confirm at any coverage percentage). Both of Phase 4's original gate tests pass
unmodified. Full suite: 98 tests pass (`flutter test`); `flutter analyze` clean.

## Phase 11 — PipelineRunner: separate stdout capture for the dedup parser (2026-07-14)

**Context:** #54, follow-up from Cody's review of #49/PR #52. `PipelineRunner.run()` merges a
step's stdout and stderr into one buffer via two independent stream listeners, but
`duplicate_report.dart`'s "Keep:"/"Would trash:" parser implicitly assumed it was reading pure
stdout. Not exploitable today — `06_delete_duplicates.sh` has no stderr writes on its success
path — but a latent correctness assumption feeding a destructive-delete confirm gate: if a
script (this one or a future one) ever wrote to stderr between two groups' announcement lines,
an interleaved stderr line could theoretically strand a stale "Keep:" to later mispair with an
unrelated "Would trash:" in the review dialog.
**Decision:** Of the issue's three suggested directions, chose to split stdout/stderr at
`PipelineRunner` itself (not a `duplicate_report.dart`-only filter, and not a
`06_delete_duplicates.sh`-side invariant) — but additively, not by replacing the merged buffer.
`PipelineRunner.run()`'s two existing stream listeners (`process.stdout`, `process.stderr`)
still both write into the original combined `output` buffer and both still call `onLog` for
every chunk exactly as before, so the live step-log UI's real-time interleaving is
byte-for-byte unchanged — a human watching a long-running step still sees stdout and stderr
interleaved as they actually arrive, nothing is hidden or reordered. The stdout listener
additionally accumulates into a new, dedicated `stdoutOutput` buffer that never receives
stderr content. `PipelineRunResult` gained `stdoutOutput` (alongside the existing `output`);
`StepRunState` gained `stdoutLog` (alongside the existing `log`). `media_pipeline_app.dart`'s
dedup-review call sites (`_openDedupReviewDialog`'s `dryRunLog` and the step-detail panel's
`dedupDryRunLog` pair-count preview) now read `stdoutLog` instead of `log`; every other use of
`log`/`output` (the visible step-log panel, guided-run completion state) is untouched.
Rejected the `duplicate_report.dart`-only filter/tag approach: it would close the risk for this
one parser but leave the same merged-buffer assumption open for any future safety-relevant
parser that reads `StepRunState.log` — the issue explicitly flagged this as an architectural
assumption, not just a bug in one call site. Rejected the script-side invariant alone (never
write to stderr on `06_delete_duplicates.sh`'s success path): it's a reasonable belt-and-braces
addition but doesn't fix the underlying `PipelineRunner` assumption either, and enforcing it
only defers the same risk to the next script that grows a legitimate stderr write. Did not
touch `06_delete_duplicates.sh` — no behavior-change or invariant-addition was needed once the
fix moved to `PipelineRunner`.
**Outcome:** `pipeline_runner_test.dart` gained a `stdout/stderr separation (issue #54)` group:
one test spawns a real bash script that interleaves stdout ("Keep:"/"Would trash:" lines) with
stderr writes between them, and asserts `stdoutOutput` contains zero stderr content while
`output` (and every `onLog` chunk) still contains both, unchanged; a second test asserts
`onLog` still fires for both streams exactly as before. `dedup_review_widget_test.dart` gained
an end-to-end widget test with a new `_StreamSeparatedFakePipelineRunner` that returns a
stdout-only capture different from its merged log (simulating a stray interleaved "Keep:" that
only exists in the merged/stderr-contaminated stream) and proves the review dialog shows only
the one real pair from stdout — the phantom "Keep:" never surfaces as a pair or leaks into the
dialog — while remaining fully visible on the step's own log panel afterward, so nothing is
silently dropped from the human-facing view. All pre-existing confirm-gate tests
(`GuidedRunController` refusal tests, Phase 4/10 dedup gate tests) pass unmodified. Full suite:
101 tests pass (`flutter test`); `flutter analyze` clean.

## Phase 12 — Pin gitleaks CLI version instead of floating @latest (2026-07-14)

**Context:** #73. `gitleaks.yml` installed the gitleaks CLI via `go install
github.com/zricethezav/gitleaks/v8@latest` against a hardcoded `go-version: '1.21'`. Gitleaks
v8.30.1 shipped requiring `go >= 1.24.11` per its own `go.mod`, so the floating `@latest`
started resolving to a release the pinned Go toolchain couldn't build — breaking the mandatory
gitleaks security gate intermittently/permanently on every PR regardless of that PR's content
(observed live: PR #47 failed while #40/#44/#45/#46 passed).
**Decision:** Checked the `go.mod` `go` directive for the gitleaks tags around the break
(via `curl https://proxy.golang.org/github.com/zricethezav/gitleaks/v8/@v/<tag>.mod`):
v8.21.x–v8.27.x already require Go 1.23, v8.28.x–v8.29.x require Go 1.23.8, and v8.30.x
requires Go 1.24.11+/1.25.4. Since even the oldest "reasonably current" gitleaks releases need
newer-than-1.21 Go, pinning gitleaks alone (issue's primary suggested fix) wasn't enough on its
own — both a gitleaks version *and* a compatible `go-version` needed pinning, which the issue's
acceptance criteria anticipated ("verified compatible with whatever go-version the workflow
specifies"). Pinned gitleaks to `v8.30.1` (latest existing release tag, confirmed present in
`go list`'s module proxy version list, not an ancient release). Initially bumped `go-version` to
the bare minor `'1.24'`, but Cody's PR review flagged that `actions/setup-go`'s default
`check-latest: false` prefers a cached toolchain over the newest matching patch — a partial
version spec isn't strictly guaranteed to resolve above the `>= 1.24.11` floor gitleaks v8.30.1
needs, which could silently recreate this exact failure class. Tightened to the exact patch
`'1.24.13'`, verified as a real published Go release via `https://go.dev/dl/?mode=json`. Left
the existing SHA-pinned `actions/checkout`/`actions/setup-go` steps untouched — only the
floating `@latest` install and the Go version needed to move.
**Outcome:** `.github/workflows/gitleaks.yml`'s install step now reads
`go install "github.com/zricethezav/gitleaks/v8@${GITLEAKS_VERSION}"` with `GITLEAKS_VERSION:
v8.30.1` pinned as a step `env`, and `go-version: '1.24.13'` (exact patch, not a bare minor),
plus inline comments giving the exact commands (proxy.golang.org `.mod`/`/list` and go.dev/dl
JSON lookups) to check compatibility and bump `GITLEAKS_VERSION` and the exact `go-version`
patch together the next time a deliberate upgrade is needed, so this doesn't silently drift
back to a floating target. No product code (`scripts/`, `lib/`, `tests/`) touched — CI config only.

## Phase 13 — Dart port, Phase 0a: drive-detection read-only logic (2026-07-14)

**Context:** Part of #76/#77's shared Phase 0 roadmap (cross-platform Docker-container /
native-runtime designs both need the pipeline's orchestration logic ported from Bash to Dart
before either design can proceed). Phase 0a is the first slice: port only the READ-ONLY
detection logic from `scripts/00b_first_time_drive_setup.sh` — boot/root-disk resolution,
candidate-partition filtering, filesystem-type detection — leaving the confirmation-gated
mount/fstab-append actions in Bash for a later phase, per the same print-don't-execute boundary
the Bash script already enforces.
**Decisions:** New `lib/src/drive_detection.dart` mirrors the Bash functions 1:1
(`lsblk_ancestor_chain_raw`/`disk_name_from_partition`/`root_boot_disk` →
`DriveDetector.lsblkAncestorChain`/`diskNameFromPartition`/`rootBootDisk`;
`list_candidate_partitions` → `filterCandidatePartitions`; `detect_fstype` →
`DriveDetector.detectFstype`), built from small pure functions
(`parseLsblkPairLines`, `stripBtrfsSubvolumeSuffix`, `resolveDiskNameFromAncestorChain`,
`filterCandidatePartitions`, `extractFirstLine`) that take plain strings/data with zero
subprocess dependency, plus a thin `DriveDetector` class that shells out via `Process.run`
(same pattern as `pipeline_runner.dart`). Kept the `-s`/`--inverse` ancestor-chain primitive
from PR #66 as the *only* call site that resolves a device's disk ancestry — there is no
hand-rolled PKNAME-walking loop in this port for the #56/#57/#58 bug class to recur in.
Did not modify or retire `scripts/00b_first_time_drive_setup.sh` — it keeps working standalone
until a much later phase proves the Dart port fully equivalent.
**Outcome:** `test/drive_detection_test.dart` (25 tests) covers every scenario
`tests/test_first_time_drive_setup.py`'s Bash suite tests for this logic: simple partition,
LVM chain (`/dev/mapper/vg-root` → `sda1` → `sda`), btrfs subvolume bracket-suffix stripping,
boot-disk exclusion (including the LVM sibling-partition regression and the "boot disk is the
only large unmounted partition" regression), non-numeric/missing `SIZE` handling, and the
lsblk-first/sudo-blkid-fallback filesystem-type detection order — all against synthetic
fixture strings, no real subprocess needed. Also kept a `DriveDetector real-machine tests`
group that calls the real `lsblk`/`blkid`/`findmnt` on whatever Linux machine runs the suite
(skipped outside Linux), matching what the Bash test suite already does for its own real
end-to-end tests: `rootBootDisk` resolves to a disk lsblk actually reports, the ancestor-chain
query for that disk reports zero `TYPE=part` rows, `candidatePartitions` never includes a
partition on the real boot disk, and `detectFstype` returns a real filesystem type for the
root partition without needing the sudo fallback. Full suite: `flutter analyze` clean, `flutter
test` 126/126 passing (up from 101), including the new real-machine tests running live during
CI/local verification on this Linux dev box.
## Phase 14 — Tools container image, Phase 1 of #76 (2026-07-14)

**Context:** [#76](https://github.com/Leosforge-ai/media-pipeline/issues/76) is a multi-phase
roadmap to move the pipeline to a Docker-containerized tool runtime (Design A), so the Dart
desktop app can drive `exiftool`/`ffmpeg`/`rclone`/`czkawka` identically on Linux, macOS, and
Windows via the Docker dependency this repo already requires for Immich. Phase 1 is standalone:
build the tools image and prove it works, without wiring anything up yet.
**Decisions:** Added `docker/tools/Dockerfile`, a multi-arch (`linux/amd64` + `linux/arm64`)
image on `debian:bookworm-slim` (pinned by digest) bundling all four tools at pinned versions:
`exiftool`/`ffmpeg` via exact-pinned apt package versions (`libimage-exiftool-perl=12.57+dfsg-1`,
`ffmpeg=7:5.1.9-0+deb12u1` — matching what `scripts/01_setup_dependencies.sh` installs via apt
today), `rclone` via a checksum-verified upstream release binary (`v1.74.4` — apt's bookworm
version, 1.60.1, is years stale), and `czkawka_cli` via a checksum-verified upstream release
binary pinned to an exact tag (`12.0.0`, not `latest` as the host script uses, since `latest` is
not reproducible; czkawka doesn't publish a checksums file so the pinned SHA256s were computed
at pin-time from the downloaded assets). Runs as a non-root `tools` user by default (full
UID/GID host-mapping is Phase 3). Verified on both architectures (amd64 natively, arm64 via
`docker buildx` + QEMU emulation): all four `--version`/`-ver` invocations exit 0 with sane
output, and a real `czkawka_cli dup` scan against synthetic files correctly identified a planted
duplicate pair and ignored the unique file, on both architectures.
**Pivots:** None — the two most likely deviations flagged going in (czkawka needing a non-apt
path, rclone's apt version being outdated) were both confirmed and documented rather than
avoided.
**Note for Phase 2:** `czkawka_cli`'s exit code is not a plain 0/non-zero success flag — it
returns `0` when no duplicates are found and a non-zero count-like code when duplicates *are*
found, discovered during this phase's verification. `scripts/05_cleanup_scan.sh` already pipes
`czkawka_cli` invocations through `tee` under `set -euo pipefail` today; this is pre-existing
Bash-script behavior, unrelated to and out of scope for this container-only PR, but worth
checking when Phase 2 wires the container's `czkawka_cli` into any pipefail-sensitive call site.
**Outcome:** A reproducible, verified, multi-arch tools image exists at
`docker/tools/Dockerfile`, documented in `docker/tools/README.md` (build commands, debugging
shell, and a version-bump procedure per tool). Nothing in `scripts/*.sh` or `lib/**` was
touched — no pipeline behavior changed. #76 stays open; only Phase 1 is complete.

## Phase 15 — Dart port, Phase 0b (first script): restore-from-trash (2026-07-14)

**Context:** Shared Phase 0 of #76/#77's roadmap calls for porting the four confirm-gated
destructive scripts (`06_delete_duplicates.sh`, `11_restore_from_trash.sh`,
`12_clean_immich_takeout_duplicates.sh`, `13_dedupe_live_photos.sh`) to Dart before any Bash
script is retired. `11_restore_from_trash.sh` is the pipeline's sole recovery mechanism — every
other destructive script relies on it to reverse a move-to-`media_trash`, and it had a real
exit-code bug as recently as PR #61/#63 — so it is the first and highest-priority of the four to
port, with the equivalent test rigor `drive_detection.dart` (Phase 0a) established.
**Decisions:** Added `lib/src/restore_from_trash.dart`, mirroring `drive_detection.dart`'s shape:
a pure `reconstructOriginalPath()` (strips the `$MEDIA_TRASH/` prefix and prepends `/`, exactly
mirroring the Bash script's `rel="${f#"$MEDIA_TRASH"/}"; dest="/$rel"`) plus a pure
`parentDirectory()` (`dirname` equivalent), and a thin `TrashRestorer` class doing the actual
`Directory.list(recursive: true)` walk and `File.rename` move. No-clobber semantics
(`mv -n`) are replicated exactly: an existing destination is left alone (`RestoreAction
.skippedExisting`), never overwritten, and the trashed duplicate stays in `media_trash`,
unresolved but never deleted. `TrashRestorer.run(confirm: false)` (the default) only computes and
returns what *would* happen, touching nothing on disk — proven with real temp-directory
mtime/content assertions, not just log-string checks. `File.rename`'s cross-filesystem limitation
(unlike real `mv`, it doesn't transparently fall back across devices) is handled explicitly:
`TrashRestorer._moveFile` catches the cross-device rename failure (`EXDEV`/errno 18) and falls
back to copy + byte-length verification + delete-original, never deleting the trashed file before
the copy is confirmed on disk. This fallback branch is implemented but not exercised by the test
suite — reproducing genuine `EXDEV` needs two distinct mounted filesystems, unavailable in this
sandbox/CI, and the test file documents this gap explicitly rather than claiming coverage that
doesn't exist. Also added a direct regression test class for the PR #61/#63 bug (--confirm
wrongly reporting failure via a bash trailing conditional under `set -e`): this port has no
equivalent footgun by construction, since success/failure is signaled exclusively by
`Future<List<RestoreOutcome>>` completing normally vs. throwing, with no separate exit-code/
last-statement side channel a trailing print could hijack — proven with a fully successful
--confirm-equivalent run and a fully successful empty-dry-run completing the Future normally.
`scripts/11_restore_from_trash.sh` itself is untouched and remains the working fallback; this PR
is additive only.
**Pivots:** None.
**Outcome:** `lib/src/restore_from_trash.dart` + `test/restore_from_trash_test.dart` (20 new
tests: pure path reconstruction incl. spaces/unicode/nested paths, dry-run non-mutation, confirm
mode moves + no-clobber, a full trash-convention round-trip matching scripts 06/12/13's layout,
and the PR #61/#63 regression class). Full suite: `flutter analyze` clean, `flutter test`
146/146 passing (up from 126). Part of #76 and #77; neither issue closes — 06/12/13 and the
Phase 0c/0d work remain.
## Phase 16 — Fix `05_cleanup_scan.sh` aborting on found-count exit codes (2026-07-14)

**Context:** Issue #81, found and reproduced during Cody's review of PR #80 (#76 Phase 1):
`scripts/05_cleanup_scan.sh` runs under `set -euo pipefail` and pipes every `czkawka_cli`
invocation through `tee` for logging. `czkawka_cli`'s exit code for the `image`/`video`/`dup`
subcommands is a found-count, not a plain success flag — `0` means nothing found, any other
value means N duplicates/similar items were found (the normal, expected outcome of a dedup
scanner). Because of `pipefail`, that found-count propagated through the `tee` pipe as the
pipeline's exit status, and `set -e` treated it as a fatal error — aborting the whole script
the instant the *first* scan (image) found anything. The video scan, exact-duplicate scan,
blur scan, and summary section never ran whenever duplicates existed, which is the common case,
not an edge case. This was pre-existing, shipped behavior, flagged as a "Note for Phase 2" in
Phase 14 above but out of scope for that container-only PR.
**Decisions:** Captured `czkawka_cli`'s real exit code via `${PIPESTATUS[0]}` for every
`czkawka_cli ... | tee ...` invocation (image, video, dup), instead of trusting pipefail's
propagated pipeline status. Refactored the three near-identical invocations into one
`run_czkawka_scan()` helper to keep the exit-code handling in one place. Distinguished a
found-count (informational, must not abort the script) from a genuine tool failure (must still
abort, per this repo's data-loss-prevention priority) by treating only exit codes attributable
to a real crash/invocation failure as fatal: `101` (the default exit code for an uncaught Rust
panic — `czkawka_cli` is a Rust binary) and `126`/`127` (standard "found but not executable" /
"command not found" codes). Every other non-zero code is treated as an informational
found-count. Also captured `tee`'s own exit code via `${PIPESTATUS[1]}` (both indices read in
one `local` statement, since bash resets `PIPESTATUS` after every simple command) and treat a
failed log write as a real, separate error. `06_delete_duplicates.sh`'s report-parsing format
is unchanged — only `05`'s exit-code handling changed.
**Verification:** Added a regression test (`tests/test_shell_scripts.py`,
`CleanupScanExitCodeTests`) that plants two real, byte-identical duplicate files and runs
`05_cleanup_scan.sh` against a fake `czkawka_cli` that does real work (hashes the real files
under `-d`, writes real duplicate groups to `-f` in Czkawka's actual report format, then exits
with the real group count) plus stub `ffmpeg`/`ffprobe`/`convert` so the script's tool-presence
check passes without needing the real binaries installed. Confirmed the test would have caught
the original bug: temporarily reverted the script fix and re-ran the test suite — both new
tests failed (`1 != 0` on the found-duplicates case; the genuine-failure case never printed
anything since the script died silently through pipefail before reaching the new error-handling
path). Restored the fix and re-ran: both tests, plus the full existing suite (47 tests total),
`shellcheck -x -e SC1091`, `shfmt -d`, and `ruff check` all pass clean.
**Pivots:** None.
**Outcome:** `05_cleanup_scan.sh` now runs all four scan types and prints the summary section
regardless of how many duplicates each scan finds, while still surfacing and aborting on a
genuine `czkawka_cli` crash or invocation failure. Closes #81.

## Phase 16 — PR #83 review fixes: signal-death exit codes + exit-code terminology (2026-07-14)

**Context:** Astrid and Cody's reviews of PR #83 (Phase 15) each found a gap.
Astrid: the fatal-exit-code allowlist (`101`/`126`/`127`) didn't cover the standard Unix
signal-death convention (a process killed by signal N exits with code `128+N`) — so `137`
(SIGKILL, most commonly an OOM-kill) or `139` (SIGSEGV) would have been silently classified as
"just found N duplicates" and a truncated/corrupt report trusted as complete. This matters
concretely, not just in theory: `czkawka_cli` is planned to run inside a memory-limited Docker
container per #76's roadmap (PR #80, already merged), where OOM-kills become materially more
likely. Cody: pulled czkawka's actual upstream source (`czkawka_cli/src/main.rs`) and found the
real "found duplicates" exit code is a **fixed constant, `11`** — not a variable found-count as
Phase 15's comments, HISTORY entry, and test double all described. This didn't change Phase
15's fix correctness (11 still lands in the "keep going" bucket either way), but the
terminology was wrong.
**Decisions:** Replaced the allowlist-of-known-fatal-codes approach with a denylist-of-
known-safe-codes approach: only `0` (nothing found) and `11` (czkawka's real, fixed
found-duplicates sentinel) are now treated as non-fatal; every other exit code aborts the
script. This is both more correct (matches czkawka's actual, narrow exit-code contract) and
fail-closed by construction — it automatically covers `137`/`139`/any other signal-death code
(`128+N`) and any other unrecognized code, without needing to enumerate every possible crash
mode. Kept `101`/`126`/`127` and the `128-255` signal-death range documented inline as known,
named failure modes for diagnostic value, even though the actual conditional no longer needs to
special-case them. Corrected all "found-count" language in the script's comments to describe
the real fixed-`11` sentinel. Updated the fake `czkawka_cli` test double to exit `11` (not an
arbitrary group count) when it plants duplicate groups, so it accurately models real czkawka
behavior.
**Verification:** Added `test_signal_death_exit_code_still_aborts_the_script`
(`CleanupScanExitCodeTests`), parametrized over `137` and `139`, asserting the script aborts
before the video scan or summary. Confirmed this test would have caught the gap: ran it against
Phase 15's original fix commit (`9077097`) — both parametrized cases failed
(`AssertionError: 0 == 0`, i.e. the script exited successfully on a simulated OOM-kill/segfault
instead of aborting). Restored the corrected script and re-ran: full suite (48 tests total),
`shellcheck -x -e SC1091`, `shfmt -d`, and `ruff check` all pass clean.
**Pivots:** Switched from an allowlist of known-fatal codes to a denylist of known-safe codes
(`{0, 11}`), per Astrid's signal-death finding and Cody's fixed-sentinel finding together —
once the real exit-code contract is only two values, fail-closed on everything else is both
simpler and safer than continuing to enumerate failure modes.
**Outcome:** `05_cleanup_scan.sh` now correctly treats only `0`/`11` as non-fatal and aborts on
any other exit code, including OOM-kills and other signal deaths inside the planned container
environment. PR #83 updated accordingly; still open for final review, not merged.

## Phase 17 — Extract shared safe-file-move primitive (2026-07-14)

**Context:** Astrid's review of PR #82 (the `11_restore_from_trash.sh` Dart port) flagged that
the cross-device-safe, no-clobber file-move logic (rename with EXDEV fallback to
copy+byte-verify+delete-original, cleaning up any partial/corrupt destination on failure) lived
only inside `TrashRestorer`, private to `restore_from_trash.dart` — but issue #76's Phase 0b
roadmap calls for porting three more confirm-gated destructive scripts
(`06_delete_duplicates.sh`, `12_clean_immich_takeout_duplicates.sh`,
`13_dedupe_live_photos.sh`) that each `mv` files into `$MEDIA_TRASH` using the identical `mv`
no-clobber semantics. Doing those ports without extracting this logic first would have meant
three near-duplicate re-implementations of safety-critical move logic.
**Decisions:** Added `lib/src/filesystem_ops.dart` with `SafeFileMover` (`moveNoClobber`,
`copyVerifyAndReplace`, the injectable `FileCopier` seam, and the shared `parentDirectory`
dirname helper) — the exact logic previously in `TrashRestorer`, generalized to not be
trash-specific. `restore_from_trash.dart`'s `TrashRestorer` is now a thin caller: it walks
`$MEDIA_TRASH`, reconstructs original paths, and gates on dry-run/confirm, delegating every
actual move to `SafeFileMover.moveNoClobber`. `parentDirectory` is re-exported from
`restore_from_trash.dart` so existing importers keep working. Moved the generic-primitive tests
(dirname, `copyVerifyAndReplace` copy/verify/cleanup behavior) from `restore_from_trash_test.dart`
into a new `test/filesystem_ops_test.dart`, and added two new tests exercising
`moveNoClobber` directly (move-with-mkdir, no-clobber-skip) now that the primitive is
independently testable outside the trash-restore context. `restore_from_trash_test.dart` keeps
the trash-specific coverage: path reconstruction, dry-run/confirm behavior, no-clobber in the
trash-restore context, and the full round-trip.
**Verification:** Pure refactor — `TrashRestorer`'s external behavior is unchanged. Test count:
24 tests in `restore_from_trash_test.dart` before the split; 16 remain there (trash-specific)
and 10 moved to `filesystem_ops_test.dart` (8 moved + 2 new `moveNoClobber` tests), confirming
none were lost. Full suite (152 tests) and `flutter analyze` both pass clean.
**Pivots:** None — a contained, same-behavior refactor per Astrid's review finding.
**Outcome:** `SafeFileMover` is ready for the 06/12/13 ports (still Bash today, not part of this
change) to reuse instead of each re-implementing the move-safety logic. Part of #76 and #77;
not closing either — both stay open until those ports land.

## Phase 18 — Port delete-duplicates to Dart (2026-07-14)

**Context:** Phase 0b of issue #76/#77's shared roadmap continues: `06_delete_duplicates.sh` is
the highest-stakes port in the series — the script that actually decides which file in a
Czkawka duplicate group survives and which get moved to `$MEDIA_TRASH`. The thumbnail-diff
review dialog (issue #49, PR #52/#69/#71) exists specifically so a human can double-check this
exact decision before it happens for real, so this port had to preserve that trust relationship,
not just the scoring logic.
**Decisions:**
- Added `lib/src/delete_duplicates.dart`: `scoreKeepPath` (pure port of `score_keep_path`,
  same 0/5/10/12/20 scoring chain in the same order) and `decideCzkawkaReportGroups` (pure port
  of `process_czkawka_report`'s grouping — only a line starting with a `"..."`-quoted string
  under `stagingRoot` is ever treated as a path; report headers, dimension lines, and size
  annotations are never misparsed as paths, per `.company/forbidden-actions.md`'s explicit rule
  for this script). `DuplicateDeleter` wires the pure decision logic to the filesystem:
  dry-run by default, confirm-gated moves via the shared `SafeFileMover.moveNoClobber`
  (`filesystem_ops.dart`, from Phase 17/PR #84) rather than reimplementing move semantics.
  Trash destination mirrors the full-original-path-minus-leading-slash convention 06/12/13
  already use post-#62.
- **`duplicate_report.dart` integration decision (the key design call for this port):** this PR
  does **not** rewire `pipeline_models.dart`'s `delete-dry-run`/`delete-confirm` steps — they
  still shell out to the real `scripts/06_delete_duplicates.sh`, exactly like Phase 0b's earlier
  port left `11_restore_from_trash.sh` wired as the executed script (wiring the Dart-native/
  container execution path is Phase 2 of issue #76, not this slice). Because nothing actually
  executing today changes, `duplicate_report.dart`'s `parseDuplicateDryRunOutput` still reads
  the real Bash script's real stdout, completely unchanged — **zero risk to the existing
  thumbnail-review dialog from this port landing.** For Phase 2, this module deliberately
  follows `restore_from_trash.dart`'s precedent rather than `06`'s own stdout format:
  `DuplicateDeleter.run` returns structured `DuplicateReportOutcome` objects (keep path + typed
  per-file outcomes), not printed text. A helper, `renderDryRunKeepTrashLines`, renders those
  structured outcomes into the exact `Keep: `/`Would trash: ` line format
  `duplicate_report.dart` parses today — proven equivalent by a round-trip test — so Phase 2
  can choose either to keep `duplicate_report.dart` as a thin compatibility parser over that
  rendered text, or have the review UI consume `DuplicateReportOutcome` directly and retire the
  text parser. That choice is deliberately deferred to the wiring PR, which can update the
  review dialog's tests end-to-end at the same time; deciding it here would mean touching
  `duplicate_report.dart`/`media_pipeline_app.dart` without the process wiring that would
  actually exercise the new path — a half-migrated state this task was explicitly warned
  against.
- **Trash-move collision-handling deviation (intentional, documented):** the Bash script's own
  `trash_file()` resolves a destination collision with a numbered suffix (`_1`, `_2`, ...) and
  always moves. This port instead uses `SafeFileMover.moveNoClobber`, which skips the move and
  leaves the source in place on collision (`mv -n` semantics), matching `filesystem_ops.dart`'s
  own doc comment, which already named 06/12/13 as the intended next callers of this shared
  primitive. This is a deliberate, safety-neutral-or-safer behavioral difference (never invents
  a slightly-different destination filename) and does not affect the keep/trash *decision*
  logic itself, which the parity test below verifies byte-for-byte.
**Verification:** `test/delete_duplicates_test.dart` (29 tests): `scoreKeepPath` exact score
values and ordering; adversarial parsing tests matching the rigor of
`tests/test_shell_scripts.py`'s Bash coverage (report headers, dimension lines, size
annotations, and out-of-staging quoted paths are never misread as paths); `DuplicateDeleter`
dry-run/confirm/missing-file/no-clobber behavior; a `renderDryRunKeepTrashLines` <->
`parseDuplicateDryRunOutput` round-trip test proving format compatibility. Highest-value test:
a **Bash-vs-Dart parity test** that runs the real `scripts/06_delete_duplicates.sh` (via
`Process.run`) against a synthetic Czkawka report fixture (containing a header line, a
dimension-like line, an out-of-staging quoted path, and a real duplicate group with real files
on disk) and asserts its `Keep:`/`Would trash:` lines match `decideCzkawkaReportGroups`'
independently computed decision exactly. `flutter analyze`: no issues. `flutter test`: 181/181
passing (29 new). `scripts/06_delete_duplicates.sh` itself is untouched — additive only, remains
the working fallback.
**Pivots:** None from the original plan; the integration-decision and collision-handling
deviations above were both anticipated design questions, resolved deliberately rather than
defaulted into.
**Outcome:** `lib/src/delete_duplicates.dart` is a parity-tested, standalone Dart port of
`06_delete_duplicates.sh`'s decision logic, ready for Phase 2 wiring. PR flags Cody + Astrid
review as **required** (not just warranted) given this is the highest-stakes port in the
series. Part of #76 and #77; not closing either — 12/13 and Phase 0c/0d remain, and Phase 2
wiring (replacing the Bash subprocess calls in `pipeline_models.dart`) is still future work.

## Phase 0b (continued) — Dart port of `12_clean_immich_takeout_duplicates.sh` (2026-07-14)

**Context:** Third of the four confirm-gated destructive scripts in issue #76/#77's Phase 0b
(after `11_restore_from_trash.sh`, PR #82, and `06_delete_duplicates.sh`, PR #86). This script
finds Google Takeout localized year-folder duplicates (`Fotos de YYYY/*`) that match a
canonical `YYYY/*` file by basename, size, AND SHA-256 hash, and moves verified duplicates to
`media_trash`.
**Decisions:**
- Added `lib/src/clean_takeout_duplicates.dart`: `matchLocalizedYearFolderName` (pure
  `Fotos de YYYY` directory-name match), `verifyTakeoutDuplicateCandidate` (the three-way
  basename+size+hash verification, with every filesystem access injectable via `FileSizer`/
  `FileHasher`/`PathExistsChecker` so the decision branching is directly unit-testable without
  real files), and `TakeoutDuplicateCleaner.run` (the async orchestration walking `Fotos de
  YYYY`/`YYYY` directory pairs and delegating the actual move to the shared `SafeFileMover`).
  Same "port the logic, defer the wiring" pattern as the two prior ports: `pipeline_models.dart`
  / `media_pipeline_app.dart` are untouched, and the actual executed pipeline step still shells
  out to the real `scripts/12_clean_immich_takeout_duplicates.sh`.
- **Hashing without a new dependency:** `defaultFileHasher` shells out to the real `sha256sum`
  binary (matching `pipeline_models.dart`'s existing `requiredTools: ['sha256sum']` declaration
  for this step) rather than adding a `crypto` package dependency to `pubspec.yaml`.
- **Typed confirmation phrase:** unlike `06`/`11`, this script also gates confirm mode on typing
  the exact phrase `"MOVE TAKEOUT DUPLICATES"` at an interactive prompt. Since this port isn't
  wired into the app yet, the real Bash script still owns that interactive prompt; this port
  adds `kTakeoutDuplicatesConfirmPhrase`/`isTakeoutDuplicatesConfirmationPhraseValid` so the
  phrase itself is already ported, named, and unit-tested ahead of Phase 2 wiring, while
  `TakeoutDuplicateCleaner.run` still takes a plain `confirm` bool, matching
  `TrashRestorer.run`/`DuplicateDeleter.run`'s precedent exactly.
- **Trash-move collision-handling deviation (intentional, documented, same as PR #86):** the
  Bash script's own `unique_destination` resolves a destination collision with a numbered
  suffix (`_1`, `_2`, ...) and always moves. This port instead uses
  `SafeFileMover.moveNoClobber`, which skips the move and leaves the source in place on
  collision (`mv -n` semantics). Deliberate, safety-neutral-or-safer, and does not affect the
  verify/skip decision logic the parity test verifies.
**Verification:** `test/clean_takeout_duplicates_test.dart` (27 tests): `matchLocalizedYearFolderName`
exact-match/case-sensitivity tests; confirmation-phrase validity tests; `verifyTakeoutDuplicateCandidate`
tests proving the three-way check short-circuits on size mismatch before ever hashing, and is never
satisfied by a size-only match; `TakeoutDuplicateCleaner` dry-run/confirm/no-clobber/missing-canonical-file/
missing-canonical-year-folder/spaces-and-unicode behavior. Highest-value test: a **Bash-vs-Dart parity
test** that runs the real `scripts/12_clean_immich_takeout_duplicates.sh` (via `Process.run`) against a
synthetic fixture with four candidates — a genuine verified duplicate, a **size-mismatch** case, a
**hash-mismatch-despite-matching-size** case (the adversarial case proving the three-way check isn't
weakened to size-only), and a missing-canonical-file case — and asserts identical
verified/size-mismatch/hash-mismatch/missing-canonical decisions and identical `Candidates
inspected`/`Verified duplicates` counters between the two implementations. `flutter analyze`: no
issues. `flutter test`: 208/208 passing (27 new). `scripts/12_clean_immich_takeout_duplicates.sh` itself
is untouched — additive only, remains the working fallback.
**Pivots:** None from the original plan; the hashing-dependency and confirm-phrase design questions
were both anticipated and resolved deliberately rather than defaulted into.
**Outcome:** `lib/src/clean_takeout_duplicates.dart` is a parity-tested, standalone Dart port of
`12_clean_immich_takeout_duplicates.sh`'s decision logic, ready for Phase 2 wiring. PR flags Cody +
Astrid review as required, matching the rigor of the prior two ports in this series. Part of #76 and
#77; not closing either — `13_dedupe_live_photos.sh` and Phase 0c/0d remain, and Phase 2 wiring is
still future work.

## Phase 0b (concluded) — Dart port of `13_dedupe_live_photos.sh` (2026-07-14)

**Context:** Fourth and FINAL confirm-gated destructive script in issue #76/#77's Phase 0b (after
`11_restore_from_trash.sh` PR #82, `06_delete_duplicates.sh` PR #86, and
`12_clean_immich_takeout_duplicates.sh` PR #87). This script finds Apple Live Photo still+video
pairs that Google Takeout split apart (same directory + basename), verifies the video's duration
via `ffprobe` (`<=5s`), falling back to file-mtime proximity (`<=5s` apart) only when `ffprobe`
can't report a duration at all, and moves the redundant video to `media_trash`, keeping the still
untouched.
**Decisions:**
- Added `lib/src/dedupe_live_photos.dart`: `pairStillsAndVideos` (pure same-directory/same-basename
  still+video pairing, mirroring `process_directory`'s associative-array bookkeeping exactly, never
  matching across directories), `evaluateVideoDuration` (pure numeric-duration regex/threshold
  check, mirroring Bash's `^[0-9]+(\.[0-9]+)?$` regex exactly rather than a general float parser),
  `evaluateLivePhotoPair` (the pure `evaluate_pair` priority-order port — duration first, timestamp
  fallback only when duration is unknown — with zero filesystem/subprocess dependency), and
  `LivePhotoDedupeCleaner.run` (the async orchestration walking every directory under the target,
  shelling out to `ffprobe` via an overridable `VideoDurationReader` seam mirroring Bash's own
  `$FFPROBE_BIN` override, and delegating the actual move to the shared `SafeFileMover`). Same
  "port the logic, defer the wiring" pattern as the three prior ports: `pipeline_models.dart` /
  `media_pipeline_app.dart` are untouched, and the actual executed pipeline step still shells out to
  the real `scripts/13_dedupe_live_photos.sh`.
- **Non-negotiable priority order preserved exactly:** a known-too-long duration
  (`DurationVerification.tooLong`) is a terminal rejection inside `evaluateLivePhotoPair` — it
  returns immediately without ever consulting the still/video mtimes, so a known-too-long duration
  can never be overridden by the timestamp-proximity fallback, matching the original Bash script's
  own explicit design decision (reviewed on issue #60 / PR #61). A dedicated regression test asserts
  this holds even when the two files' mtimes are identical.
- **Typed confirmation phrase:** like `12`, this script gates confirm mode on typing the exact
  phrase `"MOVE LIVE PHOTO VIDEOS"`. `kLivePhotoDedupeConfirmPhrase`/
  `isLivePhotoDedupeConfirmationPhraseValid` are ported and unit-tested ahead of Phase 2 wiring;
  `LivePhotoDedupeCleaner.run` still takes a plain `confirm` bool, matching the series' precedent.
- **Trash-move collision-handling deviation (intentional, documented, same as PRs #86/#87):** this
  port uses `SafeFileMover.moveNoClobber` (skip-on-collision) rather than the Bash script's own
  `unique_destination` numbered-suffix scheme. Deliberate, safety-neutral-or-safer, and does not
  affect the verify/skip decision logic the parity test verifies.
- **Explicit non-goal preserved:** this port never attempts to re-link the still+video pair as a
  single Immich "Live Photo" asset via metadata (`QuickTime:ContentIdentifier` etc). It only decides
  which video is redundant and moves it — the still is always left as a plain photo, matching the
  original script's own out-of-scope boundary from #60.
**Verification:** `test/dedupe_live_photos_test.dart` (33 tests): `pairStillsAndVideos`
same-directory-only pairing/case-insensitivity/no-extension/no-paired-still tests;
`evaluateVideoDuration` boundary and Bash-regex-rejection-form tests (negative, exponent, leading
dot); `evaluateLivePhotoPair` tests including the safety-critical "known-too-long duration wins even
when timestamps are identical" regression guard; `LivePhotoDedupeCleaner` dry-run/confirm/
no-clobber/missing-still/cross-directory-non-matching/spaces-and-unicode behavior. Highest-value
test: a **Bash-vs-Dart parity test** that runs the real `scripts/13_dedupe_live_photos.sh` (via
`Process.run`, with `FFPROBE_BIN` pointed at the same fake-ffprobe stub protocol
`tests/test_shell_scripts.py`'s own `write_fake_ffprobe` uses) against a synthetic fixture covering
all five required scenarios — a valid short-duration pair, an over-duration video (rejected), a
missing-still case (skipped), a duration-unknown pair within timestamp proximity (fallback accepts),
and a duration-unknown pair NOT within proximity (fallback rejects) — and asserts identical
per-video decisions and identical `Candidates inspected`/`Verified pairs`/`Missing paired
still`/`Video too long`/`Duration unknown (total)`/`Skipped, ambiguous match` counters between the
two implementations. `flutter analyze`: no issues. `flutter test`: 241/241 passing (33 new).
`scripts/13_dedupe_live_photos.sh` itself is untouched — additive only, remains the working
fallback.
**Pivots:** None from the original plan.
**Outcome:** `lib/src/dedupe_live_photos.dart` is a parity-tested, standalone Dart port of
`13_dedupe_live_photos.sh`'s decision logic, ready for Phase 2 wiring. PR flags Cody + Astrid review
as required, matching the rigor of the prior three ports in this series. **This completes Phase 0b
of issue #76/#77: all four confirm-gated destructive scripts (`11_restore_from_trash.sh`,
`06_delete_duplicates.sh`, `12_clean_immich_takeout_duplicates.sh`, and
`13_dedupe_live_photos.sh`) are now ported to Dart, each logic-only/unwired with its own real
Bash-vs-Dart parity test.** Part of #76 and #77; not closing either — next up is Phase 0c (decide
the fate of `04_stitch_metadata.py`: keep as an external Python dependency vs. port to Dart) or,
alternatively, the actual app-wiring phase (Phase 2: replacing the Bash subprocess calls in
`pipeline_models.dart`/`media_pipeline_app.dart` with these Dart implementations).

## Phase 0c (concluded) — Dart port of `04_stitch_metadata.py`, completing shared Phase 0 (2026-07-15)

**Context:** Leo decided Phase 0c (port `04_stitch_metadata.py` to Dart rather than keep it as an
external Python dependency), the last open decision point in issue #76/#77's shared Phase 0 roadmap.
Unlike the four Phase 0b scripts, this one has no confirm-gate/typed-phrase and never touches
`media_trash` — it extracts Google Takeout archives, matches each media file to its Google Photos
JSON sidecar, applies that metadata with `exiftool`, and moves every media file (whether or not
metadata could be applied) into `cleaning_staging`. Still safety-relevant: it decides what data and
metadata actually end up in `cleaning_staging` in the first place, and this repo's Python hard rule
for this exact script ("continue past individual corrupt media files, log warnings clearly") had to
be preserved as this port's own hard rule.
**Decisions:**
- Added `lib/src/stitch_metadata.dart`: `candidateJsonsForMedia` (the exact sidecar-matching
  heuristic — exact name, stem, `.supplemental-metadata.json` variants, then two 45-character
  truncated-name glob-equivalent scans, de-duplicated preserving first-seen order), `extractTimestamp`
  (Google's `photoTakenTime`/`creationTime` epoch-to-`exiftool`-format conversion),
  `applyMetadataWithExiftool` (builds the same date/title/description/GPS argument list and shells
  out via an overridable `ExiftoolRunner`, mirroring `dedupe_live_photos.dart`'s `FFPROBE_BIN`-style
  seam), `TakeoutArchiveExtractor` (list-then-validate-then-extract, reproducing
  `safe_extract_zip`/`safe_extract_tar`'s path-traversal guard against every archive member before
  extracting anything), `moveToStaging` (the numbered-suffix collision handling, reusing
  `SafeFileMover.moveNoClobber` for the actual byte-safe move once a free name is chosen), and
  `MetadataStitcher.run` (the full orchestration mirroring `main()`'s per-archive try/catch: a
  corrupt/unsafe *archive* aborts the run and is kept for retry, but a corrupt/unmatched *media file*
  inside an otherwise-good archive never aborts anything — the same two-tier safety model the real
  script uses). Not wired into `pipeline_models.dart`/`media_pipeline_app.dart` — same "port the
  logic, defer the wiring" pattern as every Phase 0b port before it; the real pipeline step still
  shells out to `scripts/04_stitch_metadata.py`, which is completely untouched.
- **Archive extraction shells out to `unzip`/`tar` rather than adding a pub.dev archive package:**
  this repo's `pubspec.yaml` has no archive-handling dependency (only
  `flutter`/`flutter_test`/`flutter_lints`), and every other external-tool integration in this
  codebase (`exiftool`, `ffprobe`, `rclone`, `czkawka_cli`) already shells out via `Process.run` with
  an overridable binary name rather than pulling in a pure-Dart decoder. Shelling out to `unzip -Z1`/
  `tar -tzf` for listing (validated against `isPathTraversalSafe` before anything is extracted) and
  `unzip -o -d`/`tar -xzf -C` for the actual extraction keeps this port consistent with that
  precedent instead of introducing the only pure-Dart archive dependency in the app.
- **Preserved a byte-for-byte quirk rather than silently fixing it:** the real Python
  `apply_metadata_with_exiftool` builds `args = ["exiftool", "-overwrite_original"]` (length 2) and
  skips exiftool entirely `if len(args) == 3` — i.e. only when *exactly one* single-flag tag
  (`-Title=` or `-Description=`, with no date and no GPS) was queued. This reads as an off-by-one bug
  (the true "no tags at all" case is `len(args) == 2` and, read literally, actually still invokes
  exiftool with just `-overwrite_original` plus the file path). `applyMetadataWithExiftool` preserves
  this exact behavior, including the zero-tag case still invoking exiftool — ported for parity, not
  fixed, with the quirk documented in the module doc comment and flagged in the PR for Cody/Astrid to
  weigh in on whether a follow-up fix issue against the Python script is warranted.
- **`moveToStaging` deliberately does not use `SafeFileMover.moveNoClobber`'s skip-on-collision
  behavior directly:** every Phase 0b port relies on that skip-on-collision semantics because those
  scripts have a dry-run/confirm split with a human reviewing a report first. This script has no such
  split — it always moves every file it finds, resolving a same-basename collision with a numbered
  suffix (`photo_1.jpg`, `photo_2.jpg`, ...) instead, exactly matching
  `tests/test_stitch_metadata.py::test_move_to_staging_renames_colliding_media`. `SafeFileMover` is
  still reused for the actual move once a free destination name is chosen, for its cross-device
  (`EXDEV`) fallback and copy-verify-then-delete safety net.
**Verification:** `test/stitch_metadata_test.dart` (37 tests): unit coverage for `archiveStem`,
`isMediaExtension`, `isSupportedArchiveFileName`, `extractTimestamp`, `isPathTraversalSafe`,
`candidateJsonsForMedia` (against real tmp-dir fixtures, mirroring the Python test suite's own
exact/supplemental/truncated-match case), `applyMetadataWithExiftool` (including the preserved
`len(args)==3` quirk and its zero-tag counterpart), `TakeoutArchiveExtractor` (blocks extraction on
any unsafe member before the extractor is ever invoked), `moveToStaging` (direct parity with the
Python collision-rename test), `processExtractedTree`, and `MetadataStitcher.run` end-to-end against
a real zip archive built via the `zip` CLI and extracted via the real `unzip`/`tar` binaries. Highest
-value test: a real **Python-vs-Dart parity test** that builds an identical fixture for both sides
(a clean match with a matching JSON sidecar, a missing-sidecar file, and a corrupt file that makes a
fake `exiftool` stand-in exit non-zero), runs the real `scripts/04_stitch_metadata.py` via
`Process.run` (the fake `exiftool` prepended onto `PATH`, since the Python script hard-codes the
literal command name with no env-var override unlike the Bash scripts' `FFPROBE_BIN` convention),
runs `MetadataStitcher` against a second identical fixture with the same fake `exiftool` binary
injected via its overridable `ExiftoolRunner`, and asserts both report the same
processed/warning counts (3 media moved, 2 warnings) and move the same three files into
`cleaning_staging`. `flutter analyze`: no issues. `flutter test`: 278/278 passing (37 new).
`python3 -m unittest tests.test_stitch_metadata`: 4/4 passing (untouched). `ruff check scripts`: all
checks passed. `scripts/04_stitch_metadata.py` and `config/pipeline_config.py` are both untouched —
additive only, matching every prior port's isolation.
**Pivots:** None from the original plan; the work fit in one PR with clearly separated commits
(logic port, then tests, then this history entry) rather than needing a multi-PR split.
**Outcome:** `lib/src/stitch_metadata.dart` is a parity-tested, standalone Dart port of
`04_stitch_metadata.py`'s decision logic, ready for Phase 2 wiring. PR flags Cody + Astrid review as
required, matching the rigor of every prior port in this series. **This completes Phase 0c, and
therefore ALL of issue #76/#77's shared Phase 0: drive detection (0a, PR #79) + all four
confirm-gated destructive scripts (0b, PRs #82/#86/#87/#88) + metadata stitching (0c, this PR) are
now all ported to Dart, each logic-only/unwired with its own real Bash-or-Python-vs-Dart parity
test.** Part of #76 and #77; not closing either — next up is Phase 1 wiring differs by design: #76
still needs Phase 2 (wire this whole series into the tools-container execution path) and Phases 3-7;
#77 (Design B, native runtime) branches from this same shared Phase 0 into its own installer-based
next steps.
## Phase 19 — `SafeFileMover` collision-rename fix: match Bash's `unique_destination()` exactly (2026-07-15)

**Context:** Phase 0b's four Dart ports (`11`/`06`/`12`/`13`, PRs #82/#86/#87/#88) each carried a
documented deviation from Bash: `SafeFileMover.moveNoClobber` always skips on a destination
collision (`mv -n` semantics), while `06_delete_duplicates.sh`, `12_clean_immich_takeout_duplicates.sh`,
and `13_dedupe_live_photos.sh` each carry an identical inline `unique_destination()` algorithm that
instead resolves a collision with a numbered suffix (`_1`, `_2`, ...) and always moves. Leo reviewed
this deviation (flagged across those PRs) and decided: match Bash's real behavior exactly, per real
script — not one uniform Dart-only policy. Investigating the real Bash scripts closely surfaced a
nuance the original framing missed: `11_restore_from_trash.sh` is a literal `mv -n` with no
`unique_destination` logic at all, so that port's existing skip-on-collision behavior was already
correct and did not need to change.
**Decisions:**
- Added `uniqueDestinationPath(desiredPath, exists)` to `lib/src/filesystem_ops.dart`: a pure,
  synchronous, zero-I/O port of Bash's `unique_destination()`, verified against real `bash` runs
  (not hand-derived) for every edge case, including two intentionally-reproduced Bash quirks: the
  split point is the *last* `.` in the **full path string** (not the basename — a dot in a
  *directory* component wins over a dot-less filename, e.g. `/a/b.c/photo` splits at `b.c`, not at
  `photo`), and a leading-dot dotfile (`.bashrc`) still counts as "having a dot." No upper retry
  bound, matching Bash's own unbounded `while true` loop.
- Split `SafeFileMover`'s single collision behavior into two named methods rather than changing
  `moveNoClobber` in place: `moveNoClobber` (unchanged — `mv -n`/skip, matches
  `11_restore_from_trash.sh`'s real behavior) and the new `moveRenamingOnCollision` (Bash
  `unique_destination()` semantics — resolves via `uniqueDestinationPath` and always moves, never
  skips, returning a `MoveOutcome` carrying the actual destination path used). `restore_from_trash.dart`
  needed zero changes as a result.
- `delete_duplicates.dart`, `clean_takeout_duplicates.dart`, and `dedupe_live_photos.dart` switched
  their `SafeFileMover` calls from `moveNoClobber` to `moveRenamingOnCollision`; each file's
  `*Action` enum's `skippedExisting` value was replaced with a `trashedWithSuffix`/`movedWithSuffix`
  equivalent, and each outcome's `destinationPath` now reflects the actual (possibly suffixed) path
  used rather than the originally-requested one. The keep/trash and verify/reject *decision* logic
  in all three files is unchanged; only what happens after a collision is detected changed.
**No-clobber semantics change:** for `06`/`12`/`13`, a trash-bound move is never left un-moved on
collision — either it lands at the requested destination or a numbered-suffix alternative, matching
Bash's guarantee that a move into `$MEDIA_TRASH` always succeeds. `11_restore_from_trash.sh`'s
skip-on-collision guarantee (an unresolved trash item stays in the trash rather than colliding with
a real file at the restore destination) is unchanged.
**Verification:** `test/filesystem_ops_test.dart` adds a `uniqueDestinationPath` Bash-parity group
(every expected value captured from real `bash` runs against a dot-free temp directory: no
collision, single collision, dotfile, no-extension, multi-dot, trailing-dot, the directory-dot
quirk, and unbounded-retry) and a `moveRenamingOnCollision` group (no-collision, single-collision,
repeated-collision). `test/delete_duplicates_test.dart`, `test/clean_takeout_duplicates_test.dart`,
and `test/dedupe_live_photos_test.dart`'s former "never clobbers (mv -n semantics)" tests were
rewritten to assert the new rename-on-collision behavior instead of being deleted.
`test/restore_from_trash_test.dart` required no changes — its skip-on-collision tests still describe
real, current behavior. `flutter analyze`: no issues. `flutter test`: full suite green (one
pre-existing, unrelated flake in `pipeline_runner_test.dart`'s stdout/stderr-separation test under
full-suite parallel load, confirmed pre-existing and passing in isolation both before and after this
change).
**Pivots:** The task brief described the pre-existing behavior as a uniform deviation across all
four ports; direct inspection of `11_restore_from_trash.sh`'s real Bash source showed it was not
actually deviating (`mv -n`, no `unique_destination`), so that port's collision behavior was
deliberately left unchanged rather than forced into the rename scheme, to avoid introducing a new
deviation where none existed.
**Outcome:** `SafeFileMover` now offers two collision strategies, each matching its real Bash
counterpart exactly; `06`/`12`/`13`'s trash moves can no longer silently strand a file un-moved.
Part of #76 and #77; not closing either. PR flags Cody + Astrid review as required — this changes
safety-critical move behavior across three of the four already-reviewed Phase 0b ports.

## Phase 20 — Container-orchestration plumbing: `ToolsContainer`, start of #76 Phase 2 (2026-07-15)

**Context:** Shared Phase 0 (drive detection + all four confirm-gated destructive scripts +
metadata stitching) and Phase 1 (the `media-pipeline-tools` Docker image, PR #80) are both
complete. This is the first PR of Phase 2 — "wire Dart orchestration to the container" — and is
scoped to infrastructure only, per this issue's own phase breakdown: build the plumbing that
manages a long-lived tools container and execs commands into it, without yet rewiring any of the
five existing ported logic modules (`drive_detection.dart`, `delete_duplicates.dart`,
`clean_takeout_duplicates.dart`, `dedupe_live_photos.dart`, `stitch_metadata.dart`) to use it.
Each of those still shells out to the host binary directly via its own existing overridable seam
(`exiftoolRunner`, the `$FFPROBE_BIN`-style override, `sha256sum`, etc.) — that consumer wiring is
deferred to subsequent Phase 2 PRs, one consumer at a time, matching how Phase 0b ported one
script at a time.

**Added:** `lib/src/tools_container.dart`'s `ToolsContainer` class:
- **Start:** `docker run -d --rm --init --label media-pipeline.tools-session=<id> -v
  <hostMountRoot>:<containerMountPath> <image> sleep infinity`. `docker/tools/Dockerfile`'s own
  `CMD` (`["bash"]`, no `ENTRYPOINT`) would exit immediately under a detached, non-TTY `docker
  run` — rather than modify the Dockerfile (Phase 1 already shipped, reused unmodified here),
  `start()` overrides the container's command at the `docker run` invocation itself, a standard,
  supported Docker idiom for a long-lived exec target. `--init` was added after test development
  surfaced a real bug (see "Pivots" below).
- **Exec:** `docker exec <container-id> <args...>`, returning the real `ProcessResult` `docker
  exec` produced — the same shape `Process.run` returns, so a later consumer-wiring PR can swap a
  direct `Process.run(tool, args)` host call for `container.exec([tool, ...args])` with no shape
  change at the call site.
- **Stop:** `docker stop <id>` then an explicit `docker rm -f <id>` (see "Pivots" below for why
  `--rm`'s automatic daemon-side removal alone wasn't relied on). Idempotent and never throws on
  a failed underlying `docker` call — a container that's already gone is the success case.
  `ToolsContainer.withSession()` wraps `start`/`stop` in a `try`/`finally` so a thrown exception
  from the caller's own callback can never skip cleanup; every started container also carries a
  `media-pipeline.tools-session` label so any orphan left behind by an uncatchable `SIGKILL` (the
  one leak path no userspace process can close) can still be found and reaped independently.
- **Path translation:** `hostToContainerPath`/`containerToHostPath` — a pure prefix-rewrite
  between a host absolute path under `hostMountRoot` and its container-side path under
  `containerMountPath` (`/data` by default), and the reverse. Per this repo's Safety Rules, a
  path outside the mounted root — including one that merely shares the root as a *string* prefix
  without a real `/`-boundary (e.g. `/mnt/target_drive2/...` against a root of
  `/mnt/target_drive`) — throws `ArgumentError` rather than being silently mistranslated.
  `containerToHostPath` is provided as symmetric plumbing (documented as not yet needed by any
  wired consumer) for a later PR that needs to translate a tool's own path-echoing error output
  back to a host path for a user-facing message.

**Windows-style host paths and Docker Desktop's different bind-mount syntax are explicitly out of
scope for this PR** — that's Phase 4/5 of this issue (macOS/Windows end-to-end verification),
which this repo's own real-machine test precedent (`test/drive_detection_test.dart`'s
`Platform.isLinux`-gated group) already treats as separate, platform-gated work; this PR's own
Docker-backed tests are gated the same way.

**Verification:** `test/tools_container_test.dart` — pure path-translation unit tests (round-trip,
spaces, non-English characters, the outside-root and string-prefix-collision rejection cases);
fake-docker-runner lifecycle tests exercising exact `docker run`/`exec`/`stop` argument shapes and
every error path (non-zero exit, empty container ID, double-start, exec-before-start, idempotent
stop, `withSession`'s cleanup-on-throw guarantee) without needing a real Docker daemon; and a
real-Docker group, gated on a synchronous `docker version` + `docker image inspect
media-pipeline-tools:local` availability check (mirroring `drive_detection_test.dart`'s
`Platform.isLinux` skip pattern) so a CI run without Docker visibly skips rather than silently
passing. Docker was available in this environment (the `media-pipeline-tools:local` image built
locally from `docker/tools/Dockerfile` per its own README), so the real-Docker group actually ran:
`exiftool -ver` inside the container returned `12.57`, matching the pinned version in
`docker/tools/README.md`; the container was confirmed actually running via a real `docker inspect`
call after `start()` and actually gone after `stop()`; a file written on the host was read back
through its translated container path via a real `docker exec cat`; and `exec()` into an
out-of-band-killed container failed rather than silently succeeding. A `docker ps -a --filter
label=media-pipeline.tools-session` check after the full suite confirmed zero leaked containers.
`flutter analyze`: no issues. `flutter test`: full suite green (323 tests).

**Pivots:** Writing the "container is actually gone after `stop()`" real-Docker test caught a real
bug before it shipped: `sleep infinity` run as a container's PID 1 with no init/shell wrapper gets
Linux's special PID-1 signal semantics, where a signal with no explicitly installed handler is
*dropped* rather than getting its normal default action — so `docker stop`'s SIGTERM was silently
falling through to the full ~10s grace-period timeout before SIGKILL on every single call
(confirmed by timing: real-Docker tests initially took ~40s total), and even after that, the
`--rm`-triggered removal raced with a `docker inspect` issued immediately after `stop()` returned
often enough to fail the test outright. Fixed by adding `--init` to `docker run` (a minimal init
that correctly forwards SIGTERM to `sleep infinity` with normal, non-PID-1 semantics) and having
`stop()` issue an explicit, synchronous `docker rm -f` rather than relying solely on `--rm`'s
asynchronous daemon-side cleanup — real-Docker test time dropped to ~1s total after the fix, with
no further flakiness across repeated runs.

**Outcome:** The container-orchestration plumbing this issue's Phase 2 needs now exists,
independently verified against a real Docker daemon and container, but nothing in `lib/**`
consumes it yet. Part of #76, not closing it — this issue stays open until the remaining Phase 2
consumer-wiring PRs and Phases 3-7 land. PR flags **Cody + Astrid** review as required: this is new
infrastructure everything else in #76's Design A will eventually route real personal-media
operations through, even though this PR itself touches no destructive path.

## Phase 21 — First real consumer migration: dedupe-live-photos routes `ffprobe` through `ToolsContainer` (2026-07-15)

**Context:** #76 Phase 2 (container wiring) has plumbing (`ToolsContainer`, PR #93) but no real
consumer yet. `lib/src/dedupe_live_photos.dart` (Phase 0b port, PR #88) was picked as the first
migration: one external tool (`ffprobe`), no archive/multi-file complexity, and its own
Bash-vs-Dart parity test already isolates the decision logic from the invocation mechanism.

**Decisions:**
- Added `containerFfprobeDurationReader({required ToolsContainer container, String ffprobeBin})`
  — the sanctioned production `VideoDurationReader`: translates the host video path via
  `ToolsContainer.hostToContainerPath` before every `container.exec(['ffprobe', ...])` call, same
  success/failure mapping as the host-based reader (non-zero exit or empty stdout -> `null`).
- **Hard cutover, not a fallback pair.** `LivePhotoDedupeCleaner.durationReader` is now a
  *required* constructor parameter — the implicit `?? ffprobeDurationReader()` host-`Process.run`
  default was removed. This repo's target users already run Docker (a hard requirement for
  Immich itself), so there's no real deployment scenario needing a silent host fallback; a
  fallback default would only invite an accidental bypass of the container path (and its
  path-traversal-safe boundary check) by omission. `ffprobeDurationReader` (host) is kept, but
  only as a lower-ceremony way for a test to exercise the decision logic without a container —
  it is no longer reachable by omission.
- **Parity test decoupled from the invocation mechanism.** Before this change, the parity test's
  Dart side called `ffprobeDurationReader(ffprobeBin: fakeFfprobe.path)` — exercising the *host*
  `Process.run` seam against a fake binary. Standing up a real container with a stubbed `ffprobe`
  baked into the pinned image just for this one test would have been high-ceremony for a test
  whose actual job is `evaluate_pair` decision-logic parity, not container-exec mechanics.
  Instead, `test/dedupe_live_photos_test.dart` now has a small Dart-native
  `_fakeDurationReaderFromMarkerFile` that replicates the same marker-file protocol
  (`DURATION=<n>` / `UNKNOWN`) directly, with zero process/container involvement — the Bash-vs-Dart
  comparison stays meaningful (identical fixtures, identical protocol) while staying decoupled
  from *how* the real production seam fetches the duration string.
- **Real end-to-end coverage added separately.** A new Docker-gated test group
  ("ffprobe via a real ToolsContainer") starts a real `ToolsContainer`, uses the pinned image's
  own `ffmpeg` to generate a genuine 2-second synthetic video onto the bind-mounted host
  directory (rather than a checked-in fixture), then calls `containerFfprobeDurationReader` with
  the *host* path and confirms the full path — host path -> container path translation -> real
  `ffprobe` exec -> `evaluateVideoDuration` parsing it as `verified` — genuinely works. A second
  case confirms a missing file maps to `null`. Both skip gracefully (matching
  `test/tools_container_test.dart`'s pattern) when Docker/the image aren't available.

**Preserved unchanged:** the duration-then-timestamp-fallback priority order, the `<=5s`
threshold, and the safety-critical "a known-too-long duration must never fall through to the
timestamp fallback" regression test — none of `evaluate_pair`'s decision logic changed, only how
`ffprobe`'s raw output gets fetched.

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green (331 tests),
including the new real-container tests, which actually ran (Docker + `media-pipeline-tools:local`
were available in this environment) rather than skipping.

**Pivots:** The real-container test initially failed with `Permission denied` writing the
synthetic video into the bind-mounted temp directory — the image runs as a fixed non-root UID
(`tools`, uid 10000; `docker/tools/Dockerfile`) that doesn't match the host test-runner's UID.
Real UID/GID mapping is explicitly future work (#76 Phase 3); as a test-only workaround, the
fixture temp directory is `chmod 0777`'d before the container starts, scoped to this test's own
fixture and touching nothing in `lib/`/`docker/`.

**Outcome:** `dedupe_live_photos.dart` now has a sanctioned, container-routed production path for
`ffprobe`, proven against a real Docker daemon end-to-end. Still not wired into
`pipeline_models.dart`/`media_pipeline_app.dart` — that remains later work. Sets the pattern
(container-exec seam + parity test decoupled from invocation mechanism + real Docker-gated e2e
test) for the remaining Phase 2 consumer migrations (`stitch_metadata.dart`,
`clean_takeout_duplicates.dart`, `drive_detection.dart`, `delete_duplicates.dart`). Part of #76,
not closing it. Flagging **Cody + Astrid** review as required — first real consumer migration,
sets the pattern for the rest.

## Phase 22 — Third consumer migration: stitch-metadata routes `unzip`/`tar`/`exiftool` through `ToolsContainer` (2026-07-15)

**Context:** Following Phase 21's `ffprobe` migration for `dedupe_live_photos.dart`,
`lib/src/stitch_metadata.dart` (Phase 0c port, PR #89) is the third #76 Phase 2 consumer
migration and the hardest so far: THREE external tools (`unzip`/`tar` for archive extraction via
`TakeoutArchiveExtractor`, `exiftool` for metadata application), and archive extraction has real
filesystem side effects (many files written to disk) rather than a single parseable return value.
It also composes two independent path-safety mechanisms — `isPathTraversalSafe` (validates
archive *member* names against the extraction destination) and
`ToolsContainer.hostToContainerPath` (validates the extraction destination itself against the
bind-mount boundary) — that both need to hold without one weakening the other.

**Decisions:**
- **Archive extraction routes through the container, extracting onto the bind mount.**
  `containerZipLister`/`containerZipExtractor`/`containerTarLister`/`containerTarExtractor`
  (bundled by `containerTakeoutArchiveExtractor`) translate every host path (archive path,
  extraction destDir) via `ToolsContainer.hostToContainerPath` before exec'ing `unzip`/`tar`
  inside the container. `extractArchive` still creates the extraction destDir on the *host*
  filesystem before extraction runs (unchanged) — since that destDir lives under
  `$HD_PATH/takeout_extracted` and callers construct their `ToolsContainer` with `hostMountRoot`
  set to (an ancestor of) `$HD_PATH`, it's always inside the bind mount, and because a bind mount
  is the same underlying filesystem on both sides, the host sees every file the container writes
  the instant `docker exec` returns — no explicit sync step needed. Verified for real (not just
  asserted) by this PR's Docker-gated end-to-end test.
- **`exiftool` routes through the container, same pattern as `ffprobe`.**
  `containerExiftoolRunner({required ToolsContainer container})` translates the target media
  path — always `applyMetadataWithExiftool`'s trailing argument — via
  `ToolsContainer.hostToContainerPath` before `container.exec(['exiftool', ...])`. The JSON
  sidecar itself is read directly by Dart, never passed to `exiftool`, so no other argument needs
  translation.
- **How the two path-safety mechanisms compose (the key design call in this PR).**
  `isPathTraversalSafe` runs entirely on host-domain paths, inside `TakeoutArchiveExtractor.extract`,
  *before* the container-routed lister/extractor is ever invoked — it has no awareness a
  container is even involved, and it can throw (blocking the entire archive) without any exec
  ever happening. Separately, `ToolsContainer.hostToContainerPath` validates that the extraction
  destDir (and the archive path) fall inside the container's `hostMountRoot` — a check about the
  bind-mount boundary, unrelated to what's inside the archive. These check different axes
  (member-relative-to-destDir vs. destDir-relative-to-mount-root) and neither can substitute for
  or weaken the other: an archive with a path-traversal member is blocked regardless of whether
  destDir is a legal container path at all, and a destDir outside the mount root is rejected
  regardless of whether every archive member is individually safe. `test/stitch_metadata_test.dart`'s
  new "container path-safety composition" group proves both directions directly with a fake
  docker runner: an unsafe member never reaches an extraction exec (only the listing exec runs),
  and a destDir outside the mount root is rejected via `ArgumentError` even when every member
  passes `isPathTraversalSafe`, with neither test's assertion able to pass by accident from the
  other check alone.
- **Hard cutover, matching PR #94's precedent.** `MetadataStitcher.exiftool` and
  `MetadataStitcher.archiveExtractor` are now *required* constructor parameters — no implicit
  default that silently shells out to a host-installed `unzip`/`tar`/`exiftool`. Same rationale as
  the `ffprobe` migration: this repo's target users already require Docker for Immich, so a "just
  in case" host fallback would only invite an accidental bypass of the container path (and its
  path-translation safety net) by omission.
- **Parity test redesign (the single most important design decision in this PR).** The Dart side
  of the Python-vs-Dart parity test previously called
  `exiftoolRunner(exiftoolBin: fakeExiftool.path)` — exercising the host `Process.run` mechanism
  against a fake binary on disk, mirroring exactly what the real Python script does via its own
  `PATH` override. Reusing that now that production `exiftool` invocation is container-routed
  would mean either installing a stub `exiftool` *inside* the pinned `media-pipeline-tools` image
  just for one test, or keeping a host-process seam wired in as if it were still the production
  path — neither is right for a test whose actual job is verifying processed/warning-count parity
  with the real Python script, not container-exec mechanics. `_fakeExiftoolRunnerFromMarkerFile`
  replicates the exact same marker-file protocol directly in Dart with zero process/container
  involvement, mirroring PR #94's identical `_fakeDurationReaderFromMarkerFile` decoupling for
  `dedupe_live_photos_test.dart`. The Python side is unchanged — it still runs the real script
  with a fake `exiftool` on `PATH`, since Python isn't going through the container either. Archive
  extraction in the parity test also stays on the host's real `unzip` (`TakeoutArchiveExtractor()`
  with no arguments) — the parity test's job is decision-logic parity, not container-exec
  mechanics, so only the exiftool invocation mechanism needed decoupling.
- **Real end-to-end coverage.** A new Docker-gated "stitch metadata via a real ToolsContainer"
  test starts a real `ToolsContainer`, generates a genuine JPEG with the pinned image's own
  `ffmpeg`, builds a real zip archive (real `zip`) containing that image plus a JSON sidecar and a
  second sidecar-less file, extracts it with real `unzip` inside the container, applies real
  `exiftool` metadata, and independently re-reads the `-Title` tag via a fresh `exiftool` exec to
  confirm it actually persisted (not just that `applyMetadataWithExiftool` returned `true`). The
  sidecar-less file proves the "continue past a file that can't get metadata, still move it" hard
  rule holds when both the extraction and the other file's `exiftool` call are real container
  execs.

**Pivots:** The real end-to-end test surfaced a genuine UID-mismatch finding: `extractArchive`
creates the extraction destDir on the *host*, with the host process's default umask — not
writable by the container's fixed non-root uid (10000; `docker/tools/Dockerfile`). This is the
same known-open Phase 3 (#76) UID/GID-mapping gap Phase 21's real-container test already
documented for its own fixture directory, now hit from a different angle (a container process
*writing into* a host-created directory, not just reading a host-written file). Worked around
with a test-only `chmod -R 0777` wrapped around the real container extractors, applied to
destDir right after `extractArchive` creates it and right before `unzip`/`tar` writes into it —
scoped entirely to the test fixture, no `lib/**` change. Also needed an ffmpeg fix: single-image
output requires `-update 1` (without it, `-frames:v 1` alone produces an "image sequence pattern"
error since `ffmpeg`'s `image2` muxer defaults to expecting a numbered sequence).

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green (339 tests),
including the new real-container tests, which actually ran (Docker + `media-pipeline-tools:local`
were available in this environment) rather than skipping.

**Also verified (constraints from this repo's Safety Rules):** a container-exec failure for one
file is caught inside `applyMetadataWithExiftool` (never propagates) — the hard
"continue past corrupt files" rule holds identically whether the failure originates on the host
or inside a container exec, since `containerExiftoolRunner` surfaces failures as an ordinary
non-zero exit code through the same `ExiftoolRunner` return shape the host implementation uses.
No media bytes are ever loaded into Dart memory by any of the new container-routed functions —
they only pass paths and flag strings as `docker exec` arguments.

**Outcome:** `stitch_metadata.dart` now has sanctioned, container-routed production paths for all
three of its external tools, proven against a real Docker daemon end-to-end, including the
two-mechanism path-safety composition this migration was expected to get right. Still not wired
into `pipeline_models.dart`/`media_pipeline_app.dart` — that remains later work. Part of #76, not
closing it. Flagging **Cody + Astrid** review as required — hardest migration in the series so
far, touches untrusted archive input, and composes two separate path-safety mechanisms.

## Phase 23 — Fourth consumer migration: clean-takeout-duplicates routes `sha256sum` through `ToolsContainer` (2026-07-15)

**Context:** Following Phase 22's three-tool `stitch_metadata.dart` migration, `lib/src/clean_takeout_duplicates.dart`
(Phase 0b port, PR #87) is the fourth #76 Phase 2 consumer migration and, as anticipated in this
migration's task brief, the simplest one yet: a single tool (`sha256sum`), invoked once per file,
producing one parseable hex string on stdout with no filesystem side effects — structurally
closer to Phase 21's `ffprobe` migration than to Phase 22's archive-extraction one.

**Decisions:**
- **`sha256sum` routes through the container.** `containerFileHasher({required ToolsContainer
  container})` translates the host file path via `ToolsContainer.hostToContainerPath` before every
  `container.exec(['sha256sum', ...])` call, mirroring `containerFfprobeDurationReader`'s shape
  exactly. Throws `FileSystemException` on a non-zero exit — a hashing failure is always a loud
  error, never a silent "not a duplicate" verdict.
- **Hard cutover, matching the established precedent.** `TakeoutDuplicateCleaner.hasher` is now a
  *required* constructor parameter — no implicit default that silently shells out to a
  host-installed `sha256sum`. Same rationale as the prior three migrations: this repo's target
  users already require Docker for Immich, so a "just in case" host fallback would only invite an
  accidental bypass of the container path (and its path-translation safety net) by omission.
  `verifyTakeoutDuplicateCandidate`'s own `hasher` parameter (the pure three-way decision function)
  is unchanged — every existing unit test already injects its own synthetic lambda there, and the
  verification *logic* itself was explicitly out of scope for this migration.
- **Parity test decoupling transferred even more cleanly than predicted.** Unlike the `ffprobe`
  migration (which needed a Dart-native marker-file fake because part of its decision logic — the
  numeric-duration regex, the duration-then-timestamp priority order — lives in how the raw stdout
  gets *parsed*), the Bash-vs-Dart parity test here needed no fake substitution at all:
  `sha256sum`'s only job is producing a real content hash of real bytes, and `defaultFileHasher`
  (host `Process.run` against a real `sha256sum` binary — the same real binary the Bash script
  itself shells out to) already does exactly that. Passing `hasher: defaultFileHasher` into the
  parity test's `TakeoutDuplicateCleaner` keeps the test decoupled from the "where does sha256sum
  run" question (no Docker needed to run the comparison) while still exercising a genuine SHA-256
  computation — including the adversarial hash-mismatch-despite-matching-size fixture that proves
  the three-way check isn't weakened to size-only, which continues to pass unmodified in spirit.
- **`sha256sum`'s provenance in the pinned image, made explicit.** Astrid's PR #93 review flagged
  that unlike `exiftool`/`ffmpeg`/`rclone`/`czkawka_cli`, `sha256sum` is present in
  `docker/tools/Dockerfile`'s image only as an undocumented transitive dependency of the
  `debian:bookworm-slim` base image (GNU coreutils). Verified the actual resolved version against
  the currently-pinned base image digest: `sha256sum (GNU coreutils) 9.1` / Debian package
  `coreutils=9.1-1`. `docker/tools/README.md` gains a new table row, a "GNU coreutils / `sha256sum`"
  section documenting that provenance and how to re-verify/bump it, and a new step in "Bumping a
  pinned tool version". `Dockerfile` itself gains a short inline comment next to the other `ARG`
  pins explaining why no explicit `apt-get install coreutils=...` line was added: coreutils is
  `Essential: yes` in Debian and therefore cannot be absent from *any* `debian:bookworm-slim`
  image — an explicit pin would be pinning theater, not a real reproducibility improvement, since
  the `FROM ...@sha256:...` digest pin already fixes its version exactly as effectively as an
  explicit `ARG` would for the other four tools.
- **Real end-to-end coverage.** A new Docker-gated "sha256sum via a real ToolsContainer" group
  starts a real `ToolsContainer` and: (1) hashes a real fixture file through the full path — host
  path -> container path translation -> real `sha256sum` exec inside the pinned image — and
  cross-checks the result against an independently-computed host-side `defaultFileHasher` call on
  the same bytes; (2) confirms a missing path throws `FileSystemException` rather than returning a
  bogus hash; (3) runs `TakeoutDuplicateCleaner` end-to-end with `containerFileHasher` wired in
  against a genuine matching-basename+size+hash fixture, confirming the full `wouldMove` decision
  path works through a real container exec, not just a mocked one.

**Pivots:** None. The migration matched its task brief's own prediction exactly — no marker-file
fake was needed, no UID-mismatch workaround was needed for the read-only hashing path (the write-only
UID-mismatch issue from Phases 21/22 only applies to files the *container* writes; here the
container only ever reads host-written fixture files, though the new container tests still
`chmod 0666`/`0777` their fixtures defensively, matching this series' established pattern, since
the fixed non-root container UID still needs read access to files the host test process wrote).

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green (343 tests, up
from 339 before this PR), including the new real-container tests, which actually ran (Docker +
`media-pipeline-tools:local` were available in this environment) rather than skipping.

**Outcome:** `clean_takeout_duplicates.dart` now has a sanctioned, container-routed production
path for its one external tool, proven against a real Docker daemon end-to-end, and
`sha256sum`'s previously-undocumented provenance in the pinned image is now explicit. Still not
wired into `pipeline_models.dart`/`media_pipeline_app.dart` — that remains later work. Part of
#76, not closing it. Flagging **Cody + Astrid** review as required, per this series' established
practice.

## Phase 24 — `ToolsContainer` host UID/GID mapping, closing the #76 Phase 3 gap (2026-07-15)

**Context:** Phases 21/22/23 (PRs #94/#95/#96) each independently hit the same
permission-denied failure while writing their real-`ToolsContainer` end-to-end tests:
`docker/tools/Dockerfile`'s image runs as a fixed non-root user (`tools`, uid 10000) as a safe
default for the image's own standalone verification, which generally does not match the host
test-runner's own UID — so files the container wrote onto the bind-mounted host directory came
out owned by uid 10000, not the host user, and (symmetrically) host-created fixture files the
fixed container uid lacked permission on failed to read from inside the container. All three
PRs flagged this as an open Phase 3 gap and worked around it with test-only `chmod
0777`/`0666` calls on their fixture directories/files, scoped to `test/**`, never `lib/**`.
This phase closes that gap for real, rather than continuing to work around it.

**Decision — `docker run --user <host-uid>:<host-gid>`, not an image change:**
`ToolsContainer.start()` (`lib/src/tools_container.dart`) now passes `--user` to `docker run`,
overriding the image's baked-in `tools` user for that one container instance — the standard
Docker-on-Linux idiom for exactly this bind-mount-ownership problem. `docker/tools/Dockerfile`'s
own `USER tools` default is untouched, so standalone/debugging use of the image (`docker run -it
media-pipeline-tools:local bash`, no `--user`) behaves exactly as before; this is a per-run
override, not an image change.

- **Host UID/GID detection:** the new `ToolsContainer.detectHostUserFlag()` static method shells
  out to `id -u`/`id -g` (Linux/macOS only; the same "shell to a small trusted binary" pattern
  this codebase already uses throughout `dedupe_live_photos.dart`/`stitch_metadata.dart`'s
  overridable tool seams). Output is sanity-checked as purely numeric before ever reaching a
  `docker run` argument. Returns `null` — meaning "don't pass `--user`; fall back to the image's
  baked-in `tools` user" — in two deliberate cases: on `Platform.isWindows` (Docker Desktop's
  Linux VM has a fundamentally different bind-mount permission model with no direct
  host-uid-to-container-uid passthrough; solving that properly is #76 Phase 5, not this PR), and
  if `id` itself is unavailable or fails for any reason (a permissions *optimization*, not a
  safety-critical path — falling back to the old baked-in-uid behavior beats refusing to start
  the tools container at all over a detection hiccup).
- **Not-provided-vs-explicit-null sentinel.** `ToolsContainer`'s constructor (and
  `withSession`'s) `hostUserFlag` parameter needed to distinguish "caller didn't pass it at all"
  (auto-detect via `detectHostUserFlag()`) from "caller explicitly passed `hostUserFlag: null`"
  (force no `--user` override, e.g. a test simulating Windows) — a plain `String?` parameter
  defaulting to `null` can't make that distinction, since both cases look identical inside the
  constructor body. Solved with a private `Object` sentinel default
  (`_hostUserFlagNotProvided`) and an `identical()` check, rather than silently collapsing the
  two cases (which would have made "explicitly disable" impossible to test and "auto-detect"
  impossible to distinguish from a caller bug).
- **Verified all five bundled tools work as an arbitrary host UID with no `/etc/passwd` entry**
  inside the container — a real, known Docker gotcha this PR did not assume away. Manually
  verified (`docker run --user "$(id -u):$(id -g)" ...`) and then covered by a dedicated
  Docker-gated test group (`test/tools_container_test.dart`, "ToolsContainer host UID/GID
  mapping"): `exiftool`, `ffmpeg`/`ffprobe`, `rclone`, `czkawka_cli`, and `sha256sum` all run
  correctly; only `whoami`/username-lookup-style operations fail (`cannot find name for user ID
  <uid>`), and none of these five tools rely on one.
- **Real ownership proof, not just "no error was thrown."** The same new test group starts a
  real `ToolsContainer`, has it write a file onto the bind mount, and asserts via `stat -c %u`
  that the resulting host-side file is owned by the real host UID (cross-checked against `id
  -u`), not uid 10000 — and separately proves a pre-existing host-owned fixture file (created
  with no `chmod`) is readable from inside the container without a permission error.
- **Removed the chmod workarounds** in `test/dedupe_live_photos_test.dart`,
  `test/stitch_metadata_test.dart` (both the `tempDir`-level chmod and the
  `chmodThenExtract`-wrapped archive extractors), and `test/clean_takeout_duplicates_test.dart`
  (all three chmod call sites) — all four Docker-gated real-container test groups from Phases
  21-23 now pass with zero chmod calls, which is this PR's own proof the fix works for the right
  reason (correct UID mapping), not that the removed assertions just happened to stop mattering.

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green (350 tests, up
from 343 before this PR — 7 new tests: 5 in the new "host UID/GID mapping" group, 2 in a new
"detectHostUserFlag" pure-logic group; 1 of those 7 is a Windows-only test that skips on this
Linux CI environment), all real-Docker groups (including the chmod-free reruns of Phases 21-23's
own real-container tests) actually ran against a real Docker daemon and the
`media-pipeline-tools:local` image in this environment, not skipped.

**Review addendum — visible fallback warning:** Astrid's review flagged that the "shouldn't
happen on a real Linux/macOS host" detection-failure branches of `detectHostUserFlag()`
(`id -u`/`id -g` erroring, producing non-numeric output, or the binary being missing entirely)
fell back to the old baked-in-uid-10000 behavior silently — a user hitting that edge case would
get the exact permission confusion this phase exists to eliminate, with no indication why.
Fixed by adding a `stderr.writeln('WARNING: ...')` in those three branches only, reusing
`stitch_metadata.dart`'s existing `WARNING: ` idiom — deliberately not added to the
`Platform.isWindows` branch, since that fallback is expected/documented, not a hiccup.

**Out of scope:** Windows UID/GID handling (explicitly deferred to #76 Phase 5, per this PR's
task brief) — `detectHostUserFlag()` returns `null` on Windows rather than attempting a mapping
that wouldn't mean the same thing under Docker Desktop's Linux VM. No consumer wiring changes —
this only changes how `ToolsContainer.start()` launches the container; the four already-migrated
consumers (`dedupe_live_photos.dart`, `stitch_metadata.dart`, `clean_takeout_duplicates.dart`)
needed no `lib/**` changes at all, only their tests' chmod workarounds came out.

**Outcome:** Closes the #76 Phase 3 permission-denied gap independently reproduced in PRs
#94/#95/#96 — every container-routed tool invocation across all four migrated consumers now runs
as the real host user by default on Linux/macOS, with no test-only chmod workaround required.
Part of #76 (tracking issue — stays open); this is Phase 3 of that issue's roadmap, not the
whole issue. Flagging **Cody + Astrid** review as required — this changes how every
container-routed tool invocation runs (`docker run`'s own argument list), a cross-cutting change
underneath all four already-reviewed consumer migrations.

## Phase 25 — `PipelineRunner`/`PipelineStep` Dart-action execution plumbing, no step migrated (2026-07-15)

**Context:** Phase 0 (Dart ports of `drive_detection`/`delete_duplicates`/`clean_takeout_duplicates`/
`dedupe_live_photos`/`stitch_metadata`/`restore_from_trash`) and Phase 2 (wiring those ports'
external-tool calls to `ToolsContainer`, PRs #93-96) are done, but `pipeline_models.dart`'s
`buildPipelineSteps()` still routes every single step through `PipelineCommand('bash'|'python3',
[...])` — the ported Dart logic is fully tested but has no way to actually run as a live pipeline
step. This phase builds the plumbing that will let a later PR swap one step at a time from a
subprocess to a direct Dart call, without touching which steps currently run Bash/Python.

**Design — exactly one execution mechanism per step, enforced by a constructor assert:**
`PipelineStep.command` (`lib/src/pipeline_models.dart`) changed from `required` to an optional
`PipelineCommand?`, joined by a new optional `PipelineDartAction? dartAction` field — a typedef
`Future<PipelineRunResult> Function(PipelineSettings settings, LogSink? onLog)`. The constructor
asserts `(command == null) != (dartAction == null)`, so a step must set exactly one; asserts run
in every debug/test build (this repo's whole test suite runs under `flutter test`, which keeps
asserts enabled), and `PipelineRunner.run()` also throws a `StateError` if it's ever handed a step
with neither set, so the invariant fails loudly even if asserts were ever compiled out. A sealed
class per execution kind was considered and rejected — it would have forced every existing
`PipelineStep(...)` call site in `buildPipelineSteps()` (12 steps, all `command`-based) to change
shape for no behavioral gain over a two-nullable-fields-plus-assert, which is this codebase's
existing idiom for "at most one of N related fields" (see `requiresDryRunStepId`'s already-nullable
pattern one field over).

**`LogSink` moved to `pipeline_models.dart`, re-exported from `pipeline_runner.dart`:** the
`PipelineDartAction` typedef needs the same callback shape `PipelineRunner.run()`'s `onLog`
parameter already used, but `LogSink` previously lived in `pipeline_runner.dart`, which imports
`pipeline_models.dart` — moving it the other direction would have created a cycle. Moved the
typedef itself to `pipeline_models.dart` and added `export 'pipeline_models.dart' show LogSink;`
to `pipeline_runner.dart`, so every existing `import 'package:media_pipeline_app/src/
pipeline_runner.dart'` call site (test files included) keeps resolving `LogSink` with zero changes.

**`PipelineRunner.run()` branches, subprocess path byte-for-byte unchanged:** if
`step.dartAction` is set, it's called directly — in-process, no `Process.start`, given the same
`onLog` callback a subprocess step would get — and its returned `PipelineRunResult` is passed
through unmodified. If `step.command` is set, the existing `Process.start`/stdout-stderr-split/
`stdoutOutput` capture logic (issue #54) is untouched, just reading from a local `command` binding
instead of `step.command` directly (needed once the field became nullable). Either path produces
the identical `PipelineRunResult` shape, so `GuidedRunController` and the app's step-run UI (which
only ever call `runner.run(...)` and read the result) need zero changes — verified by a new test
group chaining a mix of `command`-backed and `dartAction`-backed steps through the same
`GuidedRunController.run()` call and asserting identical start/complete/log/short-circuit behavior.

**Cancellation — investigated, none exists today, so none was added for Dart actions either.**
Searched `media_pipeline_app.dart` for any `Process.kill()`/step-abort path reachable from the UI:
none exists — the one visible "Cancel" button (`_MemoryWriteApprovalDialog`, an unrelated
memory-write-approval dialog) just closes a `Navigator` route, and `GuidedRunController.run()`'s
`shouldAbort` callback only gates *between* steps in the automatic chain, never kills a step
already spawned. Since subprocess steps have no live-cancellation parity to match, a Dart action
gets none either — adding one now would be scope beyond what this plumbing PR needs, per the task
brief's explicit instruction not to invent cancellation beyond what parity requires.

**Confirm-gate/dry-run invariants — no new bypass surface.** `PipelineStep`'s constructor doesn't
loosen `risk`/`requiresDryRunStepId`/`requiresDuplicateThumbnailReview` in any way — a future
`dartAction`-backed `delete-confirm`/`restore-confirm` step would still need to go through
`canRunStep()`'s existing dry-run/thumbnail-review gate exactly like a `command`-backed one, since
that gate is evaluated by the caller (`media_pipeline_app.dart`) before `runner.run()` is ever
invoked, independent of which execution mechanism the step uses. Nothing in this PR gives a Dart
action a way to run without going through that same caller-side gate.

**Not done here (intentionally):** `buildPipelineSteps()` is byte-for-byte unchanged — every step
still uses `command`; no script gets replaced by a Dart call in this PR. That migration (one step
at a time, per Astrid's standing risk list from Phase 20) is later work.

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green (358 tests, up
from 350 before this PR — 8 new tests in `test/pipeline_runner_test.dart`'s new "PipelineStep.dartAction
plumbing" group: 2 constructor-assert tests, 4 `PipelineRunner.run()` tests against a synthetic
dartAction — success/failure/uncaught-throw/settings-passthrough — and 2 `GuidedRunController`
tests — a mixed command+dartAction chain, and a dartAction failure short-circuiting the chain).

**Outcome:** `PipelineStep`/`PipelineRunner` now have a proven, tested second execution path with
identical external behavior to the existing subprocess path, ready for a future PR to migrate one
real step onto. Part of #76 (tracking issue — see roadmap, stays open), not the whole issue.
Flagging **Cody + Astrid** review as required, per this series' established practice — this
touches the shared execution path every future step migration will build on.

## Phase 26 — First real step migrations: 4 SAFE/dry-run steps wired to `dartAction`, plus the stuck-UI-state fix (2026-07-15)

**Context:** Phase 25 (PR #99) built the `PipelineStep.dartAction`/`PipelineRunner.run()` plumbing
but changed zero real steps — every step still shelled out to `bash`/`python3`. This phase does
the actual "swap Bash for Dart in production" step Astrid's Phase 20 risk list called out,
migrating exactly the four SAFE/non-confirm-gated steps in scope: `delete-dry-run` ->
`delete_duplicates.dart`, `restore-dry-run` -> `restore_from_trash.dart`,
`immich-takeout-duplicate-dry-run` -> `clean_takeout_duplicates.dart`, and `stitch-metadata` ->
`stitch_metadata.dart` (`PipelineRisk.reviewRequired`, not `safe`, but in scope per this PR's own
brief since it isn't confirm-gated). `delete-confirm`/`restore-confirm`
(`PipelineRisk.confirmRequired`) are untouched, deferred to a dedicated future PR with extra
review, per standing project policy on confirm-gated destructive steps.

**`scan-duplicates` (`05_cleanup_scan.sh`) confirmed out of scope, not skipped by oversight:**
checked `delete_duplicates.dart`'s own module doc comment and Phase 2's migration-completion note
— only `06`'s report-parsing/dry-run/confirm logic was ever ported to Dart; `05`'s own Czkawka
scan invocation (the actual `czkawka_cli` duplicate-scan command) has no Dart port at all. Porting
it would be inventing a new port outside this PR's stated scope (wiring already-ported modules),
so `scan-duplicates` stays on `command`.

**Wiring functions live in `pipeline_models.dart` itself** (`runDeleteDryRunStep`,
`runRestoreDryRunStep`, `runImmichTakeoutDuplicateDryRunStep`, `runStitchMetadataStep`), each a
top-level function matching the `PipelineDartAction` typedef exactly, referenced from
`buildPipelineSteps()` as plain tear-offs — kept the step list `const` (a top-level function
reference is a valid Dart compile-time constant), preserving the file's existing style. A separate
`pipeline_step_actions.dart` file was considered (cleaner separation of concerns) but would have
required either a two-file mutual import cycle with `pipeline_models.dart` (technically legal in
Dart but an unusual pattern for this codebase) or moving `PipelineStep`/`buildPipelineSteps()`
itself, judged unnecessary churn for four functions.

**Parity verification, per module:**
- `delete-dry-run`/`restore-dry-run`: `test/app_driven_simulation_test.dart` (pre-existing,
  unmodified by this PR) already drives `buildPipelineSteps()`'s `delete-dry-run` step through a
  real `PipelineRunner`, feeds its output to `duplicate_report.dart`'s real
  `parseDuplicateDryRunOutput`, runs the still-Bash `delete-confirm --confirm` script against the
  same fixture, and then re-runs `restore-dry-run` against the resulting real `media_trash` layout
  — proving this PR's Dart `delete-dry-run`/`restore-dry-run` path conventions
  (`trashDestinationPath`'s absolute-path-minus-leading-slash convention) exactly match what the
  still-Bash confirm script actually writes to disk, not just that the two sides look similar in
  isolation. This test passed unmodified once the wiring's output format matched (see the bug
  found below).
- `immich-takeout-duplicate-dry-run`/`stitch-metadata`: new `test/pipeline_step_actions_test.dart`,
  Docker-gated (mirrors `test/tools_container_test.dart`'s `_dockerAvailable`/`_toolsImageAvailable`
  pattern), drives each step through a real `PipelineRunner` against a real `ToolsContainer` and
  real fixture files (a genuine basename+size+hash-matching duplicate pair for the former; a real
  `zip`-built archive with a JSON sidecar for the latter), asserting on the real rendered output
  and real filesystem side effects (staged file exists, archive deleted, nothing moved in dry-run).

**Bug found during parity verification (fixed before this PR was considered done):** the first
draft of all three dry-run wiring functions used two separate helpers — a `log()` that only called
`onLog` live, and a `emit()` that both wrote to a result-accumulating `buffer` and called `log()`
— with the very first "DRY RUN MODE: ..." line going through `log()` only. Since
`media_pipeline_app.dart`'s completion handler sets `StepRunState.log` to `result.output` (an
*overwrite*, not an append, of whatever the live `onLog` stream had already accumulated — see
`_runSelectedStep`), that first line silently vanished from the final displayed log even though it
had appeared live for an instant. Caught by `test/app_driven_simulation_test.dart`'s existing
`expect(dryRun.output, contains('DRY RUN MODE'))` assertion, which failed until every line —
including the very first — went through the same `buffer`-writing `emit`. Fixed by defining `emit`
before any output is produced and using it exclusively, in all three affected functions.

**Stuck-UI-state fix (Cody's PR #99 review finding, required by this PR's brief):**
`media_pipeline_app.dart`'s two `runner.run(...)`/`guidedRunController.run(...)` call sites
(`_runSelectedStep`, `_runNextGuidedSegment`) never wrapped the `await` in a `try`/`catch`. Before
this PR, no real step used `dartAction`, so an uncaught throw from that path was unreachable in
practice; `pipeline_runner_test.dart`'s own "runner propagates an uncaught throw..." test (added in
Phase 25) documents that `PipelineRunner.run()` *deliberately* does not swallow a `dartAction`
throw into a fake result — so once real `dartAction`s existed that could genuinely throw (this
PR's `restore-dry-run` on a missing `media_trash`, or any container step if Docker isn't running),
an uncaught throw would leave `_runningStepId` permanently non-null, disabling that step's (or the
whole guided run's) controls until an app restart. Fixed at both call sites: `_runSelectedStep`
now catches, resets `_runningStepId`, and marks the step `failed` with the error text appended to
its log; `_runNextGuidedSegment` now catches, resets `_runningStepId`/`_guidedRunning`, marks the
step that was running when it threw as `failed`, and synthesizes a `GuidedRunResult` with
`GuidedRunOutcome.stepFailed` (tracking which earlier steps in the segment had already completed
via a local list, since `GuidedRunController.run()` itself never returns on a throw) so the guided
run's retry-from-failed-step logic (issue #51) still works correctly afterward. Two new widget
tests (`test/dart_action_throw_widget_test.dart`) reproduce the bug with a fake throwing
`PipelineRunner` (same construction pattern as
`guided_run_persistence_and_retry_widget_test.dart`'s existing fakes) for both the single-step and
guided-run call sites, proving the Run button/guided-run button are both usable again after a
throw, not stuck.

**Design decision — `dartAction` implementations mostly let exceptions propagate, not catch
them:** per `pipeline_runner_test.dart`'s documented "propagate, don't swallow" contract, none of
the four wiring functions wraps the underlying ported module's call in a generic try/catch — a
`ToolsContainer` start failure (e.g. Docker not running) or any other unanticipated error
propagates uncaught, now correctly handled by the stuck-UI-state fix above rather than by trying to
convert every possible failure into a clean result. The one deliberate exception:
`runRestoreDryRunStep` catches `TrashRootNotFoundException` specifically and returns a failed
(`exitCode: 1`) `PipelineRunResult` instead of letting it propagate — this mirrors the real Bash
script's own `set -e` non-zero-exit behavior on a missing `$MEDIA_TRASH` (a well-known, always
possible "nothing has been trashed yet" condition, not a bug), giving parity with how a subprocess
step would have reported the identical situation rather than routing an expected, common condition
through the generic uncaught-throw UI path.

**`ToolsContainer` lifecycle — one session per step run, not shared across steps:**
`immich-takeout-duplicate-dry-run` and `stitch-metadata` each call `ToolsContainer.withSession`
for the duration of that single step's run, then tear the container down. Considered and rejected
a longer-lived, app-session-scoped container shared across steps: these are independent pipeline
steps a human runs one at a time (never concurrently) from the step list or guided-run chain, so
there's no real overlap window where sharing would save meaningful start/stop overhead, and a
per-step session keeps each step's container lifecycle (and cleanup guarantee, via
`withSession`'s own `try`/`finally`) trivially easy to reason about — no risk of one step's failure
leaving a container state another step unexpectedly inherits.

**Log visibility (Cody's PR #99 finding on `dartAction` output being structurally different from
subprocess-captured output):** every migrated step's `onLog` receives real per-line progress/result
text, not silence-until-done. `stitch-metadata` additionally required a small, minimal, backward-
compatible addition to `stitch_metadata.dart` itself: `MetadataStitcher.run()` gained an optional
`warnOverride` parameter (defaulting to the existing `fileWarningLogger`, unchanged for every
existing caller/test) so `runStitchMetadataStep` can forward each per-file warning to `onLog` in
addition to the warning log file — without it, warnings would only reach the real OS stderr
(invisible to this in-process caller, unlike a subprocess's captured stderr) and a human watching
the step would see silence where a warning actually occurred. The three dry-run steps' per-item
result lines (Keep/Would trash, Would restore, Would move duplicate/verification-skip reasons) are
emitted immediately after each underlying module's single atomic `run()` Future resolves, not
truly streamed mid-computation — those ported modules return one complete result object rather
than a callback-driven stream, and adding streaming callbacks to them was judged out of scope for
a wiring-only PR; `stitch-metadata` (the step actually expected to run long, given real archive
extraction) does get true live streaming via `MetadataStitcher.run()`'s existing `print` parameter.

**`requiredTools` chips updated to reflect what actually runs where:** `immich-takeout-duplicate-
dry-run`'s chip changed from `sha256sum` to `docker` (the tool now runs inside a container, not on
the host); `stitch-metadata`'s changed from `python3, exiftool, rsync` to `docker, rsync`
(`exiftool`/`unzip`/`tar` are container-routed; `rsync`, used only by the raw-Google-Drive merge
step, still shells out on the host). Neither step's `linuxOnly`/OS-gating changed:
`immich-takeout-duplicate-dry-run` already had `linuxOnly: true` from before this PR;
`stitch-metadata` deliberately was **not** given `linuxOnly: true` even though it's now
`ToolsContainer`-dependent, since it's part of the automatic guided-run chain and was never
OS-restricted before this PR (the whole app already assumes POSIX-style paths via
`PipelineSettings.defaults()`'s hardcoded `/mnt/target_drive`) — a `ToolsContainer` failure on an
unsupported platform now surfaces as a visible failed step via the stuck-UI-state fix, rather than
this PR inventing a new hard OS gate.

**Existing tests updated (2, both were asserting on the now-null `step.command`):**
`test/pipeline_models_test.dart`'s "dry-run cleanup does not include confirm argument" and "immich
takeout duplicate dry-run is safe and linux only" now assert `step.command` is `null` and
`step.dartAction` is non-null instead of inspecting `PipelineCommand.arguments` — a stronger
guarantee than the old check (there is no argument list at all any more, so there is nothing that
could ever carry `--confirm`).

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green, 358 -> 363 tests
(5 net new: 2 in `test/dart_action_throw_widget_test.dart`, 3 in
`test/pipeline_step_actions_test.dart`; 2 existing tests updated, not counted as new), 1 skipped
(Windows-only, expected on this Linux CI environment). All Docker-gated groups (both new and
pre-existing) actually ran against a real Docker daemon and the `media-pipeline-tools:local` image
in this environment, not skipped. Reran the full suite twice to confirm no new flakiness from this
PR's changes (pre-existing `tools_container_test.dart` Docker-lifecycle-under-parallel-load
flakiness, already a known characteristic of that file, was observed and is unrelated to this PR).

**Outcome:** Four SAFE/dry-run-or-non-destructive pipeline steps now genuinely run their Dart-native,
container-routed implementations in production instead of shelling out to Bash/Python — the first
real "swap Bash for Dart" migrations issue #76's whole Phase 0/Phase 2 investment was building
toward. The stuck-UI-state gap Cody flagged in PR #99's review is closed for both call sites where
it could occur. `delete-confirm`/`restore-confirm` remain untouched, on `command`, deferred to a
dedicated future PR with extra review — no confirm-gated step's execution mechanism changed. Part
of #76 (tracking issue — see roadmap, stays open), not the whole issue. Flagging **Cody + Astrid**
review as required — this is the first PR where a real, human-triggerable pipeline step actually
executes Dart-native logic instead of a subprocess, touching this repo's stated first priority
(data-loss prevention) directly.

## Phase 27 — `delete-confirm`/`restore-confirm` wired to `dartAction`: the pipeline's two most destructive steps (2026-07-15)

**Context:** Phase 26 (PR #100) migrated the four SAFE/dry-run-or-non-destructive steps to
`dartAction` and deliberately left `delete-confirm`/`restore-confirm` (`PipelineRisk
.confirmRequired`) on `command`, deferred to a dedicated future PR with extra review. This is that
PR — the highest-risk step in the entire #76 migration, since these two steps are the ones that
actually move files on disk with no dry-run safety net once triggered.

**Wiring:** `runDeleteConfirmStep`/`runRestoreConfirmStep`, added to `pipeline_models.dart`
alongside Phase 26's four functions, follow the exact same conventions: top-level functions
matching `PipelineDartAction`, referenced as plain tear-offs from `buildPipelineSteps()`, `emit`
used for every line (including the first) so nothing vanishes from `StepRunState.log`'s
overwrite-not-append behavior (see Phase 26's bug writeup — the same footgun, avoided the same
way). `runDeleteConfirmStep` calls `DuplicateDeleter.run(confirm: true)`; `runRestoreConfirmStep`
calls `TrashRestorer.run(confirm: true)` — both modules' confirm paths already existed (Phase 0b),
this PR only wires them in.

**Confirm-gate — verified untouched, not just assumed.** `canRunStep()` in `pipeline_runner.dart`
was not modified by this PR and gates purely on `states`/`duplicateThumbnailReviewAcknowledged` —
it never inspects `step.command`/`step.dartAction`, so it is structurally blind to which execution
mechanism a step uses. Traced the actual call site: `media_pipeline_app.dart`'s
`_runSelectedStep()` calls `canRunStep()` and returns early on failure *before* `_runner.run(step,
...)` is ever invoked — this ordering is unchanged by this PR and applies identically whether
`step.dartAction` or `step.command` is set. There is no new path by which either `dartAction` can
run without its gate having already been satisfied. The `requiresDuplicateThumbnailReview` gate
(issue #49) is likewise a pure caller-side UI concern, orthogonal to execution mechanism — this PR
touches neither the gate nor the review dialog.

**Interrupt-safety — investigated, finding: no worse than the status quo.** Both `dartAction`s
delegate every real move to `SafeFileMover` (`filesystem_ops.dart`, unmodified by this PR).
Same-filesystem moves (the common case — everything lives under one `$HD_PATH` tree) go through a
single atomic `File.rename` syscall, exactly matching `mv`'s fast path: a kill at any point lands
the file at the old path or the new path, never partial. Cross-device moves (only possible if
`$HD_PATH` itself straddles multiple mounts) fall back to copy-verify-then-delete-original, never
removing the source before the destination copy's byte length is confirmed — the worst possible
outcome of an interrupt in that path is a harmless duplicate (both copies present), never a lost
file, and this matches GNU `mv`'s own cross-device fallback (copy then unlink) exactly. Both
`DuplicateDeleter.run`/`TrashRestorer.run` process one file at a time sequentially, the same
granularity as the Bash scripts' own `while read` loops, so an interrupt mid-batch leaves exactly
the same "some processed, rest untouched" state either implementation would produce. Full reasoning
recorded as a design-note doc comment in `pipeline_models.dart` above the two new functions.

**Real discovery during parity verification (unrelated to this PR's diff, documented not
fixed):** while building the collision fixture for `restore-confirm`'s mirror-image test, found
that `mv -n` exits 1 (not 0) on this environment's coreutils (9.4) when it skips an existing
destination — and since `11_restore_from_trash.sh` runs under `set -euo pipefail`, that turns into
a hard script failure on the *first* collision, aborting the whole restore batch and leaving every
later file unprocessed. This is a real, pre-existing characteristic of the still-live Bash script
(`restore_from_trash.dart`'s Dart port itself predates this PR — only its `dartAction` wiring is
new here) — confirmed empirically against the real script, not inferred from documentation. The
Dart `restore-confirm` dartAction does **not** inherit this bug: `TrashRestorer`/`SafeFileMover
.moveNoClobber` already reports a collision as `RestoreAction.skippedExisting` and continues to the
next file rather than throwing. A dedicated test
(`test/confirm_step_dart_bash_mirror_parity_test.dart`'s `DISCOVERY: ...` group) proves this
empirically on both sides — the real Bash script aborting non-zero, the real Dart dartAction
finishing successfully having skipped only the one colliding file. Out of scope to fix the Bash
script (issue #76's Phase 7 keeps it as a fallback for one release cycle), but worth flagging
loudly: this is an argument *for* finishing the Dart migration, not just parity with it.

**Mirror-image parity test (this PR's load-bearing proof) —
`test/confirm_step_dart_bash_mirror_parity_test.dart`, 3 tests:**
- `delete-confirm` test: drives the real Dart `delete-dry-run` then real Dart `delete-confirm`
  `dartAction`s (via `PipelineRunner`/`buildPipelineSteps`, the actual wired app path) against a
  fixture with two duplicate groups, one pre-seeded to force a `media_trash` destination collision.
  Independently runs the real, untouched `06_delete_duplicates.sh --confirm` against an
  identically-shaped fixture on a second, independent temp root. Cross-checks the resulting
  `media_trash` layout and surviving `cleaning_staging` files bit-for-bit — every relative path
  (normalized against each side's own random temp-dir prefix, since two independently-generated
  temp roots can never share literal absolute paths) and every byte of content — proving both the
  numbered-suffix-rename collision path and the plain no-collision path agree exactly.
- `restore-confirm` no-collision test: same shape, comparing the real Dart `restore-dry-run` +
  `restore-confirm` against the real, untouched `11_restore_from_trash.sh --confirm`, on a fixture
  with no collision (see the discovery above for why a collision can't be used in this particular
  comparison — the Bash side wouldn't produce a comparable completed layout).
- `DISCOVERY` test: documents and empirically proves the `mv -n`/`set -e` abort-on-collision
  finding above, and proves the Dart dartAction's more-robust continue-past-collision behavior.

**Log visibility:** both actions emit real per-file progress as each file is processed (`Trashed:`
/ `Trashed (renamed to avoid collision):` / `Missing, skipping:` / `Refusing outside staging:` for
delete; `Restored:` / `Skipped (destination already exists):` for restore), plus a final tally line
— these are the two actions a human is watching most closely, per this PR's own brief.
`runRestoreConfirmStep`'s log text is deliberately more accurate than the real Bash script's own
output on a skip (see the discovery above: Bash's `echo "Restored: $dest"` runs unconditionally
after `mv -n`, even when nothing was actually moved) — a corrected log message, not a functional
behavior change; the underlying skip-on-collision file behavior is unchanged and covered by the
parity test.

**Existing test updated (1):** `test/pipeline_models_test.dart`'s "confirm cleanup keeps explicit
confirm argument" renamed to "delete-confirm is Dart-native (issue #76) and never a --confirm
command" and rewritten to assert `step.command` is `null`/`step.dartAction` is non-null, mirroring
the equivalent Phase 26 update for the dry-run steps — a stronger guarantee than the old
argument-list check, since there is no argument list at all any more.

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green, 363 -> 366 tests
(3 net new, all in `test/confirm_step_dart_bash_mirror_parity_test.dart`; 1 existing test renamed/
rewritten, not counted as new), 1 skipped (Windows-only, expected on this Linux CI environment).
Reran the full suite twice to confirm stability; the pre-existing, already-documented
`stdout/stderr separation` timing flakiness under full-suite parallel load (unrelated to this PR)
was not observed in either run.

**Outcome:** Every non-setup, non-scan pipeline step that has a Dart port now genuinely runs it in
production — `06_delete_duplicates.sh --confirm`/`11_restore_from_trash.sh --confirm` are no longer
on the executed path, though both scripts remain in the repo, untouched, as the documented one-
release-cycle fallback (issue #76's Phase 7). The confirm-gate invariant traced across every PR in
this sequence (#99, #100, this one) is confirmed to still hold. Part of #76 (tracking issue — see
roadmap, stays open), not the whole issue. Flagging **Cody + Astrid** review as required, with extra
emphasis per this PR's own stakes — this touches the two most destructive, least-reversible-feeling
actions in the whole app.

## Phase 28 — `scan-duplicates` wired to `dartAction`: the last #76 Phase 2 gap (issue #103)

**Context:** Issue #103, filed as a status check-in on #76 after Phases 25-27 (PRs #99/#100/#101)
migrated 6 of 7 pipeline steps. `scan-duplicates` (`05_cleanup_scan.sh`) was the one remaining gap:
Phase 26's own PR note explicitly flagged it as out of scope, since only `06`'s report-*parsing*
logic (`delete_duplicates.dart`) had a Dart port — no Dart module actually invoked `czkawka_cli` to
*produce* a scan report. This PR ports that invocation (`lib/src/duplicate_scan.dart`) and wires it
in, closing gap 1 of #103's five gaps (gaps 2-5 — macOS/Windows verification, docs/CI, Bash
retirement — remain open, correctly sequenced after this one per #76's own roadmap).

**ImageMagick/blur-scan decision (flagged explicitly per this task's own brief, matching Phase 0c's
`stitch_metadata.dart` precedent): option (b) chosen — blur-scan is NOT ported, and `docker/tools
/Dockerfile` is NOT touched.** `RUN_BLUR_SCAN` isn't consumed by any Dart module, UI, or report
parser today — it's operator-facing-only output (`blurry_images.txt`), and adding ImageMagick would
expand the tools image's multi-arch (amd64+arm64) surface for a feature nothing downstream depends
on. Blur-scan capability is not silently dropped: `scripts/05_cleanup_scan.sh` (`RUN_BLUR_SCAN=1` by
default) remains in the repo, untouched and fully functional — an operator who wants blur detection
runs it directly. `runScanDuplicatesStep` says so explicitly in its own log output, not just in code
comments, so this isn't a silent capability loss from a human's point of view either.

**Design decision: report files staged under `$HD_PATH`, then copied to the real report directory.**
`ToolsContainer` bind-mounts exactly one host directory (`hostMountRoot`). `$CLEANING_STAGING` is
always under `$HD_PATH`, but `$REPORT_DIR` defaults to `$HOME/czkawka_reports` — not under `$HD_PATH`
in the common case — so `czkawka_cli -f <report-path>` run inside the container has no way to reach
it directly. Rather than widen `ToolsContainer` to support multiple bind mounts (a real option, but
a structural change to shared infrastructure only this one consumer needs), `DuplicateScanRunner.run`
has `czkawka_cli` write its `-f` report into a small, hidden staging directory it creates directly
under `$HD_PATH` (`.duplicate_scan_tmp`) — inside the one mount already available — then reads it
directly via plain `dart:io` (a bind mount is the same filesystem viewed from two places, not a
copy, so no `docker exec cat` round-trip is needed) and copies the content to the real `$REPORT_DIR`
location before deleting the temp directory in a `finally` block, success or failure.

**Real discovery during parity verification: `czkawka_cli` needs a writable `$HOME`.** Manually
exercising the real `czkawka_cli` binary (extracted from `media-pipeline-tools:local` via `docker
cp`, run natively on the host) against a container started with `--user <host-uid>:<host-gid>` — the
exact override `ToolsContainer.start()` applies (Phase 3, #76) — surfaced a real bug this port had to
route around: with no `$HOME` set (the arbitrary host uid has no matching `/etc/passwd` entry, so the
default `$HOME` is `/`, unwritable by that uid), `czkawka_cli` panics writing its cache database and
exits `101` — the exact "genuine crash" code this module's own exit-code classification exists to
catch. Verified empirically: the same `dup` scan against real duplicate files panics (exit 101, no
report written) with `$HOME` unset, and succeeds (exit 11, real report written) once `$HOME` points
at a writable directory. Fixed by having every scan invocation pass `env HOME=<container-side temp
dir>` ahead of `czkawka_cli`, reusing the same temp directory the report-staging decision above
already needs — no extra directory/mount required. None of the other four `ToolsContainer` consumers
needed this; they don't maintain a persistent cache database the way `czkawka_cli` does. This is a
genuine, previously-unknown gap in Phase 3's `--user` override, surfaced only because this port
actually exercised `czkawka_cli` under it for the first time — flagged loudly here since a future
consumer with similar cache/state needs should expect the same failure mode.

**Exit-code classification: preserved exactly, not re-derived.** `isCzkawkaScanExitFatal` is a
direct port of `run_czkawka_scan()`'s hard-won denylist-of-safe-codes logic (issue #81/PR #83,
refined by the Phase 16 review-fix pass): only `0` and `11` (czkawka's fixed found-duplicates
sentinel, not a variable count) are non-fatal: everything else — `101`, `126`/`127`, every `128+N`
signal-death code, and any other code — aborts. The Bash script's own `PIPESTATUS`/`tee` plumbing has
no Dart equivalent: `ToolsContainer.exec` (`docker exec`, no shell pipe) returns `czkawka_cli`'s real
exit code directly, so there's no pipe to lose information through — only the actual safety-relevant
classification needed porting, not the bash-specific mechanism for observing it.

**Parity verification (`test/duplicate_scan_test.dart`):**
- **Exit-code classification, matching issue #81/#83's own test coverage exactly** (`0`, `11`, `101`,
  `126`, `127`, `137`, `139`, plus one arbitrary other code, `55`): one group asserts
  `isCzkawkaScanExitFatal` directly; a second group runs the real, untouched `05_cleanup_scan.sh`
  with a fake `czkawka_cli` that unconditionally exits each code, and asserts the script's own
  abort-vs-reach-summary behavior agrees exactly with `isCzkawkaScanExitFatal`'s verdict for every
  code — a genuine Bash-vs-Dart cross-check, not just the Dart function tested in isolation.
- **Fake-`ToolsContainer` unit tests** (no real Docker needed, mirroring `tools_container_test.dart`'s
  own fake-runner precedent): prove `runSingleCzkawkaScan` throws `CzkawkaScanFailedException` on a
  fatal exit code without ever misreporting it as found-duplicates; prove the `env HOME=...` fix is
  actually present in the real exec arguments; prove `DuplicateScanRunner.run` throws
  `CleaningStagingNotFoundException` without ever touching the container when staging is missing.
- **Real end-to-end parity, real fixtures, real Docker (`docker/tools/README.md`'s own precedent for
  what "real" means here):** seeds two independent, identically-shaped fixture roots with a genuine
  byte-identical duplicate pair; runs `DuplicateScanRunner.run` via a real `ToolsContainer` session on
  one, and the real `05_cleanup_scan.sh` — driven by the *exact same* `czkawka_cli` binary, extracted
  from the image via `docker cp` and run natively on the host (no separately-installed host binary is
  assumed to exist) — on the other. Cross-checks the found-group counts for all three scan kinds
  (image/video/dup) computed independently on each side agree exactly, and that both report files
  reference the same duplicate filenames.
- **Wiring-level test** in `test/pipeline_step_actions_test.dart` (this repo's established split
  between module-logic tests and `PipelineRunner`-driven wiring tests): drives `scan-duplicates`
  through the real `buildPipelineSteps()`/`PipelineRunner` path against a real `ToolsContainer`,
  proving the step definition itself is correctly wired, not just the underlying module.

**`scan-duplicates` step definition:** `command` → `dartAction: runScanDuplicatesStep`;
`requiredTools` changed from `['czkawka_cli', 'ffmpeg', 'ffprobe', 'convert']` to `['docker']` (only
`czkawka_cli` is used now, and it runs inside the container). `risk` unchanged
(`PipelineRisk.reviewRequired`) — this step extracts/writes report files but has no confirm-gate
split, matching `stitch-metadata`'s precedent. Not marked `linuxOnly` (it was never OS-restricted
before this PR and is part of the automatic guided-run chain, same reasoning `stitch-metadata`'s
Phase 26 entry documents).

**Existing test updated:** none required updating (no prior test asserted on `scan-duplicates`'s
`command`/`requiredTools`) — one new test added in `test/pipeline_models_test.dart` asserting
`step.command` is `null`/`step.dartAction` is non-null/`requiredTools` is `['docker']`, matching the
Phase 26/27 precedent for every other migrated step.

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green, 366 -> 388 tests (22
net new: 20 in `test/duplicate_scan_test.dart`, 1 in `test/pipeline_step_actions_test.dart`, 1 in
`test/pipeline_models_test.dart`), 1 skipped (Windows-only, expected on this Linux CI environment).
All Docker-gated groups (both new and pre-existing) actually ran against a real Docker daemon and the
`media-pipeline-tools:local` image in this environment, not skipped.

**Outcome:** Every pipeline step with a Dart port now genuinely runs it in production —
`scan-duplicates` is the last of the seven steps issue #76 Phase 2 set out to migrate.
`05_cleanup_scan.sh` remains in the repo, untouched, both as the documented one-release-cycle
fallback (issue #76's Phase 7) and as the only way to run the optional blur scan. Part of #76
(tracking issue — see roadmap, stays open) and part of #103 (status check-in issue — gaps 2-5 remain
open), not closing either. Flagging **Cody + Astrid** review — this is a real, previously-uncovered
production execution path for a tool that scans real personal media.

## Phase 29 — Fix `apply_metadata_with_exiftool`'s off-by-one skip guard, both languages (issue #91)

**Context:** Found during PR #89's review (Cody + Astrid) and filed as issue #91.
`apply_metadata_with_exiftool`'s "no useful tags queued, skip exiftool" guard had an off-by-one:
Python's `args` starts as `["exiftool", "-overwrite_original"]` (length 2), gaining +1 for a title,
+1 for a description, or +3 for date/GPS, per queued tag. The guard read `if len(args) == 3`, which
only fires when *exactly one* single-flag tag (title-only or description-only, nothing else) was
queued — silently discarding a real tag. The genuine "zero tags queued" case is `len(args) == 2`,
which fell through the guard and ran a harmless but mislabeled no-op
`exiftool -overwrite_original <file>` call instead.

**Fix:** `scripts/04_stitch_metadata.py`'s guard changed from `len(args) == 3` to `len(args) == 2`.
`lib/src/stitch_metadata.dart`'s `applyMetadataWithExiftool` — the Dart port from PR #89, which
deliberately preserved the Python bug byte-for-byte for cross-language parity at the time — had its
own equivalent guard (`args.length == 2`, one less than Python's since the Dart `args` list omits the
executable name) changed to `args.length == 1`, matching the corrected Python behavior. Per #91's
scope note in the Dart module's own top-level doc comment (the "Design decision" section explicitly
flagged this as a follow-up for Cody/Astrid to weigh in on), this PR closes that follow-up rather than
leaving the two implementations to silently diverge — Python correct, Dart still buggy, with the
Dart parity tests wrongly read as proof-of-correctness for the old behavior.

**Why the Dart side matters for real pipeline runs, not just parity docs:** per #76 Phase 2 (PR
#100), `stitch-metadata` is `dartAction`-backed in production — `lib/src/stitch_metadata.dart` is
what actually runs when a user executes this step in the app today, not
`scripts/04_stitch_metadata.py`. The Dart-side fix, not the Python one, is what fixes real pipeline
runs.

**Tests updated:**
- `tests/test_stitch_metadata.py`: three new regression tests —
  `test_apply_metadata_writes_title_only_tag_instead_of_skipping`,
  `test_apply_metadata_writes_description_only_tag_instead_of_skipping` (both mock `subprocess.run`
  and assert it's called with the real `-Title=`/`-Description=` flag, proving the tag is no longer
  discarded), and `test_apply_metadata_skips_exiftool_when_truly_zero_tags_queued` (asserts
  `subprocess.run` is never called for a genuinely empty sidecar).
- `test/stitch_metadata_test.dart`: the two `applyMetadataWithExiftool` tests that asserted the old
  buggy behavior were updated to assert the corrected behavior — the former "no usable tags, but
  exiftool still ran as a no-op" test now asserts exiftool is *not* invoked for zero tags, and the
  former "title-only quirk, exiftool never invoked" test now asserts exiftool *is* invoked with
  `-Title=...`. A new sibling test covers the description-only case. The module's top-level doc
  comment and the function's own doc comment were both updated to describe the fix instead of the
  preserved quirk.

**Verification:** Python — `python3 -m unittest discover -s tests`: 51 tests (48 -> 51, +3), all
green; `ruff check scripts config tests`: clean; `python3 -m compileall scripts config tests`: clean.
Dart — `flutter analyze`: no issues; `flutter test`: full suite green, 388 -> 389 tests (net +1, since
one existing test was split into two plus a new description-only sibling), all Docker-gated groups
(including the real end-to-end `MetadataStitcher.run` + `stitch-metadata` `PipelineRunner` wiring
tests) actually ran against a real Docker daemon and the `media-pipeline-tools:local` image, not
skipped.

**Risk:** Low-medium, matching #91's own risk assessment — a metadata-completeness fix, not a
data-loss risk (the media file itself was always kept regardless of this bug; only its title/
description tag was silently dropped for the narrow title-only/description-only sidecar case).
Closes #91.

## Phase 30 — Dedup coverage banner: warn when a large set's precise percentage is still a small fraction (issue #70)

**Context:** Follow-up from Astrid's non-blocking review note on PR #69 (#53). #53 replaced the old
vague "Showing N of M pairs" text with a precise, prominent coverage banner ("You reviewed N of M
pairs (X%)"). For real-world runs with 5,000+ pairs in one duplicate set, reviewing even a few
~20-pair "Review Another Sample" batches only moves the percentage a fraction of a point — a human
watching the number tick up slightly could come away feeling *more* confident than the old vague-count
design, despite having reviewed almost nothing relative to the set. This is the opposite failure mode
from #53's original problem (false confidence from an under-communicated small sample); now it's false
confidence from apparent precision on a huge set.

**Fix (the cheap half of the issue's option 1 — absolute-count-plus-percentage framing for large
sets):** Added `duplicateReviewIsSmallFractionOfLargeSet(reviewedCount, totalPairs)` to
`lib/src/duplicate_report.dart`, gated by two new constants: `duplicateReviewLargeSetThreshold` (200
pairs) and `duplicateReviewSmallFractionPercent` (10%). When a duplicate set is at or above the large
threshold *and* cumulative coverage is at or below the small-fraction threshold, `_DedupReviewPanel` in
`lib/src/media_pipeline_app.dart` now shows an extra warning line below the existing coverage chip:
"This is a large duplicate set (N pairs) — M reviewed is still a small fraction even at X%. Consider
reviewing several more samples, or spot-checking specific folders, before trusting the full move
plan." The warning clears automatically once cumulative coverage climbs past 10% of a large set, or
if the set never reached 200 pairs in the first place (a set that small was never the problem #70
describes).

**Deliberately did not build option 2** (folder-scoped review UI) — the issue itself flagged this as
disproportionate to its own "low risk, UX/framing only" assessment unless trivially cheap, and no
existing folder-scoping infrastructure exists to hook into. **Did not touch the confirm gate** —
`canRunStep()` and the `duplicateThumbnailReviewAcknowledged` mechanics are untouched; this is
framing-only, same constraint #53 held itself to.

**Tests added:**
- `test/duplicate_report_test.dart`: new `duplicateReviewIsSmallFractionOfLargeSet` group — false for
  small sets even at low percentage coverage, true for a large set with low absolute coverage (mirrors
  the issue's 5,412-pair example), false once coverage climbs past 10%, false once a large set is fully
  reviewed, and boundary cases at exactly the large-set threshold.
- `test/dedup_review_widget_test.dart`: new end-to-end case with a 250-pair set — after one 20-pair
  batch (8%) the extra warning shows; after reopening the review dialog once more (drawing a fresh
  20-pair batch automatically, reaching 40 of 250 = 16%) the warning clears while the underlying
  coverage banner and gate behavior are unaffected.

**Verification:** `flutter analyze`: no issues. `flutter test`: full suite green, 393 -> 399 tests (net
+6: 5 new in `test/duplicate_report_test.dart`, 1 new in `test/dedup_review_widget_test.dart`), 1
skipped (Windows-only, expected on Linux). `test/pipeline_runner_test.dart`'s
`stdout/stderr separation ... onLog still receives every stdout and stderr chunk` test failed
intermittently in this environment both with and without this branch's changes (confirmed via
`git stash`) — pre-existing flakiness, unrelated to this change.

**Risk:** Low, matching #70's own assessment — UX/framing only, no data-loss path, confirm-gate
mechanics unaffected. Closes #70.

## Phase 31 — Guided run: visible staleness warning on checkpoint resume/retry (2026-07-16)

**Context:** #68, a follow-up flagged independently by Cody and Astrid during PR #67's review
(Phase 9). The guided-run checkpoint's staleness check (`GuidedRunCheckpoint.isStale`,
hdPath/reportDir match + within `guidedRunCheckpointMaxAge`) and the in-session
retry-from-failed-step logic can't detect content drift that isn't a settings change: a manual
pipeline step run outside the guided flow against the same `HD_PATH`, or `cleaning_staging`'s
actual contents changing between an earlier step's output (e.g. `scan-duplicates`) and a later
step (e.g. `delete-dry-run`) being retried in isolation. Risk was assessed LOW by the issue
itself — no data-loss path, since the separate `--confirm` phrase gate is completely unaffected;
worst case is a stale dry-run report shown to the user or a redundant re-run.
**Decision:** Per the issue's own two possible directions, picked the cheaper one it explicitly
flagged as possibly sufficient given the confirm-gate backstop: a visible UI warning, not a
content-fingerprint mechanism (mtime/file-count of `cleaning_staging`, or a report hash). A
fingerprint would add real complexity (a new persisted field, a new comparison surface, more
edge cases to test) to close a gap whose own worst case is "misleading report", already guarded
by the unrelated, unchanged manual confirm step — the cost didn't match the risk.
Added `_guidedRunCheckpointResumedWarning` (bool state, set when `_loadGuidedRunCheckpoint`
restores a non-stale persisted checkpoint, cleared once the user acts on it by starting the next
segment) and reused the existing `_guidedSegmentCompletedCount` state (already tracks "some
steps in this segment already succeeded and a retry would resume from the failed one") to drive
a new `_guidedRunStalenessWarning` getter. It surfaces at both points named in the issue: (1) the
idle state right after a persisted checkpoint is restored, before the user presses "Continue
Guided Run"; and (2) the idle state right after a mid-segment step failure, before the user
retries and the run resumes from the failed step instead of the segment start. `_GuidedRunPanel`
gained an optional `warningMessage` rendered in the error color with a warning icon, additive to
the existing status message — no existing button/label/status-message behavior changed.
**Pivots:** None — considered making the retry-warning condition reactively track live
`TextEditingController` edits (to hide the warning the instant a changed HD_PATH would force a
full segment restart instead of a resume), but the existing `_guidedRunStatusMessage` code this
sits beside already doesn't do that (no listener triggers a rebuild on controller text changes,
by design) — matching that established pattern instead of introducing new reactive plumbing for
one warning string.
**Outcome:** `test/guided_run_persistence_and_retry_widget_test.dart` gained a
`guided run staleness warning (#68)` group: one test proves the warning appears after a
simulated app restart restores a persisted checkpoint and disappears once the user starts the
next segment; one test proves it appears after a mid-segment step failure (before retrying) and
disappears once the retry succeeds and the segment completes. `flutter analyze`: clean.
`flutter test`: full suite green, 389 -> 391 tests (net +2). Closes #68.

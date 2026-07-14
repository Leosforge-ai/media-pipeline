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
`go list`'s module proxy version list, not an ancient release) and bumped `go-version` to
`'1.24'` (setup-go resolves the latest 1.24.x patch, currently 1.24.13, which satisfies the
`>= 1.24.11` requirement). Left the existing SHA-pinned `actions/checkout`/`actions/setup-go`
steps untouched — only the floating `@latest` install and the Go version needed to move.
**Outcome:** `.github/workflows/gitleaks.yml`'s install step now reads
`go install "github.com/zricethezav/gitleaks/v8@${GITLEAKS_VERSION}"` with `GITLEAKS_VERSION:
v8.30.1` pinned as a step `env`, plus an inline comment giving the exact commands (proxy.golang.org
`.mod`/`/list` lookups) to check compatibility and bump both `GITLEAKS_VERSION` and `go-version`
together the next time a deliberate upgrade is needed, so this doesn't silently drift back to a
floating target. No product code (`scripts/`, `lib/`, `tests/`) touched — CI config only.

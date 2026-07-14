# Repo History — media-pipeline

> Durable company-os operating history. Engineering log: `docs/HISTORY.md`. No secrets.

## 2026-06-02 — Onboarded under company-os control (#36)

Decision: brought under company-os control via non-destructive, inventory-first onboarding. Added the `.company/` folder; **no existing files altered** (CLAUDE/GEMINI/AGENTS already present from the standards rollout). Registered in company-os `projects.yaml` (#61) as `active`. Data-loss-prevention rules foregrounded.
Evidence: company-os #60 (umbrella), media-pipeline #36.

## 2026-07-12/14 — Pipeline trust + Immich UX pass, plus real-data duplicate-safety incident

**Goal:** reduce manual pipeline friction and increase trust in duplicate detection (owner's stated top complaints), and get the Immich browsing experience closer to what native self-hosted ML already supports.

**Shipped (Sofie implement → Cody + Astrid review → merge, no self-merge):**

- #48/PR #50 — guided consolidated pipeline run (fewer manual checkpoints). Review caught two real defects before merge: an interactive `rclone config` step would have hung the unattended chain, and the documented confirm-gate safety check (`buildGuidedRunSteps()`) was never actually called by the app. Both fixed pre-merge.
- #49/PR #52 — thumbnail-diff review UI before the destructive duplicate-trash confirm gate. Reviewed clean.
- #55/PR #56 — `scripts/00b_first_time_drive_setup.sh`: detects an unmounted target drive and prints (never executes) the correct mount/fstab commands, gated behind explicit confirmation. Review caught a boot-disk-exclusion gap for LVM/btrfs root layouts; fixed pre-merge.
- #57/PR #58 — fixed two bugs in `00b` found live on the repo owner's real hardware: `blkid` returning empty without root (now tries `lsblk -no FSTYPE` first), and `lsblk` without `-d`/`--nodeps` leaking child-partition rows into boot-disk detection, corrupting it to multi-line/duplicated output.
- #60/PR #61 — `scripts/13_dedupe_live_photos.sh`: finds Apple Live Photo still+video pairs split apart by Google Takeout exports (matching basename + directory, `ffprobe` duration ≤5s), moves the redundant motion clip to `media_trash`. Bonus: fixed a pre-existing `11_restore_from_trash.sh` bug where `--confirm` always exited 1 even on success (was silently marking the Flutter guided-run's restore-confirm step as "failed" on every successful restore).
- #62/PR #63 — fixed `12_clean_immich_takeout_duplicates.sh`'s trash-destination path (was nesting moves under a timestamped batch subdirectory that `11_restore_from_trash.sh` couldn't reverse); now mirrors the full absolute path under `$MEDIA_TRASH`, matching `06`/`13`'s already-correct pattern.

Follow-ups filed, not yet scheduled: #51 (persist guided-run checkpoint across app restart), #53 (dedup-review sample-coverage framing), #54 (PipelineRunner stdout/stderr merge edge case), #59 (boot-disk-exclusion test isolation / consider a more robust primitive than lsblk-text-parsing).

**Real-data incident, found and resolved in the same window (not a code defect — a review gap in how a prior `06_delete_duplicates.sh --confirm` run was trusted):**

While verifying the fixes above against the owner's actual ~1.8TB library, discovered `06_delete_duplicates.sh` had, in an earlier run (before the thumbnail-diff review UI existed), trashed the large majority of two full wedding-photo folders (`Takeout/.../Lucy and Leo Wedding July 2021` and a separate `Fotos/2021/Wedding/` cache) as false-positive "duplicates." Root-caused, verified, and restored:

- Confirmed via file-count comparison (`cleaning_staging` vs `immich_library` vs what was actually live in Immich) before touching anything.
- Restored 463 + 464-1 wedding files via a scoped, dry-run-first manual replica of `11_restore_from_trash.sh`'s own logic.
- Ran a full trashed-vs-kept ratio audit across every folder (not just the wedding one), then an exhaustive SHA-256 hash-verification pass of all ~21K trashed files against the entire current library (not just same-named folders) — 19,670 confirmed as genuine duplicates (dedup was correct for the large majority; many flagged folders turned out to be Google Photos' own auto-curated "Memories" collections, which legitimately duplicate main-folder content), 1,486 with no proof of a copy anywhere — all 1,486 restored (safe/additive action).
- Separately investigated and resolved a forgotten `immich_library_contaminated_20260529_181427` folder (197G) the owner didn't remember creating — turned out to be Immich's own internal cache (`thumbs/`, `encoded-video/`) accidentally mixed into what should have been the read-only external-library folder, already correctly quarantined by a past manual fix; not a data-loss case.
- Ran the newly-merged `13_dedupe_live_photos.sh --confirm` against the live library: 4,908 redundant Live Photo motion clips removed cleanly, dry-run-verified first.
- Confirmed no widespread corruption: an ImageMagick `identify` + `ffprobe` integrity sweep found only 95/~35K images and 0/~5K videos genuinely unreadable; the rest of the "broken thumbnails" the owner saw was Immich's own thumbnail-generation job queue catching up on the ~7K restored files.

**Lesson for future dedup-adjacent work on this repo:** folder-name/ratio heuristics alone are not sufficient trust signal for a completed `--confirm` run on real family-photo data — exhaustive hash verification against the *entire* current library (not just the same-named folder) is what actually caught the gap. The thumbnail-diff review UI (#49) now prevents this class of issue going forward for new runs; this incident predated it.

Evidence: media-pipeline #48–#63 and their PRs; ad-hoc diagnostic scripts (not committed — one-off, delivered directly to the repo owner) used for the real-data audit are described in this Claude Code session's memory, not in this repo.

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run_script(
    script: str,
    hd_path: Path,
    report_dir: Path,
    *args: str,
    input_text: str | None = None,
    extra_env: dict[str, str] | None = None,
):
    env = {
        **os.environ,
        "HD_PATH": str(hd_path),
        "REPORT_DIR": str(report_dir),
        **(extra_env or {}),
    }
    return subprocess.run(
        ["bash", str(ROOT / "scripts" / script), *args],
        cwd=ROOT,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


class ShellScriptSafetyTests(unittest.TestCase):
    def test_duplicate_delete_dry_run_parses_only_staging_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staging = root / "cleaning_staging"
            reports = root / "reports"
            reports.mkdir()
            first = staging / "a.jpg"
            second = staging / "b.jpg"
            first.parent.mkdir(parents=True)
            first.write_text("first", encoding="utf-8")
            second.write_text("second", encoding="utf-8")
            (reports / "duplicate_files.txt").write_text(
                "\n".join(
                    [
                        "Found 2 files which are duplicates",
                        '"Results" - header that must not be parsed',
                        f'"{first}" - 10 KiB',
                        '"/outside/staging.jpg" - must be ignored',
                        f'"{second}" - 10 KiB',
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            result = run_script("06_delete_duplicates.sh", root, reports)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Keep: {first}", result.stdout)
            self.assertIn(f"Would trash: {second}", result.stdout)
            self.assertNotIn("Would trash: /outside/staging.jpg", result.stdout)
            self.assertTrue(second.exists())

    def test_duplicate_delete_confirm_moves_to_media_trash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staging = root / "cleaning_staging"
            reports = root / "reports"
            reports.mkdir()
            first = staging / "a.jpg"
            second = staging / "b.jpg"
            first.parent.mkdir(parents=True)
            first.write_text("first", encoding="utf-8")
            second.write_text("second", encoding="utf-8")
            (reports / "duplicate_files.txt").write_text(
                f'"{first}" - 10 KiB\n"{second}" - 10 KiB\n\n',
                encoding="utf-8",
            )

            result = run_script("06_delete_duplicates.sh", root, reports, "--confirm")

            trashed = root / "media_trash" / str(second).lstrip("/")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(first.exists())
            self.assertFalse(second.exists())
            self.assertTrue(trashed.exists())

    def test_restore_from_trash_dry_run_reconstructs_original_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            target = root / "cleaning_staging" / "restored.jpg"
            trashed = root / "media_trash" / str(target).lstrip("/")
            trashed.parent.mkdir(parents=True)
            trashed.write_text("photo", encoding="utf-8")

            result = run_script("11_restore_from_trash.sh", root, reports)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Would restore: {trashed} -> {target}", result.stdout)
            self.assertTrue(trashed.exists())
            self.assertFalse(target.exists())

    def test_immich_takeout_cleanup_dry_run_targets_only_verified_fotos_de_years(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            google_fotos = root / "immich_library" / "Takeout" / "Google Fotos"
            canonical = google_fotos / "2024" / "IMG_1951.HEIC"
            duplicate = google_fotos / "Fotos de 2024" / "IMG_1951.HEIC"
            mismatch_keep = google_fotos / "2025" / "IMG_2000.HEIC"
            mismatch_duplicate = google_fotos / "Fotos de 2025" / "IMG_2000.HEIC"
            custom_folder_duplicate = google_fotos / "Albums" / "IMG_1951.HEIC"

            canonical.parent.mkdir(parents=True)
            duplicate.parent.mkdir(parents=True)
            mismatch_keep.parent.mkdir(parents=True)
            mismatch_duplicate.parent.mkdir(parents=True)
            custom_folder_duplicate.parent.mkdir(parents=True)
            canonical.write_bytes(b"same-photo")
            duplicate.write_bytes(b"same-photo")
            mismatch_keep.write_bytes(b"canonical")
            mismatch_duplicate.write_bytes(b"localized")
            custom_folder_duplicate.write_bytes(b"same-photo")

            result = run_script(
                "12_clean_immich_takeout_duplicates.sh",
                root,
                reports,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Would move duplicate: {duplicate}", result.stdout)
            self.assertIn(f"Kept canonical: {canonical}", result.stdout)
            self.assertIn(f"Hash mismatch, skipping: {mismatch_duplicate}", result.stdout)
            self.assertIn("Candidates inspected: 2", result.stdout)
            self.assertIn("Verified duplicates:  1", result.stdout)
            self.assertTrue(duplicate.exists())
            self.assertTrue(custom_folder_duplicate.exists())
            self.assertNotIn(str(custom_folder_duplicate), result.stdout)

    def test_immich_takeout_cleanup_confirm_requires_typed_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            google_fotos = root / "immich_library" / "Takeout" / "Google Fotos"
            canonical = google_fotos / "2024" / "IMG_1951.HEIC"
            duplicate = google_fotos / "Fotos de 2024" / "IMG_1951.HEIC"
            canonical.parent.mkdir(parents=True)
            duplicate.parent.mkdir(parents=True)
            canonical.write_bytes(b"same-photo")
            duplicate.write_bytes(b"same-photo")

            result = run_script(
                "12_clean_immich_takeout_duplicates.sh",
                root,
                reports,
                "--confirm",
                input_text="wrong phrase\n",
                extra_env={"RUN_TIMESTAMP": "20260529_000000"},
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("Confirmation phrase did not match", result.stdout)
            self.assertTrue(canonical.exists())
            self.assertTrue(duplicate.exists())

    def test_immich_takeout_cleanup_confirm_moves_verified_duplicate_to_trash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            google_fotos = root / "immich_library" / "Takeout" / "Google Fotos"
            canonical = google_fotos / "2024" / "IMG_1951.HEIC"
            duplicate = google_fotos / "Fotos de 2024" / "IMG_1951.HEIC"
            canonical.parent.mkdir(parents=True)
            duplicate.parent.mkdir(parents=True)
            canonical.write_bytes(b"same-photo")
            duplicate.write_bytes(b"same-photo")

            result = run_script(
                "12_clean_immich_takeout_duplicates.sh",
                root,
                reports,
                "--confirm",
                input_text="MOVE TAKEOUT DUPLICATES\n",
                extra_env={"RUN_TIMESTAMP": "20260529_000000"},
            )

            trashed = root / "media_trash" / str(duplicate).lstrip("/")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(canonical.exists())
            self.assertFalse(duplicate.exists())
            self.assertTrue(trashed.exists())
            self.assertEqual(trashed.read_bytes(), b"same-photo")

    def test_immich_takeout_cleanup_confirm_and_restore_round_trip(self):
        # Regression test for #62: 12_clean_immich_takeout_duplicates.sh used
        # to nest moved files under a timestamped batch subdirectory
        # ($MEDIA_TRASH/immich_library_fotos_de_duplicates_<timestamp>/...),
        # which 11_restore_from_trash.sh could not reverse (it only strips
        # the $MEDIA_TRASH/ prefix and prepends "/", so the batch segment
        # survived as a bogus extra path component). Mirrors the round-trip
        # test PR #61 added for 13_dedupe_live_photos.sh.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            google_fotos = root / "immich_library" / "Takeout" / "Google Fotos"
            canonical = google_fotos / "2024" / "IMG_1951.HEIC"
            duplicate = google_fotos / "Fotos de 2024" / "IMG_1951.HEIC"
            canonical.parent.mkdir(parents=True)
            duplicate.parent.mkdir(parents=True)
            canonical.write_bytes(b"same-photo")
            duplicate.write_bytes(b"same-photo")

            result = run_script(
                "12_clean_immich_takeout_duplicates.sh",
                root,
                reports,
                "--confirm",
                input_text="MOVE TAKEOUT DUPLICATES\n",
                extra_env={"RUN_TIMESTAMP": "20260529_000000"},
            )

            trashed = root / "media_trash" / str(duplicate).lstrip("/")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(duplicate.exists())
            self.assertTrue(trashed.exists())

            restore_result = run_script(
                "11_restore_from_trash.sh",
                root,
                reports,
                "--confirm",
            )

            self.assertEqual(restore_result.returncode, 0, restore_result.stderr)
            self.assertTrue(duplicate.exists())
            self.assertFalse(trashed.exists())
            self.assertEqual(duplicate.read_bytes(), b"same-photo")


class RestoreFromTrashCollisionTests(unittest.TestCase):
    # Regression tests for issue #102: 11_restore_from_trash.sh --confirm
    # runs its per-file loop under `set -euo pipefail` and moves each file
    # with `mv -n` (no-clobber). On modern coreutils, `mv -n` exits 1 (not
    # 0) when it skips an existing destination. Combined with `set -e`,
    # the very first collision used to kill the whole script immediately,
    # silently leaving every later file in the batch un-restored. Same
    # class of bug as issue #81's czkawka_cli exit-code handling
    # (see CleanupScanExitCodeTests above).
    def test_mid_batch_collision_does_not_abort_restoring_the_rest_of_the_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"

            # Three trashed files: "a" and "c" have a clear destination,
            # "b" collides with a file that already exists at its
            # original path. Alphabetical find/read order means "b" is
            # restored in the middle of the batch, not last.
            before = root / "cleaning_staging" / "a_before.jpg"
            colliding = root / "cleaning_staging" / "b_collides.jpg"
            after = root / "cleaning_staging" / "c_after.jpg"

            trashed_before = root / "media_trash" / str(before).lstrip("/")
            trashed_colliding = root / "media_trash" / str(colliding).lstrip("/")
            trashed_after = root / "media_trash" / str(after).lstrip("/")
            for trashed in (trashed_before, trashed_colliding, trashed_after):
                trashed.parent.mkdir(parents=True, exist_ok=True)
                trashed.write_text("trashed-copy", encoding="utf-8")

            # Something already occupies "colliding"'s original path --
            # this is the collision `mv -n` will skip.
            colliding.parent.mkdir(parents=True, exist_ok=True)
            colliding.write_text("pre-existing-file", encoding="utf-8")

            result = run_script("11_restore_from_trash.sh", root, reports, "--confirm")

            self.assertEqual(result.returncode, 0, result.stderr)
            # Files before AND after the collision were both restored --
            # the batch did not stop at the first collision.
            self.assertTrue(before.exists())
            self.assertTrue(after.exists())
            self.assertFalse(trashed_before.exists())
            self.assertFalse(trashed_after.exists())
            # The collision itself was skipped, not overwritten, and the
            # trashed copy is left in place (not silently lost).
            self.assertEqual(colliding.read_text(encoding="utf-8"), "pre-existing-file")
            self.assertTrue(trashed_colliding.exists())
            self.assertIn(f"Skipped (destination already exists): {colliding}", result.stdout)

    def test_genuine_mv_failure_still_aborts_and_reports_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"

            target = root / "cleaning_staging" / "restored.jpg"
            trashed = root / "media_trash" / str(target).lstrip("/")
            trashed.parent.mkdir(parents=True)
            trashed.write_text("photo", encoding="utf-8")

            # Make the destination directory unwritable so `mv` fails for
            # a real reason (permission denied) rather than a collision --
            # the destination file itself does not exist beforehand. Pre-
            # create the directory so the script's own `mkdir -p` (a no-op
            # on an existing dir) doesn't fail first for the same reason.
            target.parent.mkdir(parents=True)
            target.parent.chmod(0o555)
            try:
                result = run_script(
                    "11_restore_from_trash.sh", root, reports, "--confirm"
                )
            finally:
                # Restore write permission before the tempdir is cleaned
                # up (its own directory removal needs it too).
                target.parent.chmod(0o755)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ERROR: failed to restore", result.stderr)
            self.assertFalse(target.exists())
            self.assertTrue(trashed.exists())


def write_fake_czkawka_tools(root: Path) -> Path:
    """Fake czkawka_cli plus ffmpeg/ffprobe/convert stand-ins, for
    environments without the real Czkawka/FFmpeg/ImageMagick binaries
    installed (05_cleanup_scan.sh hard-requires all four to be on PATH).

    The fake czkawka_cli does real work: it hashes the actual files under
    the given -d directory and writes real duplicate groups to -f, in
    Czkawka's real report format (a "Found N <noun>" header per group,
    followed by quoted absolute paths) -- then exits with czkawka_cli's
    real, fixed exit-code sentinels: 0 when no duplicate group was found,
    11 when at least one was (confirmed against czkawka_cli/src/main.rs
    upstream -- 11 is a fixed "found duplicates" constant, not a variable
    count of how many groups were found, despite how it reads at a
    glance). This means the regression test below exercises the real
    pipefail/PIPESTATUS interaction against planted duplicate files and
    czkawka's real exit-code convention, not a mocked/invented exit code
    (issue #81).
    """
    bin_dir = root / "fakebin"
    bin_dir.mkdir()

    czkawka = bin_dir / "czkawka_cli"
    czkawka.write_text(
        "\n".join(
            [
                "#!/usr/bin/env bash",
                "set -euo pipefail",
                'mode="$1"; shift',
                'dir=""',
                'outfile=""',
                "while [[ $# -gt 0 ]]; do",
                '\tcase "$1" in',
                '\t-d) dir="$2"; shift 2 ;;',
                '\t-f) outfile="$2"; shift 2 ;;',
                "\t*) shift ;;",
                "\tesac",
                "done",
                "",
                'case "$mode" in',
                'image) noun="images" ;;',
                'video) noun="videos" ;;',
                'dup) noun="files" ;;',
                '*) noun="items" ;;',
                "esac",
                "",
                ': > "$outfile"',
                "declare -A groups",
                "while IFS= read -r -d '' f; do",
                "\th=\"$(md5sum \"$f\" | awk '{print $1}')\"",
                "\tgroups[\"$h\"]+=\"$f\"$'\\n'",
                'done < <(find "$dir" -type f -print0)',
                "",
                "count=0",
                'for h in "${!groups[@]}"; do',
                '\tmapfile -t files < <(printf "%s" "${groups[$h]}")',
                '\tif [[ "${#files[@]}" -ge 2 ]]; then',
                "\t\tcount=$((count + 1))",
                '\t\tprintf "Found %d %s in group\\n" "${#files[@]}" "$noun" >>"$outfile"',
                '\t\tfor f in "${files[@]}"; do',
                "\t\t\tprintf '\"%s\" - 10 KiB\\n' \"$f\" >>\"$outfile\"",
                "\t\tdone",
                '\t\tprintf "\\n" >>"$outfile"',
                "\tfi",
                "done",
                "",
                'echo "fake czkawka_cli: mode=$mode dir=$dir groups=$count" >&2',
                "# czkawka_cli's real exit-code convention: 0 = nothing found, 11 =",
                "# a fixed sentinel for \"duplicates found\" (not the group count).",
                'if [[ "$count" -gt 0 ]]; then',
                "\texit 11",
                "fi",
                "exit 0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    czkawka.chmod(0o755)

    for name in ("ffmpeg", "ffprobe", "convert"):
        stub = bin_dir / name
        stub.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        stub.chmod(0o755)

    return bin_dir


class CleanupScanExitCodeTests(unittest.TestCase):
    # Regression test for issue #81: 05_cleanup_scan.sh pipes each
    # czkawka_cli invocation through `tee` under `set -euo pipefail`.
    # czkawka_cli's exit code is 11 (a fixed "found duplicates" sentinel,
    # not a success flag or a variable count), so the script used to abort
    # the moment the *first* scan (image) found any duplicates -- the
    # video scan, exact-duplicate scan, and summary section never ran.
    # This plants real duplicate files (identical bytes) and asserts the
    # script runs every scan and reaches its summary output instead of
    # aborting after the first non-zero exit.
    def test_completes_all_scans_and_reaches_summary_when_duplicates_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            staging = root / "cleaning_staging"
            staging.mkdir(parents=True)

            first = staging / "a.jpg"
            second = staging / "b.jpg"
            first.write_bytes(b"identical-photo-bytes")
            second.write_bytes(b"identical-photo-bytes")

            bin_dir = write_fake_czkawka_tools(root)

            result = run_script(
                "05_cleanup_scan.sh",
                root,
                reports,
                extra_env={
                    "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                    "RUN_BLUR_SCAN": "0",
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            # All three scans ran (not just the first).
            self.assertIn("==> Running Czkawka similar image scan", result.stdout)
            self.assertIn("==> Running Czkawka similar video scan", result.stdout)
            self.assertIn(
                "==> Running Czkawka exact duplicate file scan", result.stdout
            )
            # The found-duplicates sentinel (exit 11) was treated as
            # informational, not fatal.
            self.assertIn(
                "similar image scan: completed, duplicates found (exit 11",
                result.stdout,
            )
            self.assertIn(
                "similar video scan: completed, duplicates found (exit 11",
                result.stdout,
            )
            self.assertIn(
                "exact duplicate file scan: completed, duplicates found (exit 11",
                result.stdout,
            )
            # Execution reached the summary section at the end of the script.
            self.assertIn("==> Summary", result.stdout)
            self.assertIn("Image groups: 1", result.stdout)
            self.assertIn("Video groups: 1", result.stdout)
            self.assertIn("Exact duplicate groups: 1", result.stdout)
            self.assertTrue((reports / "duplicate_images.txt").exists())
            self.assertTrue((reports / "duplicate_videos.txt").exists())
            self.assertTrue((reports / "duplicate_files.txt").exists())

    @staticmethod
    def _write_fake_czkawka_that_exits(root: Path, exit_code: int, stderr_line: str) -> Path:
        """A fakebin with a czkawka_cli stand-in that unconditionally exits
        with the given code (plus ffmpeg/ffprobe/convert stubs), for
        exercising 05_cleanup_scan.sh's fatal-vs-informational exit-code
        handling directly, independent of any found-duplicates logic."""
        bin_dir = root / "fakebin"
        bin_dir.mkdir()
        czkawka = bin_dir / "czkawka_cli"
        czkawka.write_text(
            f"#!/usr/bin/env bash\necho '{stderr_line}' >&2\nexit {exit_code}\n",
            encoding="utf-8",
        )
        czkawka.chmod(0o755)
        for name in ("ffmpeg", "ffprobe", "convert"):
            stub = bin_dir / name
            stub.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            stub.chmod(0o755)
        return bin_dir

    def test_genuine_czkawka_failure_still_aborts_the_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            staging = root / "cleaning_staging"
            staging.mkdir(parents=True)
            (staging / "a.jpg").write_bytes(b"some-bytes")

            # A czkawka_cli stand-in that crashes like an uncaught Rust
            # panic (exit 101) rather than returning the found-duplicates
            # sentinel (11).
            bin_dir = self._write_fake_czkawka_that_exits(
                root, 101, "thread main panicked"
            )

            result = run_script(
                "05_cleanup_scan.sh",
                root,
                reports,
                extra_env={
                    "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                    "RUN_BLUR_SCAN": "0",
                },
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("czkawka_cli failed during", result.stderr)
            # It must not have proceeded past the first (image) scan.
            self.assertNotIn("similar video scan", result.stdout)
            self.assertNotIn("==> Summary", result.stdout)

    def test_signal_death_exit_code_still_aborts_the_script(self):
        # Regression test for the Astrid review finding on PR #83: the
        # original fatal-code allowlist (101/126/127) didn't cover
        # signal-death exit codes -- the standard Unix convention where a
        # process killed by signal N exits with code 128+N. 137 = SIGKILL
        # (most commonly an OOM-kill) and 139 = SIGSEGV are the practically
        # important cases, since czkawka_cli is planned to run inside a
        # memory-limited Docker container (#76/PR #80), where an OOM-kill
        # is a real, not just theoretical, way for a scan to die mid-run.
        # Without this, exit 137 would have been silently classified as
        # "found 137 duplicates" and the truncated report trusted as
        # complete.
        for exit_code, label in ((137, "SIGKILL (simulated OOM-kill)"), (139, "SIGSEGV")):
            with self.subTest(exit_code=exit_code):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    reports = root / "reports"
                    staging = root / "cleaning_staging"
                    staging.mkdir(parents=True)
                    (staging / "a.jpg").write_bytes(b"some-bytes")

                    bin_dir = self._write_fake_czkawka_that_exits(
                        root, exit_code, f"Killed: {label}"
                    )

                    result = run_script(
                        "05_cleanup_scan.sh",
                        root,
                        reports,
                        extra_env={
                            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                            "RUN_BLUR_SCAN": "0",
                        },
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("czkawka_cli failed during", result.stderr)
                    self.assertIn(f"exit {exit_code}", result.stderr)
                    self.assertNotIn("similar video scan", result.stdout)
                    self.assertNotIn("==> Summary", result.stdout)


def write_fake_ffprobe(root: Path) -> Path:
    """A stand-in for ffprobe so tests don't need real encoded media or a
    real ffprobe binary on the test runner.

    Reads a marker from the first line of the target file:
      - "DURATION=<seconds>" -> prints that duration, like real ffprobe would
      - "UNKNOWN"            -> exits non-zero with no stdout, simulating
                                 ffprobe being unable to determine a duration
    """
    fake = root / "fake_ffprobe.sh"
    fake.write_text(
        "\n".join(
            [
                "#!/usr/bin/env bash",
                'file="${@: -1}"',
                'first_line="$(head -n1 "$file" 2>/dev/null || true)"',
                'case "$first_line" in',
                'DURATION=*) echo "${first_line#DURATION=}" ;;',
                "UNKNOWN) exit 1 ;;",
                '*) echo "1.500000" ;;',
                "esac",
                "",
            ]
        ),
        encoding="utf-8",
    )
    fake.chmod(0o755)
    return fake


class LivePhotoDedupeTests(unittest.TestCase):
    def test_dry_run_verifies_short_pair_and_reports_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            fake_ffprobe = write_fake_ffprobe(root)
            lib_dir = root / "immich_library" / "Takeout" / "Album"
            lib_dir.mkdir(parents=True)
            still = lib_dir / "IMG_1234.HEIC"
            video = lib_dir / "IMG_1234.MOV"
            still.write_text("still-bytes", encoding="utf-8")
            video.write_text("DURATION=2.000000\n", encoding="utf-8")

            result = run_script(
                "13_dedupe_live_photos.sh",
                root,
                reports,
                extra_env={"FFPROBE_BIN": str(fake_ffprobe)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                f"Would move standalone Live Photo video (duration 2.000000s): {video}",
                result.stdout,
            )
            self.assertIn(f"Kept still: {still}", result.stdout)
            self.assertIn("Verified pairs:           1", result.stdout)
            self.assertIn("Moved to trash:            0", result.stdout)
            self.assertTrue(video.exists())
            self.assertTrue(still.exists())

    def test_dry_run_skips_video_over_duration_threshold(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            fake_ffprobe = write_fake_ffprobe(root)
            lib_dir = root / "immich_library"
            lib_dir.mkdir(parents=True)
            still = lib_dir / "IMG_9999.HEIC"
            video = lib_dir / "IMG_9999.MOV"
            still.write_text("still-bytes", encoding="utf-8")
            # A real, unrelated multi-minute video that happens to share a basename.
            video.write_text("DURATION=612.000000\n", encoding="utf-8")

            result = run_script(
                "13_dedupe_live_photos.sh",
                root,
                reports,
                extra_env={"FFPROBE_BIN": str(fake_ffprobe)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                f"Video too long (612.000000s > 5s), skipping: {video}", result.stdout
            )
            self.assertIn("Verified pairs:           0", result.stdout)
            self.assertNotIn("Would move standalone Live Photo video", result.stdout)
            self.assertTrue(video.exists())

    def test_dry_run_skips_video_with_no_paired_still(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            fake_ffprobe = write_fake_ffprobe(root)
            lib_dir = root / "immich_library"
            lib_dir.mkdir(parents=True)
            video = lib_dir / "IMG_5555.MOV"
            video.write_text("DURATION=2.000000\n", encoding="utf-8")

            result = run_script(
                "13_dedupe_live_photos.sh",
                root,
                reports,
                extra_env={"FFPROBE_BIN": str(fake_ffprobe)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"No paired still for video, skipping: {video}", result.stdout)
            self.assertIn("Missing paired still:     1", result.stdout)
            self.assertTrue(video.exists())

    def test_dry_run_falls_back_to_timestamp_proximity_when_duration_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            fake_ffprobe = write_fake_ffprobe(root)
            lib_dir = root / "immich_library"
            lib_dir.mkdir(parents=True)

            close_still = lib_dir / "IMG_0001.HEIC"
            close_video = lib_dir / "IMG_0001.MOV"
            close_still.write_text("still", encoding="utf-8")
            close_video.write_text("UNKNOWN\n", encoding="utf-8")
            close_time = 1_800_000_000.0
            os.utime(close_still, (close_time, close_time))
            os.utime(close_video, (close_time, close_time))

            far_still = lib_dir / "IMG_0002.HEIC"
            far_video = lib_dir / "IMG_0002.MOV"
            far_still.write_text("still", encoding="utf-8")
            far_video.write_text("UNKNOWN\n", encoding="utf-8")
            os.utime(far_still, (close_time, close_time))
            os.utime(far_video, (close_time + 300, close_time + 300))

            result = run_script(
                "13_dedupe_live_photos.sh",
                root,
                reports,
                extra_env={"FFPROBE_BIN": str(fake_ffprobe)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                f"Would move standalone Live Photo video (duration unknown, "
                f"timestamps 0s apart): {close_video}",
                result.stdout,
            )
            self.assertIn(
                f"Duration unknown and timestamps not close enough, skipping: {far_video}",
                result.stdout,
            )
            self.assertIn("Verified pairs:           1", result.stdout)
            self.assertIn("Skipped, ambiguous match: 1", result.stdout)

    def test_confirm_requires_typed_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            fake_ffprobe = write_fake_ffprobe(root)
            lib_dir = root / "immich_library"
            lib_dir.mkdir(parents=True)
            still = lib_dir / "IMG_1234.HEIC"
            video = lib_dir / "IMG_1234.MOV"
            still.write_text("still-bytes", encoding="utf-8")
            video.write_text("DURATION=2.000000\n", encoding="utf-8")

            result = run_script(
                "13_dedupe_live_photos.sh",
                root,
                reports,
                "--confirm",
                input_text="wrong phrase\n",
                extra_env={"FFPROBE_BIN": str(fake_ffprobe)},
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("Confirmation phrase did not match", result.stdout)
            self.assertTrue(still.exists())
            self.assertTrue(video.exists())

    def test_confirm_moves_verified_video_to_trash_and_restore_reverses_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            fake_ffprobe = write_fake_ffprobe(root)
            lib_dir = root / "immich_library" / "Takeout" / "Album"
            lib_dir.mkdir(parents=True)
            still = lib_dir / "IMG_1234.HEIC"
            video = lib_dir / "IMG_1234.MOV"
            still.write_text("still-bytes", encoding="utf-8")
            video.write_text("DURATION=2.000000\n", encoding="utf-8")

            result = run_script(
                "13_dedupe_live_photos.sh",
                root,
                reports,
                "--confirm",
                input_text="MOVE LIVE PHOTO VIDEOS\n",
                extra_env={
                    "FFPROBE_BIN": str(fake_ffprobe),
                    "RUN_TIMESTAMP": "20260529_000000",
                },
            )

            trashed = root / "media_trash" / str(video).lstrip("/")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(still.exists())
            self.assertFalse(video.exists())
            self.assertTrue(trashed.exists())
            self.assertEqual(trashed.read_text(encoding="utf-8"), "DURATION=2.000000\n")

            restore_result = run_script(
                "11_restore_from_trash.sh",
                root,
                reports,
                "--confirm",
            )

            self.assertEqual(restore_result.returncode, 0, restore_result.stderr)
            self.assertTrue(video.exists())
            self.assertFalse(trashed.exists())
            self.assertEqual(video.read_text(encoding="utf-8"), "DURATION=2.000000\n")


if __name__ == "__main__":
    unittest.main()

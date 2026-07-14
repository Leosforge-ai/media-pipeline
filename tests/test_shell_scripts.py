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

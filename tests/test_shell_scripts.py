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

            trashed = (
                root
                / "media_trash"
                / "immich_library_fotos_de_duplicates_20260529_000000"
                / "Takeout"
                / "Google Fotos"
                / "Fotos de 2024"
                / "IMG_1951.HEIC"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(canonical.exists())
            self.assertFalse(duplicate.exists())
            self.assertTrue(trashed.exists())
            self.assertEqual(trashed.read_bytes(), b"same-photo")


if __name__ == "__main__":
    unittest.main()

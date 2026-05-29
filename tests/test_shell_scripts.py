from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run_script(script: str, hd_path: Path, report_dir: Path, *args: str):
    env = {
        **os.environ,
        "HD_PATH": str(hd_path),
        "REPORT_DIR": str(report_dir),
    }
    return subprocess.run(
        ["bash", str(ROOT / "scripts" / script), *args],
        cwd=ROOT,
        env=env,
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


if __name__ == "__main__":
    unittest.main()

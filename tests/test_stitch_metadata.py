from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "04_stitch_metadata.py"


def load_stitch_module(hd_path: Path):
    sys.modules.pop("pipeline_config", None)
    spec = importlib.util.spec_from_file_location("stitch_metadata_under_test", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load stitch metadata module")
    module = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, {"HD_PATH": str(hd_path)}, clear=False):
        spec.loader.exec_module(module)
    return module


class StitchMetadataTests(unittest.TestCase):
    def test_candidate_jsons_include_exact_supplemental_and_truncated_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            module = load_stitch_module(Path(tmp))
            album = Path(tmp) / "album"
            album.mkdir()
            media = album / "IMG_20200101_abcdefghijklmnopqrstuvwxyzzzzzzzzzz.jpg"
            media.write_bytes(b"image")

            expected = [
                album / f"{media.name}.json",
                album / f"{media.stem}.json",
                album / f"{media.name}.supplemental-metadata.json",
                album / f"{media.stem}.supplemental-metadata.json",
                album / f"{media.name[:45]}-truncated.json",
            ]
            for path in expected:
                path.write_text("{}", encoding="utf-8")

            self.assertEqual(module.candidate_jsons_for_media(media), expected)

    def test_extract_timestamp_uses_google_photo_taken_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            module = load_stitch_module(Path(tmp))

            self.assertEqual(
                module.extract_timestamp({"photoTakenTime": {"timestamp": "0"}}),
                "1970:01:01 00:00:00",
            )
            self.assertIsNone(
                module.extract_timestamp({"photoTakenTime": {"timestamp": "bad"}})
            )

    def test_safe_extract_zip_blocks_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            module = load_stitch_module(Path(tmp))
            root = Path(tmp)
            archive = root / "takeout.zip"
            dest = root / "dest"
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("../evil.jpg", b"not safe")

            with self.assertRaises(RuntimeError):
                module.safe_extract_zip(archive, dest)

            self.assertFalse((root.parent / "evil.jpg").exists())

    def test_move_to_staging_renames_colliding_media(self):
        with tempfile.TemporaryDirectory() as tmp:
            module = load_stitch_module(Path(tmp))
            extracted = Path(tmp) / "takeout"
            source_dir = extracted / "Google Photos"
            source_dir.mkdir(parents=True)
            media = source_dir / "photo.jpg"
            media.write_bytes(b"new")

            existing = Path(tmp) / "cleaning_staging" / "Google Photos" / "photo.jpg"
            existing.parent.mkdir(parents=True)
            existing.write_bytes(b"existing")

            moved = module.move_to_staging(media, extracted)

            self.assertEqual(moved.name, "photo_1.jpg")
            self.assertTrue(moved.exists())
            self.assertFalse(media.exists())
            self.assertEqual(existing.read_bytes(), b"existing")


if __name__ == "__main__":
    unittest.main()

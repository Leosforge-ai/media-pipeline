"""Shared Python configuration for the media pipeline."""
from __future__ import annotations

import os
from pathlib import Path

DRIVE_NAME = os.environ.get("DRIVE_NAME", "target_drive")
MOUNT_ROOT = Path(os.environ.get("MOUNT_ROOT", "/mnt"))
HD_PATH = Path(os.environ.get("HD_PATH", str(MOUNT_ROOT / DRIVE_NAME)))

RAW_GDRIVE = HD_PATH / "raw_gdrive"
RAW_TAKEOUT_ZIPS = HD_PATH / "raw_takeout_zips"
TAKEOUT_EXTRACTED = HD_PATH / "takeout_extracted"
CLEANING_STAGING = HD_PATH / "cleaning_staging"
MEDIA_TRASH = HD_PATH / "media_trash"
IMMICH_LIBRARY = HD_PATH / "immich_library"
IMMICH_APP = HD_PATH / "immich_app"
REPORT_DIR = Path(os.environ.get("REPORT_DIR", str(Path.home() / "czkawka_reports")))

MEDIA_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif",
    ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".3gp", ".webm",
}

JSON_EXTENSIONS = {".json"}

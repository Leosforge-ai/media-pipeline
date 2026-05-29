#!/usr/bin/env python3
"""
Extract Google Photos Takeout archives, stitch JSON sidecar metadata into media
files with exiftool, and move the media into cleaning_staging.

Safety model:
- Processes one archive at a time.
- Continues past corrupt/unwritable media files, logging warnings.
- Deletes an archive only after extraction + staging completes for that archive.
- Never deletes staged media.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tarfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

# Allow running from scripts/ without installing as a package
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "config"))
from pipeline_config import (  # noqa: E402
    RAW_GDRIVE,
    RAW_TAKEOUT_ZIPS,
    TAKEOUT_EXTRACTED,
    CLEANING_STAGING,
    HD_PATH,
    MEDIA_EXTENSIONS,
)

WARNING_LOG = HD_PATH / "stitch_metadata_warnings.md"


def log_warning(message: str) -> None:
    WARNING_LOG.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat()
    with WARNING_LOG.open("a", encoding="utf-8") as f:
        f.write(f"- {stamp} — {message}\n")
    print(f"WARNING: {message}", file=sys.stderr)


def is_media_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS


def archive_stem(path: Path) -> str:
    name = path.name
    for suffix in (".tar.gz", ".tgz", ".zip"):
        if name.lower().endswith(suffix):
            return name[: -len(suffix)]
    return path.stem


def safe_extract_zip(archive: Path, dest: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        for member in zf.infolist():
            out = dest / member.filename
            if not str(out.resolve()).startswith(str(dest.resolve())):
                raise RuntimeError(f"Blocked unsafe zip path: {member.filename}")
        zf.extractall(dest)


def safe_extract_tar(archive: Path, dest: Path) -> None:
    with tarfile.open(archive) as tf:
        for member in tf.getmembers():
            out = dest / member.name
            if not str(out.resolve()).startswith(str(dest.resolve())):
                raise RuntimeError(f"Blocked unsafe tar path: {member.name}")
        tf.extractall(dest)


def extract_archive(archive: Path, dest: Path) -> None:
    print(f"==> Extracting {archive.name} -> {dest}")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)

    lname = archive.name.lower()
    if lname.endswith(".zip"):
        safe_extract_zip(archive, dest)
    elif lname.endswith(".tgz") or lname.endswith(".tar.gz"):
        safe_extract_tar(archive, dest)
    else:
        raise RuntimeError(f"Unsupported archive type: {archive}")


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def candidate_jsons_for_media(media: Path) -> list[Path]:
    """Return likely Google Photos JSON sidecars for a media file."""
    parent = media.parent
    name = media.name
    stem = media.stem
    candidates = [
        parent / f"{name}.json",
        parent / f"{stem}.json",
        parent / f"{name}.supplemental-metadata.json",
        parent / f"{stem}.supplemental-metadata.json",
    ]
    # Google truncates long names in sidecar names. Add loose candidates.
    candidates.extend(parent.glob(f"{name[:45]}*.json"))
    candidates.extend(parent.glob(f"{stem[:45]}*.json"))
    seen: set[Path] = set()
    result: list[Path] = []
    for p in candidates:
        if p.exists() and p not in seen:
            seen.add(p)
            result.append(p)
    return result


def extract_timestamp(meta: dict) -> str | None:
    for key in ("photoTakenTime", "creationTime"):
        obj = meta.get(key)
        if isinstance(obj, dict) and obj.get("timestamp"):
            try:
                ts = int(obj["timestamp"])
                return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y:%m:%d %H:%M:%S")
            except Exception:
                return None
    return None


def apply_metadata_with_exiftool(media: Path, json_path: Path) -> bool:
    try:
        meta = load_json(json_path)
    except Exception as exc:
        log_warning(f"Could not read JSON sidecar {json_path}: {exc}")
        return False

    args = ["exiftool", "-overwrite_original"]
    dt = extract_timestamp(meta)
    if dt:
        args.extend([f"-DateTimeOriginal={dt}", f"-CreateDate={dt}", f"-ModifyDate={dt}"])

    title = meta.get("title")
    description = meta.get("description")
    if title:
        args.append(f"-Title={title}")
    if description:
        args.append(f"-Description={description}")

    geo = meta.get("geoData") or meta.get("geoDataExif") or {}
    lat = geo.get("latitude")
    lon = geo.get("longitude")
    if isinstance(lat, (int, float)) and isinstance(lon, (int, float)) and (lat != 0 or lon != 0):
        args.extend([f"-GPSLatitude={lat}", f"-GPSLongitude={lon}"])
        args.extend(["-GPSLatitudeRef=N" if lat >= 0 else "-GPSLatitudeRef=S"])
        args.extend(["-GPSLongitudeRef=E" if lon >= 0 else "-GPSLongitudeRef=W"])

    if len(args) == 3:  # only exiftool -overwrite_original and no useful tags
        return False

    args.append(str(media))
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        log_warning(f"exiftool failed for {media} using {json_path}: {proc.stderr.strip() or proc.stdout.strip()}")
        return False
    return True


def move_to_staging(media: Path, extracted_root: Path) -> Path:
    try:
        rel = media.relative_to(extracted_root)
    except ValueError:
        rel = Path(media.name)
    dest = CLEANING_STAGING / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        base = dest.with_suffix("")
        suffix = dest.suffix
        i = 1
        while True:
            candidate = Path(f"{base}_{i}{suffix}")
            if not candidate.exists():
                dest = candidate
                break
            i += 1
    shutil.move(str(media), str(dest))
    return dest


def process_extracted_tree(extracted_root: Path) -> tuple[int, int]:
    media_files = sorted([p for p in extracted_root.rglob("*") if is_media_file(p)])
    processed = 0
    warnings = 0
    print(f"==> Found {len(media_files)} media files in {extracted_root.name}")

    for media in media_files:
        jsons = candidate_jsons_for_media(media)
        if jsons:
            ok = False
            for js in jsons:
                if apply_metadata_with_exiftool(media, js):
                    ok = True
                    break
            if not ok:
                warnings += 1
                log_warning(f"Media file had sidecar(s), but metadata was not applied: {media}")
        else:
            warnings += 1
            log_warning(f"Media file had no matched/processed JSON sidecar. Moving original file: {media}")
        move_to_staging(media, extracted_root)
        processed += 1
    return processed, warnings


def supported_archives() -> list[Path]:
    patterns = ["*.zip", "*.tgz", "*.tar.gz"]
    found: list[Path] = []
    for pat in patterns:
        found.extend(RAW_TAKEOUT_ZIPS.glob(pat))
    return sorted(set(found))


def merge_raw_gdrive() -> None:
    if not RAW_GDRIVE.exists():
        return
    if not any(RAW_GDRIVE.iterdir()):
        print("==> raw_gdrive is empty; skipping Google Drive merge")
        return
    print(f"==> Merging raw Google Drive media: {RAW_GDRIVE} -> {CLEANING_STAGING}")
    CLEANING_STAGING.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "rsync", "-a", "--ignore-existing", f"{RAW_GDRIVE}/", f"{CLEANING_STAGING}/"
    ], check=True)


def main() -> None:
    for d in (RAW_TAKEOUT_ZIPS, TAKEOUT_EXTRACTED, CLEANING_STAGING):
        d.mkdir(parents=True, exist_ok=True)

    WARNING_LOG.write_text("# Metadata stitching warnings\n\n", encoding="utf-8")

    archives = supported_archives()
    if not archives:
        print(f"==> No supported archives found in {RAW_TAKEOUT_ZIPS}")
    else:
        print(f"==> Processing {len(archives)} archive(s)")

    total = 0
    warn = 0
    for archive in archives:
        dest = TAKEOUT_EXTRACTED / archive_stem(archive)
        try:
            extract_archive(archive, dest)
            processed, warnings = process_extracted_tree(dest)
            total += processed
            warn += warnings
            print(f"==> Archive complete: {archive.name}; media moved: {processed}; warnings: {warnings}")
            archive.unlink()
            print(f"==> Deleted processed archive: {archive}")
        except Exception as exc:
            log_warning(f"Archive failed and was kept for retry: {archive}: {exc}")
            raise
        finally:
            if dest.exists():
                shutil.rmtree(dest, ignore_errors=True)

    merge_raw_gdrive()
    print(f"==> Metadata stitching complete. Media moved from Takeout: {total}; warnings: {warn}")
    print(f"==> Staging folder: {CLEANING_STAGING}")
    print(f"==> Warning log: {WARNING_LOG}")


if __name__ == "__main__":
    main()

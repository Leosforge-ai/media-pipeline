# Immich External Library Setup

This pipeline keeps Immich's own upload storage separate from the cleaned media library.

Container paths:

```text
/data      Immich upload/storage folder
/library   cleaned media library, mounted read-only
```

Host paths:

```text
/mnt/target_drive/immich_app/upload    -> /data
/mnt/target_drive/immich_library       -> /library:ro
```

## Start Immich

```bash
./scripts/09_setup_immich.sh
```

Open:

```text
http://localhost:2283
```

## Add external library

In Immich UI:

```text
Administration -> External Libraries -> New External Library
```

Add folder:

```text
/library
```

Do not add `/data`.

Then select:

```text
Scan All Library Files
```

## Clean Takeout localized year duplicates

If the external library contains both canonical Google Photos year folders and
localized copies, Immich will scan both paths as separate assets:

```text
/library/Takeout/Google Fotos/2024/IMG_1951.HEIC
/library/Takeout/Google Fotos/Fotos de 2024/IMG_1951.HEIC
```

Fix this in the filesystem before or between Immich scans. Do not rely on
thumbnail generation, metadata extraction, OCR, face detection, transcoding, or
the Immich duplicate review page to clean up duplicate source files.

Dry-run the targeted cleanup:

```bash
./scripts/12_clean_immich_takeout_duplicates.sh | tee /tmp/immich_takeout_duplicates_dry_run.txt
```

The script only targets direct files under:

```text
/mnt/target_drive/immich_library/Takeout/Google Fotos/Fotos de YYYY/
```

It keeps the matching canonical file under:

```text
/mnt/target_drive/immich_library/Takeout/Google Fotos/YYYY/
```

A file is moved only when the canonical file exists with the same basename,
same size, and same SHA-256 hash. Confirm mode still never deletes files; it
mirrors each duplicate's full original absolute path under `media_trash`
(the same layout `06_delete_duplicates.sh` and `13_dedupe_live_photos.sh`
use), so `11_restore_from_trash.sh` can reverse the move.

Before confirm mode:

1. Stop Immich.
2. Inspect the dry-run output.
3. Run confirm mode only if the plan is correct:

```bash
./scripts/12_clean_immich_takeout_duplicates.sh --confirm
```

After confirm mode:

1. Restart Immich.
2. Rescan the external library path:

```text
/library
```

## Verify from shell

```bash
./scripts/10_verify_immich.sh
```

## If thumbnails do not load

Wait for Jobs to finish:

```text
Administration -> Jobs
```

Check logs:

```bash
cd /mnt/target_drive/immich_app
docker compose logs -f immich-server
```

Fix permissions:

```bash
sudo chmod -R a+rX /mnt/target_drive/immich_library
cd /mnt/target_drive/immich_app
docker compose restart immich-server
```

# Troubleshooting

## External drive is not visible in Ubuntu Files

Check whether Linux sees it:

```bash
lsblk -f
findmnt | grep target_drive || true
```

If it is mounted at `/mnt/target_drive`, open it directly:

```bash
nautilus /mnt/target_drive
```

To make it appear more naturally in the sidebar, mount under `/media/$USER/DATA`:

```bash
sync
sudo umount /mnt/target_drive
sudo mkdir -p "/media/$USER/DATA"
sudo mount /dev/sda1 "/media/$USER/DATA"
nautilus "/media/$USER/DATA"
```

Replace `/dev/sda1` with your partition.

---

## Permission problems opening files

```bash
sudo chmod -R a+rX /mnt/target_drive/cleaning_staging
sudo chmod -R a+rX /mnt/target_drive/immich_library
```

For files you personally need to edit:

```bash
sudo chown -R "$USER:$USER" /mnt/target_drive/review_examples
```

---

## Takeout archives are `.tgz`, not `.zip`

Supported by `04_stitch_metadata.py`:

```text
.zip
.tgz
.tar.gz
```

Put them in:

```text
/mnt/target_drive/raw_takeout_zips
```

---

## Metadata script stops on a broken video

The included script logs exiftool errors and continues. Check:

```bash
less /mnt/target_drive/stitch_metadata_warnings.md
```

---

## Czkawka command says flags are invalid

Use the included `05_cleanup_scan.sh`, which uses Czkawka CLI syntax:

```bash
czkawka_cli image -d PATH -f REPORT
czkawka_cli video -d PATH -f REPORT
czkawka_cli dup -d PATH -f REPORT
```

---

## Video scan says FFmpeg or FFprobe missing

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg
ffmpeg -version | head -n 1
ffprobe -version | head -n 1
```

Then rerun:

```bash
./scripts/05_cleanup_scan.sh
```

---

## Czkawka video scan produces warnings like “Failed to hash file”

Some videos may be corrupt or unsupported for perceptual video hashing. The workflow also runs exact duplicate scanning:

```bash
czkawka_cli dup -d /mnt/target_drive/cleaning_staging -f ~/czkawka_reports/duplicate_files.txt
```

This catches byte-identical duplicates even if video similarity hashing fails.

---

## Delete dry-run tries to trash report headers

Stop immediately. Do not run `--confirm`.

Safety check:

```bash
grep -E 'Would trash: Results|Would trash: Found|Would trash: [0-9]+ .*similar friends|Would trash: .* - [0-9]+x' /tmp/delete_dry_run_v2.txt | head
```

Expected: no output.

If it outputs anything, replace the delete script with the one in this repository and rerun dry-run.

---

## Immich says `/data` is invalid for an external library

Correct. `/data` is Immich's upload folder. Use `/library`.

The compose file should mount:

```yaml
- ${UPLOAD_LOCATION}:/data
- /mnt/target_drive/immich_library:/library:ro
```

In the UI, add external library path:

```text
/library
```

---

## Immich finds assets but says “Error loading image”

Check that the container can read the files:

```bash
cd /mnt/target_drive/immich_app
docker compose exec immich-server find /library -type f | wc -l
docker compose exec immich-server sh -c 'f=$(find /library -type f | head -n 1); echo "$f"; ls -lh "$f"; head -c 10 "$f" >/dev/null && echo read-ok'
```

Fix permissions:

```bash
sudo chmod -R a+rX /mnt/target_drive/immich_library
cd /mnt/target_drive/immich_app
docker compose restart immich-server
```

Then check Jobs in Immich:

```text
Administration -> Jobs
```

Run thumbnail/preview/metadata jobs if needed.

---

## Immich sees zero files in `/library`

Check the Docker mount:

```bash
cd /mnt/target_drive/immich_app
docker inspect immich_server --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker compose exec immich-server ls -lah /library
docker compose exec immich-server find /library -type f | wc -l
```

If `/library` does not exist, recreate containers:

```bash
cd /mnt/target_drive/immich_app
docker compose down
docker compose up -d
```

---

## Immich shows duplicate assets after external-library scan

Check whether the duplicate assets come from real duplicate files in the
external library. Google Photos Takeout can create both canonical and localized
year folders:

```text
/mnt/target_drive/immich_library/Takeout/Google Fotos/2024/IMG_1951.HEIC
/mnt/target_drive/immich_library/Takeout/Google Fotos/Fotos de 2024/IMG_1951.HEIC
```

Immich scans external-library files from disk, so both paths can appear as
separate timeline assets. Do not expect Immich jobs such as thumbnails,
metadata extraction, OCR, face detection, or transcoding to remove duplicate
source files.

Dry-run the conservative cleanup:

```bash
./scripts/12_clean_immich_takeout_duplicates.sh | tee /tmp/immich_takeout_duplicates_dry_run.txt
```

The script only considers direct files under:

```text
Takeout/Google Fotos/Fotos de YYYY/
```

It moves nothing unless a matching canonical file exists under:

```text
Takeout/Google Fotos/YYYY/
```

The files must have the same basename, same size, and same SHA-256 hash.

If the dry-run is correct:

```bash
cd /mnt/target_drive/immich_app
docker compose down
cd /path/to/media-pipeline
./scripts/12_clean_immich_takeout_duplicates.sh --confirm
cd /mnt/target_drive/immich_app
docker compose up -d
```

Then rescan the external library path in Immich:

```text
/library
```

Do not use this script for `Destaques/`, `Albums/`, wedding folders, Google
Drive folders, or custom folders. Those need a separate report because they
may contain unique files or album-only copies.

---

## Immich environment changes do not apply

Recreate containers:

```bash
cd /mnt/target_drive/immich_app
docker compose up -d --force-recreate
```

---

## Restore duplicates from media_trash

Dry-run:

```bash
./scripts/11_restore_from_trash.sh | tee /tmp/restore_dry_run.txt
```

Confirm only after inspection:

```bash
./scripts/11_restore_from_trash.sh --confirm
```

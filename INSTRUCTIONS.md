# Detailed Instructions

These instructions walk through the full workflow from an empty external drive to a cleaned Immich library.

> **Read this first:** do not run any `--confirm` command until you have inspected the dry-run output. The pipeline is designed to be reversible, but only if you keep `media_trash` and avoid deleting backups too early.

---

## 0. Assumptions

Default drive path:

```text
/mnt/target_drive
```

Default final folders:

```text
/mnt/target_drive/cleaning_staging
/mnt/target_drive/media_trash
/mnt/target_drive/immich_library
/mnt/target_drive/immich_app
```

To use a different drive path:

```bash
export HD_PATH=/your/drive/path
```

Then run scripts from the repository root.

---

## 1. Mount the external drive

Find the drive:

```bash
lsblk -f
```

Example output:

```text
sda
└─sda1 ext4 DATA
```

Mount it:

```bash
sudo mkdir -p /mnt/target_drive
sudo mount /dev/sda1 /mnt/target_drive
```

Replace `/dev/sda1` with your actual partition.

Verify:

```bash
findmnt /mnt/target_drive
df -h /mnt/target_drive
```

## Optional desktop app

The Flutter desktop app can run the same guarded workflow with path settings,
step status, and live log output:

```bash
flutter pub get
flutter run -d linux
```

ChromeOS support means running the Linux target inside the ChromeOS Linux
development environment. macOS and Windows builds can launch the app, but
Linux-only dependency installation and Immich setup steps remain guarded.

Open in Ubuntu Files:

```bash
nautilus /mnt/target_drive
```

---

## 2. Install dependencies

From the repo root:

```bash
./scripts/00_check_system.sh
./scripts/01_setup_dependencies.sh
```

If Docker was newly installed, log out and back in, or run:

```bash
newgrp docker
```

Verify:

```bash
./scripts/00_check_system.sh
```

You should see `OK` for the major tools, including `exiftool`, `ffmpeg`, `ffprobe`, `convert`, `docker`, and `czkawka_cli`.

---

## 3. Prepare Google Photos Takeout archives

Copy your Google Photos Takeout archives into:

```text
/mnt/target_drive/raw_takeout_zips
```

Supported archive types:

```text
.zip
.tgz
.tar.gz
```

Verify:

```bash
ls -lh /mnt/target_drive/raw_takeout_zips
```

---

## 4. Configure Google Drive import with rclone

Configure rclone:

```bash
./scripts/02_configure_rclone.sh
```

Use remote name:

```text
gdrive
```

List Google Drive folders:

```bash
rclone lsf gdrive: --dirs-only
```

Import folders by name:

```bash
./scripts/03_import_gdrive.sh "Fotos" "Wedding "
```

Important: quote names, especially if they contain spaces or trailing spaces.

Verify:

```bash
du -sh /mnt/target_drive/raw_gdrive
find /mnt/target_drive/raw_gdrive -type f | wc -l
```

---

## 5. Stitch Google Photos metadata and stage media

Run:

```bash
./scripts/04_stitch_metadata.py
```

What it does:

- extracts one Takeout archive at a time,
- finds media files,
- finds matching JSON sidecars,
- writes metadata using `exiftool`,
- logs warnings instead of stopping on broken files,
- moves media into `cleaning_staging`,
- merges `raw_gdrive` into `cleaning_staging`,
- removes processed archives only after successful processing.

Verify:

```bash
du -sh /mnt/target_drive/cleaning_staging
find /mnt/target_drive/cleaning_staging -type f | wc -l
ls -lh /mnt/target_drive/stitch_metadata_warnings.md
```

Optional extension summary:

```bash
find /mnt/target_drive/cleaning_staging -type f \
  | sed 's/.*\.//' \
  | tr '[:upper:]' '[:lower:]' \
  | sort | uniq -c | sort -nr | head -n 30
```

---

## 6. Scan duplicates and blur candidates

Run:

```bash
./scripts/05_cleanup_scan.sh
```

Reports are created in:

```text
~/czkawka_reports
```

Key reports:

```text
duplicate_images.txt        similar images
duplicate_videos.txt        similar videos
duplicate_files.txt         exact duplicate files
blurry_images.txt           optional blur candidates
*_run.log                   logs
```

Monitor while running:

```bash
watch -n 10 'pgrep -af "czkawka_cli|ffmpeg|ffprobe" || echo "not running"; echo; ls -lh ~/czkawka_reports; echo; wc -l ~/czkawka_reports/*.txt 2>/dev/null'
```

Verify after completion:

```bash
ls -lh ~/czkawka_reports
head -n 40 ~/czkawka_reports/duplicate_images.txt
head -n 40 ~/czkawka_reports/duplicate_videos.txt
grep -c '^Found .*videos' ~/czkawka_reports/duplicate_videos.txt
grep -c 'Failed to hash file' ~/czkawka_reports/video_scan_run.log
```

---

## 7. Dry-run duplicate removal

Run dry-run only:

```bash
./scripts/06_delete_duplicates.sh | tee /tmp/delete_dry_run_v2.txt
```

Count keep/trash lines:

```bash
grep -c '^Keep:' /tmp/delete_dry_run_v2.txt
grep -c '^Would trash:' /tmp/delete_dry_run_v2.txt
```

Parser safety check:

```bash
grep -E 'Would trash: Results|Would trash: Found|Would trash: [0-9]+ .*similar friends|Would trash: .* - [0-9]+x' /tmp/delete_dry_run_v2.txt | head
```

Expected result: **no output**.

Inspect examples:

```bash
head -n 120 /tmp/delete_dry_run_v2.txt
grep -m 30 '^Keep:' /tmp/delete_dry_run_v2.txt
grep -m 30 '^Would trash:' /tmp/delete_dry_run_v2.txt
```

Check video behavior:

```bash
grep -iE '\.(mp4|mov)$' /tmp/delete_dry_run_v2.txt | head -n 80
grep -icE '^Would trash: .*\.(mp4|mov)$' /tmp/delete_dry_run_v2.txt
```

Estimate size that would be moved:

```bash
grep '^Would trash:' /tmp/delete_dry_run_v2.txt \
  | sed 's/^Would trash: //' \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
  | du --files0-from=- -ch 2>/dev/null | tail -n 1
```

---

## 8. Optional: copy review examples for visual inspection

```bash
mkdir -p /mnt/target_drive/review_examples/videos_keep
mkdir -p /mnt/target_drive/review_examples/videos_trash
mkdir -p /mnt/target_drive/review_examples/images_keep
mkdir -p /mnt/target_drive/review_examples/images_trash

grep -iE '^Keep: .*\.(mp4|mov)$' /tmp/delete_dry_run_v2.txt | head -n 20 | sed 's/^Keep: //' | while IFS= read -r f; do [ -f "$f" ] && cp -n "$f" /mnt/target_drive/review_examples/videos_keep/; done

grep -iE '^Would trash: .*\.(mp4|mov)$' /tmp/delete_dry_run_v2.txt | head -n 20 | sed 's/^Would trash: //' | while IFS= read -r f; do [ -f "$f" ] && cp -n "$f" /mnt/target_drive/review_examples/videos_trash/; done

grep -iE '^Keep: .*\.(jpg|jpeg|png|heic)$' /tmp/delete_dry_run_v2.txt | head -n 30 | sed 's/^Keep: //' | while IFS= read -r f; do [ -f "$f" ] && cp -n "$f" /mnt/target_drive/review_examples/images_keep/; done

grep -iE '^Would trash: .*\.(jpg|jpeg|png|heic)$' /tmp/delete_dry_run_v2.txt | head -n 30 | sed 's/^Would trash: //' | while IFS= read -r f; do [ -f "$f" ] && cp -n "$f" /mnt/target_drive/review_examples/images_trash/; done
```

Open:

```bash
nautilus /mnt/target_drive/review_examples
```

---

## 9. Move duplicates into media_trash

> **High-risk step. Read carefully.**
>
> This does not permanently delete files, but it moves many files out of the cleaned library. Do not run it until the dry-run looks correct.

Save dry-run:

```bash
cp /tmp/delete_dry_run_v2.txt "$HOME/czkawka_reports/delete_dry_run_v2.txt"
```

Optional confirmation command:

```bash
./scripts/06_delete_duplicates.sh --confirm | tee "$HOME/czkawka_reports/delete_confirm.txt"
```

This command is intentionally not run automatically by any script.

Verify after confirmation:

```bash
du -sh /mnt/target_drive/cleaning_staging
du -sh /mnt/target_drive/media_trash
find /mnt/target_drive/cleaning_staging -type f | wc -l
find /mnt/target_drive/media_trash -type f | wc -l
```

Keep `media_trash` for a while. Do not delete it until you have verified Immich and spot-checked the library.

---

## 10. Sync cleaned media into Immich library

```bash
./scripts/08_sync_to_immich_library.sh
```

Verify:

```bash
du -sh /mnt/target_drive/cleaning_staging /mnt/target_drive/immich_library
find /mnt/target_drive/cleaning_staging -type f | wc -l
find /mnt/target_drive/immich_library -type f | wc -l
```

The file counts should match.

---

## 11. Install and start Immich

```bash
./scripts/09_setup_immich.sh
```

Open:

```text
http://localhost:2283
```

or from another device:

```text
http://SERVER_IP:2283
```

Create the admin user.

---

## 12. Add Immich external library

In Immich UI:

```text
Administration -> External Libraries -> New External Library
```

Add folder:

```text
/library
```

Do **not** use:

```text
/data
```

`/data` is Immich's upload folder. Immich rejects it as an external-library import path.

Save, then choose:

```text
Scan All Library Files
```

Then go to:

```text
Administration -> Jobs
```

Run or monitor:

```text
Library scan
Metadata extraction
Thumbnail generation
Preview generation
Video jobs
```

---

## 13. Verify Immich

```bash
./scripts/10_verify_immich.sh
```

Manual checks:

```bash
cd /mnt/target_drive/immich_app
docker compose ps
docker compose exec immich-server find /library -type f | wc -l
docker compose exec immich-server sh -c 'f=$(find /library -type f | head -n 1); echo "$f"; ls -lh "$f"; head -c 10 "$f" >/dev/null && echo read-ok'
docker compose logs --tail=120 immich-server
```

If Immich shows assets but thumbnails say “Error loading image,” wait for jobs to finish and check logs. Also ensure:

```bash
sudo chmod -R a+rX /mnt/target_drive/immich_library
cd /mnt/target_drive/immich_app
docker compose restart immich-server
```

---

## 14. Final success check

```bash
./scripts/07_verify_cleanup.sh
./scripts/10_verify_immich.sh
```

You want:

- `immich_library` file count equals `cleaning_staging` file count,
- Immich sees the same count under `/library`,
- Immich jobs are not failing repeatedly,
- thumbnails eventually load,
- `media_trash` remains available for recovery.

---

## 15. Later: deleting media_trash permanently

> **Permanent deletion warning:** this is not part of the automated workflow. Only do this weeks later after validating the cleaned library and backups.

Check size:

```bash
du -sh /mnt/target_drive/media_trash
find /mnt/target_drive/media_trash -type f | wc -l
```

Archive the deletion log first:

```bash
cp "$HOME/czkawka_reports/delete_confirm.txt" /mnt/target_drive/delete_confirm.txt
```

Permanent deletion command, provided for completeness but intentionally not automated:

```bash
# DANGER: irreversible if you have no backup.
# rm -rf /mnt/target_drive/media_trash
```

A safer approach is to rename it and wait:

```bash
mv /mnt/target_drive/media_trash /mnt/target_drive/media_trash_REVIEW_BEFORE_DELETE
```

Then delete later only after you are certain.


## Public repository, CodeRabbit, and CI/CD

This repo includes a public-repository readiness checklist, CodeRabbit configuration, and GitHub Actions CI/CD workflows.

Read these files before publishing:

```text
docs/PUBLIC_RELEASE_CHECKLIST.md
docs/CODERABBIT_AND_CI.md
SECURITY.md
```

Run this safety check before making the repo public:

```bash
git status --short
git ls-files | grep -Ei '(\.env$|rclone|token|secret|takeout|\.zip$|\.tgz$|raw_|cleaning_staging|immich_library|media_trash|\.log$)' || true
```

Expected result: no real secrets, logs, media archives, generated media folders, or personal configuration files are tracked by Git.

If the repository does not exist yet on GitHub, create it as public with:

```bash
gh auth login
gh repo create lharaujo/media-pipeline --public --source=. --remote=origin --push
```

If it already exists, push and switch visibility:

```bash
git push -u origin main
gh repo edit lharaujo/media-pipeline --visibility public
```

Install CodeRabbit from its GitHub integration UI after the repository exists. The `.coderabbit.yaml` file is already included, but the GitHub App must still be authorized for the repository.

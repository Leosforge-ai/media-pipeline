# Google Photos + Google Drive Media Cleanup Pipeline with Immich

A defensive, resumable media workflow for people who want to consolidate Google Photos Takeout exports and Google Drive media, repair Google Photos JSON metadata, detect duplicates, safely move duplicates aside, and browse the final library in Immich.

Built from real-world failure cases: `.tgz` Takeout archives, broken MP4 files, duplicated Google Photos folders such as `2024/` and `Fotos de 2024/`, Czkawka CLI flag changes, missing FFmpeg, unsafe duplicate-report parsing, and Immich external-library path mistakes.

> **Safety principle:** every destructive step defaults to dry-run. Duplicate removal moves files into `media_trash`; it never permanently deletes files.

---

## What this pipeline does

1. Creates a predictable external-drive folder structure.
2. Imports media from Google Photos Takeout archives: `.zip`, `.tgz`, `.tar.gz`.
3. Applies Google Photos JSON sidecar metadata to media files with `exiftool`.
4. Imports selected Google Drive folders using `rclone`.
5. Merges everything into `cleaning_staging`.
6. Scans for similar images, similar videos, exact duplicate files, and (optionally) blurry JPG/JPEG/PNG images.
7. Produces human-readable reports.
8. Runs a safe dry-run duplicate move plan.
9. Moves duplicates into `media_trash` only after explicit confirmation.
10. Copies the cleaned library into `immich_library`.
11. Optionally dry-runs and confirms a targeted Immich-library cleanup for Google Takeout `Fotos de YYYY` year-folder duplicates.
12. Installs and configures Immich, with upload storage at `/data` and a cleaned read-only external library at `/library`.

---

## Two ways to run it

**Desktop app (recommended).** A Flutter app (Linux, macOS, Windows) that wraps the pipeline, keeps every safety gate (dry-run first, explicit confirm, no silent deletion), and runs the duplicate-scan and metadata-stitch steps through a single pinned Docker image — no native `exiftool`/`czkawka` install required for those. Both trash-confirm steps (delete, restore) are plain in-process file moves needing neither Docker nor any native tool. See [`docs/DESKTOP_APP.md`](docs/DESKTOP_APP.md).

**Raw scripts.** The original `scripts/00`–`13` Bash/Python pipeline, run by hand. Requires the native tools listed under [Requirements](#requirements). Still fully maintained as a fallback and for scripted/headless use. See [`INSTRUCTIONS.md`](INSTRUCTIONS.md) for the full walkthrough.

Both paths share the same safety model and the same on-disk folder layout below.

---

## Folder layout on the external drive

Default root:

```text
/mnt/target_drive
```

Created folders:

```text
/mnt/target_drive/
├── raw_gdrive/           # rclone-imported Google Drive media
├── raw_takeout_zips/     # Google Photos Takeout archives: .zip/.tgz/.tar.gz
├── takeout_extracted/    # temporary extraction workspace
├── cleaning_staging/     # cleaned/staged media before Immich
├── media_trash/          # duplicates moved here, never permanently deleted
├── immich_library/       # final library copied from cleaning_staging
└── immich_app/           # Immich docker-compose, database, uploads
```

---

## Quick start

```bash
git clone https://github.com/Leosforge-ai/media-pipeline.git
cd media-pipeline
./scripts/00_check_system.sh
```

If the external drive isn't mounted yet (fresh machine, first run), run the first-time drive/Immich setup helper next. It detects unmounted candidate drives with `lsblk`/`blkid` (excluding the boot disk), and **prints, but never silently runs**, the exact mount/`fstab` commands for your drive's filesystem (ext4/ntfs/exfat) — you confirm each step interactively:

```bash
./scripts/00b_first_time_drive_setup.sh
```

Once the drive is mounted and its structure looks right:

```bash
./scripts/01_setup_dependencies.sh
```

### Desktop app

```bash
flutter pub get
flutter run -d linux   # or -d macos / -d windows
```

Build the tools image once (see [`docker/tools/README.md`](docker/tools/README.md)) before running the duplicate-scan, metadata-stitch, or Immich Takeout duplicate-dry-run steps — see [`docs/DESKTOP_APP.md`](docs/DESKTOP_APP.md#execution-model) for the full list:

```bash
docker build -t media-pipeline-tools:local docker/tools
```

Place Takeout archives into `/mnt/target_drive/raw_takeout_zips`, then follow the app's Guided Run. See [`docs/DESKTOP_APP.md`](docs/DESKTOP_APP.md) for the full workflow and platform status.

### Raw scripts

```bash
./scripts/02_configure_rclone.sh                          # optional, Google Drive
./scripts/03_import_gdrive.sh "Fotos" "Wedding "           # optional, Google Drive
./scripts/04_stitch_metadata.py
./scripts/05_cleanup_scan.sh
./scripts/06_delete_duplicates.sh | tee /tmp/delete_dry_run_v2.txt        # dry-run
./scripts/06_delete_duplicates.sh --confirm                              # inspect first
./scripts/08_sync_to_immich_library.sh
./scripts/09_setup_immich.sh
```

Open `http://localhost:2283`, add an Immich External Library with path `/library`.

Optional cleanup steps, both dry-run-first:

```bash
./scripts/12_clean_immich_takeout_duplicates.sh    # Google Takeout Fotos-de-YYYY duplicates
./scripts/13_dedupe_live_photos.sh                 # Apple Live Photos split into still + motion clip
```

Full walkthrough with every flag and edge case: [`INSTRUCTIONS.md`](INSTRUCTIONS.md).

---

## Final verification command

```bash
./scripts/07_verify_cleanup.sh
./scripts/10_verify_immich.sh
```

Expected signs of success:

- `cleaning_staging` contains the cleaned media.
- `media_trash` contains moved duplicates.
- `immich_library` file count matches `cleaning_staging` after sync.
- Immich container sees `/library`.
- Immich UI shows assets after external-library scan and background jobs finish.

---

## Important deletion disclaimer

Duplicate deletion is deliberately conservative but not magic. Czkawka similar-image detection can group files that are visually similar rather than byte-identical. Always inspect the dry-run output before confirming.

Recommended dry-run review:

```bash
grep -c '^Keep:' /tmp/delete_dry_run_v2.txt
grep -c '^Would trash:' /tmp/delete_dry_run_v2.txt
grep -E 'Would trash: Results|Would trash: Found|Would trash: [0-9]+ .*similar friends|Would trash: .* - [0-9]+x' /tmp/delete_dry_run_v2.txt | head
grep -iE '\.(mp4|mov)$' /tmp/delete_dry_run_v2.txt | head -n 80
```

The last command should print nothing. If it prints report headers or Czkawka metadata, do not confirm.

---

## Immich design

```text
/data      Immich's own upload/storage folder
/library   read-only cleaned media library
```

Do not add `/data` as an external library — Immich rejects the upload folder as an external-library path. Add `/library` instead.

---

## Recovery

Duplicate removal moves files to `/mnt/target_drive/media_trash`. To restore:

```bash
./scripts/11_restore_from_trash.sh | tee /tmp/restore_dry_run.txt   # dry-run first
./scripts/11_restore_from_trash.sh --confirm                        # only if correct
```

---

## Requirements

**Desktop app path:** Docker (for the pinned tools image) plus platform-native Flutter build tooling. No native `exiftool`/`czkawka` install needed for the steps that route through the container — see [`docs/DESKTOP_APP.md`](docs/DESKTOP_APP.md#execution-model) for exactly which steps that is; some steps still need native `rsync`, and steps not yet migrated still need the full native tool list below.

**Raw scripts path:** Ubuntu/Debian-like Linux. `scripts/01_setup_dependencies.sh` installs:

- Python 3
- rsync
- exiftool
- ffmpeg / ffprobe
- ImageMagick
- rclone
- Docker + Docker Compose plugin (for Immich)
- Czkawka CLI

---

## Platform status

| Platform | Status |
| --- | --- |
| Linux | Full support, both paths. |
| macOS | Desktop app builds and runs; the container-routed steps are architecturally cross-platform but not yet verified end-to-end on real macOS hardware. |
| Windows | Same as macOS — builds and runs, container-routed steps not yet verified end-to-end. |

See [`docs/DESKTOP_APP.md`](docs/DESKTOP_APP.md) for details and tracking issue [#76](https://github.com/Leosforge-ai/media-pipeline/issues/76).

---

## Limitations

- Metadata stitching depends on available Google Photos JSON sidecars.
- Some corrupted videos may not accept metadata writes; these are logged and still moved into staging.
- Similar-image and similar-video detection can have false positives. Review dry-runs.
- Read-only Immich external libraries cannot be modified by Immich. If you trash items in Immich, the original files may reappear after rescan because the read-only mount prevents Immich from deleting originals.
- If Immich shows duplicate assets from `Takeout/Google Fotos/YYYY/` and `Takeout/Google Fotos/Fotos de YYYY/`, run `12_clean_immich_takeout_duplicates.sh`, then restart Immich and rescan `/library`.
- If Immich shows an Apple Live Photo as two separate assets (a still plus a 1-3s motion clip), Google Takeout split what was originally one Live Photo into two files sharing a basename. `13_dedupe_live_photos.sh` moves the redundant motion clip to `media_trash`, keeping the still; it does not re-link them as a single Live Photo asset in Immich.

---

## CI and code review

Every pull request runs through GitHub Actions CI (shell/Python/YAML lint, Docker Compose validation, secret scanning) and an automated safety-focused review agent (see [`docs/CI.md`](docs/CI.md)).

## Contributing

Contributions are welcome. This project is intentionally conservative because it handles personal photos and videos. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request.

Good first contributions: documentation fixes, distro-specific dependency notes, safer error messages, additional troubleshooting cases, test reports from small disposable media samples.

Safety-sensitive contributions — duplicate parsing, deletion, metadata writing, Docker mounts, permissions — must explain the failure mode considered and the recovery path. Destructive actions must keep defaulting to dry-run and must never delete media permanently.

## License

MIT. See [`LICENSE`](LICENSE) — reuse, modification, distribution, and private/commercial use are all permitted, provided the copyright and license notice are included. Provided without warranty.

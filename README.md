# Google Photos + Google Drive Media Cleanup Pipeline with Immich

A defensive, resumable media workflow for people who want to consolidate Google Photos Takeout exports and Google Drive media, repair Google Photos JSON metadata, detect duplicates, safely move duplicates aside, and browse the final library in Immich.

This project was built from real-world failure cases: `.tgz` Takeout archives, broken MP4 files, duplicated Google Photos folders such as `2024/` and `Fotos de 2024/`, Czkawka CLI flag changes, missing FFmpeg, unsafe duplicate-report parsing, and Immich external-library path mistakes.

> **Safety principle:** scripts default to dry-run or non-destructive behavior. Duplicate removal moves files into `media_trash`; it does not permanently delete files.

---

## What this pipeline does

1. Creates a predictable external-drive folder structure.
2. Imports media from Google Photos Takeout archives: `.zip`, `.tgz`, `.tar.gz`.
3. Applies Google Photos JSON sidecar metadata to media files with `exiftool`.
4. Imports selected Google Drive folders using `rclone`.
5. Merges everything into `cleaning_staging`.
6. Scans for:
   - similar images,
   - similar videos,
   - exact duplicate files,
   - optional blurry JPG/JPEG/PNG images.
7. Produces human-readable reports.
8. Runs a safe dry-run duplicate move plan.
9. Moves duplicates into `media_trash` only after explicit confirmation.
10. Copies the cleaned library into `immich_library`.
11. Installs and configures Immich with:
   - Immich upload storage at `/data`,
   - cleaned read-only external library at `/library`.

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
git clone <your-repo-url> media-pipeline
cd media-pipeline

./scripts/00_check_system.sh
./scripts/01_setup_dependencies.sh
```

## Desktop app preview

This repository now includes a Flutter desktop controller for Linux, macOS,
Windows, and ChromeOS through the ChromeOS Linux environment. The app wraps the
existing scripts and keeps the same safety model: dry-runs first, explicit
confirm actions, and no permanent deletion.

Run the app during development:

```bash
flutter pub get
flutter run -d linux
```

See [`docs/DESKTOP_APP.md`](docs/DESKTOP_APP.md) for platform support and app
workflow details.

Place Google Photos Takeout archives into:

```text
/mnt/target_drive/raw_takeout_zips
```

Configure Google Drive access if needed:

```bash
./scripts/02_configure_rclone.sh
./scripts/03_import_gdrive.sh "Fotos" "Wedding "
```

Process Takeout + merge Google Drive:

```bash
./scripts/04_stitch_metadata.py
```

Scan for duplicates:

```bash
./scripts/05_cleanup_scan.sh
```

Dry-run duplicate removal:

```bash
./scripts/06_delete_duplicates.sh | tee /tmp/delete_dry_run_v2.txt
```

Inspect first. Then, and only then, optionally move duplicates into `media_trash`:

```bash
./scripts/06_delete_duplicates.sh --confirm | tee "$HOME/czkawka_reports/delete_confirm.txt"
```

Copy cleaned files into Immich library:

```bash
./scripts/08_sync_to_immich_library.sh
```

Install/start Immich:

```bash
./scripts/09_setup_immich.sh
```

Open:

```text
http://localhost:2283
```

Then add an Immich External Library with path:

```text
/library
```

---

## Final verification command

Run this after cleanup and Immich setup:

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

The duplicate deletion script is deliberately conservative but not magic. Czkawka similar-image detection can group files that are visually similar rather than byte-identical. Always inspect the dry-run output before using `--confirm`.

Recommended dry-run review:

```bash
grep -c '^Keep:' /tmp/delete_dry_run_v2.txt
grep -c '^Would trash:' /tmp/delete_dry_run_v2.txt

grep -E 'Would trash: Results|Would trash: Found|Would trash: [0-9]+ .*similar friends|Would trash: .* - [0-9]+x' /tmp/delete_dry_run_v2.txt | head

grep -iE '\.(mp4|mov)$' /tmp/delete_dry_run_v2.txt | head -n 80
```

The third command should print nothing. If it prints report headers or Czkawka metadata, do not confirm.

---

## Immich design

Immich is configured with two separate mounts:

```text
/data      Immich's own upload/storage folder
/library   read-only cleaned media library
```

Do not add `/data` as an external library. Immich rejects the media upload folder as an external-library path. Add `/library` instead.

---

## Recovery

Duplicate removal moves files to:

```text
/mnt/target_drive/media_trash
```

To restore from trash, dry-run first:

```bash
./scripts/11_restore_from_trash.sh | tee /tmp/restore_dry_run.txt
```

Only if correct:

```bash
./scripts/11_restore_from_trash.sh --confirm
```

---

## Requirements

Ubuntu or Debian-like Linux is recommended. The dependency script installs:

- Python 3
- rsync
- exiftool
- ffmpeg / ffprobe
- ImageMagick
- rclone
- Docker + Docker Compose plugin
- Czkawka CLI

---

## Limitations

- Metadata stitching depends on available Google Photos JSON sidecars.
- Some corrupted videos may not accept metadata writes; these are logged and still moved into staging.
- Similar-image and similar-video detection can have false positives. Review dry-runs.
- Read-only Immich external libraries cannot be modified by Immich. If you trash items in Immich, the original files may reappear after rescan because the read-only mount prevents Immich from deleting originals.


## CodeRabbit and CI/CD

This repository includes CodeRabbit configuration and GitHub Actions workflows for public/open-source maintenance. CodeRabbit is configured through `.coderabbit.yaml` in the repository root and reviews pull requests with extra attention to destructive operations, Czkawka report parsing, Immich storage separation, Bash safety, and recovery documentation.

The CI workflow validates shell scripts, Python syntax/linting, YAML, Docker Compose rendering, and GitHub Actions workflow syntax. See `docs/CODERABBIT_AND_CI.md` for setup instructions.

Before making the repository public, run the checklist in `docs/PUBLIC_RELEASE_CHECKLIST.md`.
## Contributing

Contributions are welcome. This project is intentionally conservative because it handles personal photos and videos. Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request.

Good first contributions include documentation fixes, distro-specific dependency notes, safer error messages, additional troubleshooting cases, and test reports from small disposable media samples.

Safety-sensitive contributions, especially changes to duplicate parsing, deletion, metadata writing, Docker mounts, or permissions, must explain the failure mode considered and the recovery path for users. Destructive actions must continue to default to dry-run and must never permanently delete media automatically.

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE).

The MIT License allows reuse, modification, distribution, and private or commercial use, provided the copyright and license notice are included. The software is provided without warranty.

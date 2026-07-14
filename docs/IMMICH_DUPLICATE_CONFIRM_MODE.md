# Immich Duplicate Confirm Mode Design

Confirm mode is destructive: it moves verified files to `media_trash`. Do not
run it unless you have reviewed the dry-run output and are ready to proceed.

The desktop app currently exposes the Immich Takeout duplicate cleanup as a
dry-run-only step. This is intentional.

The confirm path for `scripts/12_clean_immich_takeout_duplicates.sh` requires a typed confirmation phrase on stdin:

```text
MOVE TAKEOUT DUPLICATES
```

The `PipelineRunner` now supports sending stdin to child processes, but the app should still keep the confirm action separate from the dry-run action until the UI explicitly collects the typed phrase.

## CLI Examples

Dry-run only:

```bash
bash scripts/12_clean_immich_takeout_duplicates.sh
```

Confirm mode requires the exact typed phrase on stdin:

```bash
printf 'MOVE TAKEOUT DUPLICATES\n' | bash scripts/12_clean_immich_takeout_duplicates.sh --confirm
```

After confirm mode, inspect the trash and restore files manually if needed.
Moved files mirror their full original absolute path under `$MEDIA_TRASH`
(the same layout `06_delete_duplicates.sh` and `13_dedupe_live_photos.sh`
use — no timestamped batch subdirectory), which is what lets
`11_restore_from_trash.sh` reconstruct the original path automatically:

```bash
ls -la "$MEDIA_TRASH/mnt/target_drive/immich_library/Takeout/Google Fotos/Fotos de 2024"
mv "$MEDIA_TRASH/mnt/target_drive/immich_library/Takeout/Google Fotos/Fotos de 2024/IMG_1951.HEIC" \
   "/mnt/target_drive/immich_library/Takeout/Google Fotos/Fotos de 2024/IMG_1951.HEIC"
```

Adjust the path to match your setup, or just run
`./scripts/11_restore_from_trash.sh --confirm` to restore everything in
`media_trash` back to its original location in one pass.

## Proposed App Design

1. Keep the existing dry-run step in the app workflow.
2. Add a separate confirm UI that provides the typed phrase to the runner.
3. Require an explicit typed phrase in the UI before the confirm step is enabled.
4. Keep the dry-run and confirm actions separate in the step model.
5. Keep the confirm action Linux-only and review-gated.

## Safety Requirements

- The confirm action must never be automatic.
- The confirm action must never be the default button.
- The confirm action must only be available after a successful dry-run in the same session.
- The app must show the dry-run summary before any confirm action is allowed.
- The confirm action must still move files to `media_trash`; it must not delete files.

## Acceptance Criteria

- The app can pass typed stdin to the cleanup script through the runner.
- The confirm button is disabled until the typed phrase matches exactly.
- The confirm path remains separate from the dry-run path.
- The app continues to work on non-Linux platforms without exposing confirm mode.
- The docs make it clear that confirm mode stays separate from the dry-run action and still requires explicit typed confirmation.

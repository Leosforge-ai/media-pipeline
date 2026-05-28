#!/usr/bin/env bash
# Shared shell configuration for the media pipeline.
# Override any value by exporting it before running a script, e.g.:
#   export DRIVE_NAME=DATA

set -euo pipefail

DRIVE_NAME="${DRIVE_NAME:-target_drive}"
MOUNT_ROOT="${MOUNT_ROOT:-/mnt}"
HD_PATH="${HD_PATH:-$MOUNT_ROOT/$DRIVE_NAME}"

RAW_GDRIVE="$HD_PATH/raw_gdrive"
RAW_TAKEOUT_ZIPS="$HD_PATH/raw_takeout_zips"
TAKEOUT_EXTRACTED="$HD_PATH/takeout_extracted"
CLEANING_STAGING="$HD_PATH/cleaning_staging"
MEDIA_TRASH="$HD_PATH/media_trash"
IMMICH_LIBRARY="$HD_PATH/immich_library"
IMMICH_APP="$HD_PATH/immich_app"
REPORT_DIR="${REPORT_DIR:-$HOME/czkawka_reports}"

export DRIVE_NAME MOUNT_ROOT HD_PATH RAW_GDRIVE RAW_TAKEOUT_ZIPS TAKEOUT_EXTRACTED CLEANING_STAGING MEDIA_TRASH IMMICH_LIBRARY IMMICH_APP REPORT_DIR

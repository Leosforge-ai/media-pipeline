#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/pipeline_config.sh
. "$SCRIPT_DIR/../config/pipeline_config.sh"

echo "==> Pipeline paths"
printf 'HD_PATH=%s\n' "$HD_PATH"
printf 'RAW_TAKEOUT_ZIPS=%s\n' "$RAW_TAKEOUT_ZIPS"
printf 'RAW_GDRIVE=%s\n' "$RAW_GDRIVE"
printf 'CLEANING_STAGING=%s\n' "$CLEANING_STAGING"
printf 'MEDIA_TRASH=%s\n' "$MEDIA_TRASH"
printf 'IMMICH_LIBRARY=%s\n' "$IMMICH_LIBRARY"
printf 'IMMICH_APP=%s\n' "$IMMICH_APP"
printf 'REPORT_DIR=%s\n' "$REPORT_DIR"

echo
if [[ -d "$HD_PATH" ]]; then
	echo "==> Drive path exists"
	df -h "$HD_PATH" || true
	findmnt "$HD_PATH" || true
else
	echo "WARNING: $HD_PATH does not exist yet. Mount/create it before processing media."
fi

echo
for cmd in python3 rsync exiftool ffmpeg ffprobe convert docker; do
	if command -v "$cmd" >/dev/null 2>&1; then
		printf 'OK: %-12s %s\n' "$cmd" "$(command -v "$cmd")"
	else
		printf 'MISSING: %s\n' "$cmd"
	fi
done

if command -v docker >/dev/null 2>&1; then
	docker --version || true
	docker compose version || true
fi

if command -v czkawka_cli >/dev/null 2>&1; then
	echo "OK: czkawka_cli $(czkawka_cli --version 2>/dev/null || true)"
else
	echo "MISSING: czkawka_cli"
fi

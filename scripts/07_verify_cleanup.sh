#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

echo "==> Folder sizes"
du -sh "$CLEANING_STAGING" "$MEDIA_TRASH" "$IMMICH_LIBRARY" 2>/dev/null || true

echo
echo "==> File counts"
printf 'cleaning_staging: '
find "$CLEANING_STAGING" -type f 2>/dev/null | wc -l
printf 'media_trash:      '
find "$MEDIA_TRASH" -type f 2>/dev/null | wc -l
printf 'immich_library:   '
find "$IMMICH_LIBRARY" -type f 2>/dev/null | wc -l

echo
echo "==> Reports"
ls -lh "$REPORT_DIR" 2>/dev/null || true

echo
echo "==> Report parser safety check"
if [[ -f /tmp/delete_dry_run_v2.txt ]]; then
	grep -E "Would trash: Results|Would trash: Found|Would trash: [0-9]+ .*similar friends|Would trash: .* - [0-9]+x" /tmp/delete_dry_run_v2.txt | head || true
else
	echo "No /tmp/delete_dry_run_v2.txt found. Run 06_delete_duplicates.sh dry-run first."
fi

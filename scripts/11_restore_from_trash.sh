#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

cat <<EOF
This restores files from media_trash back to their original absolute paths.
Trash folder: $MEDIA_TRASH
Destination roots are reconstructed from paths stored under media_trash.

Default mode is dry-run. Use --confirm only if you really want to restore.
EOF

CONFIRM="${1:-}"
DRY_RUN=1
[[ "$CONFIRM" == "--confirm" ]] && DRY_RUN=0

find "$MEDIA_TRASH" -type f -print0 | while IFS= read -r -d '' f; do
	rel="${f#"$MEDIA_TRASH"/}"
	dest="/$rel"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "Would restore: $f -> $dest"
	else
		mkdir -p "$(dirname "$dest")"
		mv -n "$f" "$dest"
		echo "Restored: $dest"
	fi
done

[[ "$DRY_RUN" -eq 1 ]] && echo "Dry-run only. Re-run with --confirm to restore."

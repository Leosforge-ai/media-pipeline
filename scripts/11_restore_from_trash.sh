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
		if mv -n "$f" "$dest"; then
			echo "Restored: $dest"
		else
			mv_status=$?
			# mv -n exits non-zero both when it (correctly) skips an
			# existing destination and, less commonly, on a genuine
			# failure (permission denied, disk full, source vanished
			# mid-loop). Don't trust the exit code alone to tell them
			# apart (issue #102, same class of bug as #81's czkawka
			# exit-code handling): check whether the destination
			# actually exists. If it does, this was a benign
			# no-clobber skip -- log it and keep restoring the rest of
			# the batch. If it doesn't, mv failed for a real reason;
			# treat that as fatal and stop, matching this repo's
			# fail-closed, data-loss-prevention priority.
			if [[ -e "$dest" ]]; then
				echo "Skipped (destination already exists): $dest"
			else
				echo "ERROR: failed to restore $f -> $dest (mv exited $mv_status)" >&2
				exit "$mv_status"
			fi
		fi
	fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Dry-run only. Re-run with --confirm to restore."
fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

CONFIRM="${1:-}"
mkdir -p "$MEDIA_TRASH" "$REPORT_DIR"

cat <<'EOF'
SAFETY NOTICE
-------------
This script NEVER permanently deletes files. It moves selected duplicate files
from cleaning_staging into media_trash. You must inspect the dry-run output
before using --confirm.

Recommended:
  1. Run without --confirm.
  2. Save and inspect the dry-run.
  3. Spot-check examples in Ubuntu Files or Immich.
  4. Only then decide whether to run with --confirm.
EOF

echo
if [[ "$CONFIRM" == "--confirm" ]]; then
	DRY_RUN=0
	echo "CONFIRM MODE: files WILL be moved to $MEDIA_TRASH"
else
	DRY_RUN=1
	echo "DRY RUN MODE: no files will be moved"
fi

echo

trash_file() {
	local src="$1"
	[[ "$src" == "$CLEANING_STAGING"/* ]] || {
		echo "Refusing outside staging: $src"
		return
	}
	if [[ ! -f "$src" ]]; then
		echo "Missing, skipping: $src"
		return
	fi
	local rel="${src#/}"
	local dst="$MEDIA_TRASH/$rel"
	local dst_dir
	dst_dir="$(dirname "$dst")"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "Would trash: $src"
	else
		mkdir -p "$dst_dir"
		if [[ -e "$dst" ]]; then
			local base suffix i candidate
			base="${dst%.*}"
			suffix=".${dst##*.}"
			[[ "$base" == "$dst" ]] && suffix=""
			i=1
			while true; do
				candidate="${base}_$i$suffix"
				[[ ! -e "$candidate" ]] && {
					dst="$candidate"
					break
				}
				i=$((i + 1))
			done
		fi
		mv "$src" "$dst"
		echo "Trashed: $src"
	fi
}

score_keep_path() {
	local p="$1"
	# Lower score wins.
	# Prefer clean Google Photos year folders over localized folder copies and Google Drive duplicates.
	if [[ "$p" =~ /Takeout/Google\ Fotos/[0-9]{4}/ ]]; then
		echo 0
	elif [[ "$p" =~ /Takeout/Google\ Fotos/Fotos\ de\ [0-9]{4}/ ]]; then
		echo 10
	elif [[ "$p" =~ /Takeout/Google\ Fotos/ ]]; then
		echo 12
	elif [[ "$p" =~ /cleaning_staging/Fotos/ ]]; then
		echo 20
	else
		echo 5
	fi
}

process_czkawka_report() {
	local report="$1"
	[[ -f "$report" ]] || return 0
	echo "==> Processing duplicate report: $report"

	local -a group=()
	local line path

	flush_group() {
		local n="${#group[@]}"
		[[ "$n" -lt 2 ]] && {
			group=()
			return
		}

		local keep_index=0 best_score=999999 i score
		for i in "${!group[@]}"; do
			score="$(score_keep_path "${group[$i]}")"
			if ((score < best_score)); then
				best_score="$score"
				keep_index="$i"
			fi
		done

		echo "Keep: ${group[$keep_index]}"
		for i in "${!group[@]}"; do
			[[ "$i" == "$keep_index" ]] || trash_file "${group[$i]}"
		done
		echo
		group=()
	}

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ -z "$line" ]]; then
			flush_group
			continue
		fi
		if [[ "$line" =~ ^Found\  ]]; then
			flush_group
			continue
		fi
		# Accept only Czkawka lines that START with a quoted path inside staging.
		if [[ "$line" =~ ^\"([^\"]+)\" ]]; then
			path="${BASH_REMATCH[1]}"
			[[ "$path" == "$CLEANING_STAGING"/* ]] && group+=("$path")
		fi
	done <"$report"
	flush_group
}

process_czkawka_report "$REPORT_DIR/duplicate_images.txt"
process_czkawka_report "$REPORT_DIR/duplicate_videos.txt"
process_czkawka_report "$REPORT_DIR/duplicate_files.txt"

echo "Done."
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Dry-run complete. Review the output. Do NOT blindly run --confirm."
fi

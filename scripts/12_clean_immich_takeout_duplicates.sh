#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

MODE="${1:-}"
case "$MODE" in
"" | "--confirm") ;;
*)
	echo "Usage: $0 [--confirm]" >&2
	exit 64
	;;
esac

GOOGLE_FOTOS_DIR="$IMMICH_LIBRARY/Takeout/Google Fotos"
RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
TRASH_BATCH="$MEDIA_TRASH/immich_library_fotos_de_duplicates_$RUN_TIMESTAMP"
CONFIRM_PHRASE="MOVE TAKEOUT DUPLICATES"
DRY_RUN=1

cat <<EOF
SAFETY NOTICE
-------------
This script targets only Google Takeout localized year-folder duplicates
inside the Immich external library:

  $GOOGLE_FOTOS_DIR/Fotos de YYYY/*

It keeps matching canonical files from:

  $GOOGLE_FOTOS_DIR/YYYY/*

It never deletes files. Confirm mode moves verified duplicates to:

  $TRASH_BATCH/

Default mode is dry-run. Stop Immich before confirm mode, then restart Immich
and rescan the external library path /library after the move.
EOF

echo
if [[ "$MODE" == "--confirm" ]]; then
	DRY_RUN=0
	echo "CONFIRM MODE: verified duplicates WILL be moved to media_trash."
	printf 'Type "%s" to continue: ' "$CONFIRM_PHRASE"
	typed_confirmation=""
	if ! IFS= read -r typed_confirmation; then
		typed_confirmation=""
	fi
	if [[ "$typed_confirmation" != "$CONFIRM_PHRASE" ]]; then
		echo "Confirmation phrase did not match. No files were moved."
		exit 2
	fi
else
	echo "DRY RUN MODE: no files will be moved."
fi

echo

file_size() {
	wc -c <"$1" | tr -d '[:space:]'
}

file_hash() {
	sha256sum "$1" | awk '{print $1}'
}

unique_destination() {
	local dst="$1"
	if [[ ! -e "$dst" ]]; then
		printf '%s\n' "$dst"
		return
	fi

	local base suffix i candidate
	base="${dst%.*}"
	suffix=".${dst##*.}"
	[[ "$base" == "$dst" ]] && suffix=""
	i=1
	while true; do
		candidate="${base}_$i$suffix"
		if [[ ! -e "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return
		fi
		i=$((i + 1))
	done
}

move_or_report_duplicate() {
	local duplicate="$1"
	local canonical="$2"
	local rel dst

	rel="${duplicate#"$IMMICH_LIBRARY"/}"
	dst="$TRASH_BATCH/$rel"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "Would move duplicate: $duplicate -> $dst"
	else
		dst="$(unique_destination "$dst")"
		mkdir -p "$(dirname "$dst")"
		mv "$duplicate" "$dst"
		echo "Moved duplicate: $duplicate -> $dst"
	fi
	echo "Kept canonical: $canonical"
}

inspect_candidate() {
	local duplicate="$1"
	local year="$2"
	local localized_dir="$3"
	local canonical_dir="$4"
	local basename canonical duplicate_size canonical_size duplicate_hash canonical_hash

	[[ "$duplicate" == "$localized_dir"/* ]] || {
		echo "Refusing outside localized folder: $duplicate"
		return
	}

	basename="$(basename "$duplicate")"
	canonical="$canonical_dir/$basename"

	inspected=$((inspected + 1))

	if [[ ! -f "$canonical" ]]; then
		skipped_missing=$((skipped_missing + 1))
		echo "Missing canonical for $year: $duplicate"
		return
	fi

	duplicate_size="$(file_size "$duplicate")"
	canonical_size="$(file_size "$canonical")"
	if [[ "$duplicate_size" != "$canonical_size" ]]; then
		skipped_size=$((skipped_size + 1))
		echo "Size mismatch, skipping: $duplicate"
		return
	fi

	duplicate_hash="$(file_hash "$duplicate")"
	canonical_hash="$(file_hash "$canonical")"
	if [[ "$duplicate_hash" != "$canonical_hash" ]]; then
		skipped_hash=$((skipped_hash + 1))
		echo "Hash mismatch, skipping: $duplicate"
		return
	fi

	verified=$((verified + 1))
	move_or_report_duplicate "$duplicate" "$canonical"
}

if [[ ! -d "$GOOGLE_FOTOS_DIR" ]]; then
	echo "Google Fotos folder not found: $GOOGLE_FOTOS_DIR"
	echo "Nothing to do."
	exit 0
fi

mkdir -p "$MEDIA_TRASH" "$REPORT_DIR"

inspected=0
verified=0
skipped_missing=0
skipped_size=0
skipped_hash=0

while IFS= read -r -d '' localized_dir; do
	localized_name="$(basename "$localized_dir")"
	if [[ ! "$localized_name" =~ ^Fotos\ de\ ([0-9]{4})$ ]]; then
		continue
	fi

	year="${BASH_REMATCH[1]}"
	canonical_dir="$GOOGLE_FOTOS_DIR/$year"
	if [[ ! -d "$canonical_dir" ]]; then
		echo "Missing canonical year folder for $localized_name: $canonical_dir"
		continue
	fi

	while IFS= read -r -d '' duplicate; do
		inspect_candidate "$duplicate" "$year" "$localized_dir" "$canonical_dir"
	done < <(find "$localized_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
done < <(find "$GOOGLE_FOTOS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'Fotos de [0-9][0-9][0-9][0-9]' -print0 | sort -z)

echo
echo "Summary"
echo "-------"
echo "Candidates inspected: $inspected"
echo "Verified duplicates:  $verified"
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Moved to trash:       0"
else
	echo "Moved to trash:       $verified"
fi
echo "Missing canonical:    $skipped_missing"
echo "Size mismatches:      $skipped_size"
echo "Hash mismatches:      $skipped_hash"

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo
	echo "Dry-run complete. Inspect the output before running --confirm."
else
	echo
	echo "Confirm move complete. Restart Immich and rescan external library path /library."
fi

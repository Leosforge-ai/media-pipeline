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

# Overridable so tests can inject a stub without requiring a real ffprobe
# binary or real encoded media on the test runner.
FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"

command -v "$FFPROBE_BIN" >/dev/null || {
	echo "ERROR: $FFPROBE_BIN not found. Run scripts/01_setup_dependencies.sh" >&2
	exit 1
}

# Directory to scan. Defaults to the Immich external library, since cleanup is
# typically discovered after import (see #60). Set LIVE_PHOTO_SCAN_DIR to
# $CLEANING_STAGING to run this pre-sync instead.
TARGET_DIR="${LIVE_PHOTO_SCAN_DIR:-$IMMICH_LIBRARY}"

RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
CONFIRM_PHRASE="MOVE LIVE PHOTO VIDEOS"
DRY_RUN=1

# Reject any paired video longer than this. Apple Live Photos capture roughly
# 1.5s before and 1.5s after the still (about 3s total, per Apple's own
# documentation), and Google Takeout's exported motion clips fall in the same
# ballpark (the reporting issue observed 1-3s clips). 5 seconds gives a
# comfortable margin above that range for encoder/container overhead while
# still safely rejecting a real standalone video that happens to share a
# basename (those are typically tens of seconds to minutes long, not single
# digits).
MAX_DURATION_SECONDS=5

# Secondary signal, only used when ffprobe cannot report a numeric duration
# (corrupt file, missing metadata). Apple/Google write the still and its
# motion clip within the same capture instant, so their filesystem
# modification times land within a couple of seconds of each other. Anything
# further apart is treated as an ambiguous, unrelated match rather than
# guessed at.
TIMESTAMP_PROXIMITY_SECONDS=5

cat <<EOF
SAFETY NOTICE
-------------
This script targets Apple Live Photo still+video pairs split apart by Google
Takeout inside:

  $TARGET_DIR

A still (.heic/.heif/.jpg/.jpeg) and a video (.mov/.mp4) are only treated as a
pair when they share a directory and basename, AND the video's duration is
verified (ffprobe) to be no more than ${MAX_DURATION_SECONDS}s (falling back
to file-timestamp proximity only when ffprobe cannot report a duration at
all). It never deletes files and never touches the still. Confirm mode moves
only the verified motion video to:

  $MEDIA_TRASH/

This script does NOT attempt to re-link the still+video as a proper Immich
Live Photo asset (e.g. QuickTime:ContentIdentifier). It only removes the
redundant standalone video; the still remains a plain photo. That re-linking
is explicit out-of-scope per #60.

Default mode is dry-run.
EOF

echo
if [[ "$MODE" == "--confirm" ]]; then
	DRY_RUN=0
	echo "CONFIRM MODE: verified standalone Live Photo videos WILL be moved to media_trash."
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

video_duration_seconds() {
	"$FFPROBE_BIN" -v error -show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || true
}

file_mtime() {
	stat -c %Y "$1" 2>/dev/null || echo ""
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

# Moved files mirror their full original absolute path under $MEDIA_TRASH
# (the same layout scripts/06_delete_duplicates.sh already uses), because
# 11_restore_from_trash.sh reconstructs the original path by stripping only
# the $MEDIA_TRASH/ prefix and prepending "/". A batch subdirectory nested
# under $MEDIA_TRASH (as scripts/12 uses for its own trash layout) would
# survive as an extra path segment and break that reconstruction, so it is
# intentionally not used here. $RUN_TIMESTAMP is still recorded, in the
# printed summary and in per-move log lines, for batch identification.
move_or_report_video() {
	local video="$1"
	local still="$2"
	local reason="$3"
	local rel dst

	rel="${video#/}"
	dst="$MEDIA_TRASH/$rel"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "Would move standalone Live Photo video ($reason): $video -> $dst"
	else
		dst="$(unique_destination "$dst")"
		mkdir -p "$(dirname "$dst")"
		mv "$video" "$dst"
		echo "[$RUN_TIMESTAMP] Moved standalone Live Photo video ($reason): $video -> $dst"
	fi
	echo "Kept still: $still"
}

evaluate_pair() {
	local still="$1"
	local video="$2"

	inspected=$((inspected + 1))

	local duration
	duration="$(video_duration_seconds "$video")"

	if [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		if awk -v d="$duration" -v max="$MAX_DURATION_SECONDS" \
			'BEGIN { exit !(d <= max) }'; then
			verified=$((verified + 1))
			move_or_report_video "$video" "$still" "duration ${duration}s"
		else
			skipped_too_long=$((skipped_too_long + 1))
			echo "Video too long (${duration}s > ${MAX_DURATION_SECONDS}s), skipping: $video"
		fi
		return
	fi

	skipped_duration_unknown=$((skipped_duration_unknown + 1))

	local still_mtime video_mtime diff
	still_mtime="$(file_mtime "$still")"
	video_mtime="$(file_mtime "$video")"

	if [[ -n "$still_mtime" && -n "$video_mtime" ]]; then
		if ((still_mtime > video_mtime)); then
			diff=$((still_mtime - video_mtime))
		else
			diff=$((video_mtime - still_mtime))
		fi

		if ((diff <= TIMESTAMP_PROXIMITY_SECONDS)); then
			verified=$((verified + 1))
			move_or_report_video "$video" "$still" "duration unknown, timestamps ${diff}s apart"
			return
		fi
	fi

	skipped_ambiguous=$((skipped_ambiguous + 1))
	echo "Duration unknown and timestamps not close enough, skipping: $video"
}

process_directory() {
	local dir="$1"
	local -A stills=()
	local -A videos=()
	local -a video_order=()
	local f name base ext ext_lower

	while IFS= read -r -d '' f; do
		name="$(basename "$f")"
		ext="${name##*.}"
		[[ "$name" == "$ext" ]] && continue
		ext_lower="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
		base="${name%.*}"
		case "$ext_lower" in
		heic | heif | jpg | jpeg)
			stills["$base"]="$f"
			;;
		mov | mp4)
			if [[ -z "${videos[$base]:-}" ]]; then
				video_order+=("$base")
			fi
			videos["$base"]="$f"
			;;
		esac
	done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)

	local key
	for key in "${video_order[@]}"; do
		local video="${videos[$key]}"
		local still="${stills[$key]:-}"

		if [[ -z "$still" ]]; then
			inspected=$((inspected + 1))
			skipped_missing=$((skipped_missing + 1))
			echo "No paired still for video, skipping: $video"
			continue
		fi

		evaluate_pair "$still" "$video"
	done
}

if [[ ! -d "$TARGET_DIR" ]]; then
	echo "Scan directory not found: $TARGET_DIR"
	echo "Nothing to do."
	exit 0
fi

mkdir -p "$MEDIA_TRASH" "$REPORT_DIR"

inspected=0
verified=0
skipped_missing=0
skipped_too_long=0
skipped_duration_unknown=0
skipped_ambiguous=0

while IFS= read -r -d '' dir; do
	process_directory "$dir"
done < <(find "$TARGET_DIR" -type d -print0 | sort -z)

echo
echo "Summary"
echo "-------"
echo "Run timestamp:            $RUN_TIMESTAMP"
echo "Candidates inspected:     $inspected"
echo "Verified pairs:           $verified"
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Moved to trash:            0"
else
	echo "Moved to trash:            $verified"
fi
echo "Missing paired still:     $skipped_missing"
echo "Video too long:           $skipped_too_long"
echo "Duration unknown (total): $skipped_duration_unknown"
echo "Skipped, ambiguous match: $skipped_ambiguous"

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo
	echo "Dry-run complete. Inspect the output before running --confirm."
else
	echo
	echo "Confirm move complete. Restart Immich and rescan external library path /library."
fi

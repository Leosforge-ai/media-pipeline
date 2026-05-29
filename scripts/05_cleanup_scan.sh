#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

BLUR_THRESHOLD="${BLUR_THRESHOLD:-1000}"
RUN_BLUR_SCAN="${RUN_BLUR_SCAN:-1}"

mkdir -p "$REPORT_DIR"

for cmd in czkawka_cli ffmpeg ffprobe convert; do
	command -v "$cmd" >/dev/null || {
		echo "ERROR: $cmd not found. Run scripts/01_setup_dependencies.sh"
		exit 1
	}
done

[[ -d "$CLEANING_STAGING" ]] || {
	echo "ERROR: staging folder missing: $CLEANING_STAGING"
	exit 1
}

echo "==> Media directory: $CLEANING_STAGING"
echo "==> Report directory: $REPORT_DIR"
du -sh "$CLEANING_STAGING"
find "$CLEANING_STAGING" -type f | wc -l

rm -f \
	"$REPORT_DIR/duplicate_images.txt" \
	"$REPORT_DIR/duplicate_videos.txt" \
	"$REPORT_DIR/duplicate_files.txt" \
	"$REPORT_DIR/blurry_images.txt" \
	"$REPORT_DIR/image_scan_run.log" \
	"$REPORT_DIR/video_scan_run.log" \
	"$REPORT_DIR/duplicate_files_run.log" \
	"$REPORT_DIR/blur_scan_run.log"

echo "==> Running Czkawka similar image scan"
czkawka_cli image \
	-d "$CLEANING_STAGING" \
	-f "$REPORT_DIR/duplicate_images.txt" \
	2>&1 | tee "$REPORT_DIR/image_scan_run.log"

echo "==> Running Czkawka similar video scan"
czkawka_cli video \
	-d "$CLEANING_STAGING" \
	-f "$REPORT_DIR/duplicate_videos.txt" \
	2>&1 | tee "$REPORT_DIR/video_scan_run.log"

echo "==> Running Czkawka exact duplicate file scan"
czkawka_cli dup \
	-d "$CLEANING_STAGING" \
	-f "$REPORT_DIR/duplicate_files.txt" \
	2>&1 | tee "$REPORT_DIR/duplicate_files_run.log"

if [[ "$RUN_BLUR_SCAN" == "1" ]]; then
	echo "==> Running optional blur scan for JPG/JPEG/PNG"
	BLUR_REPORT="$REPORT_DIR/blurry_images.txt"
	: >"$BLUR_REPORT"
	find "$CLEANING_STAGING" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0 |
		while IFS= read -r -d '' img; do
			variance=$(convert "$img" -colorspace Gray -define convolve:scale=1 -morphology Convolve Laplacian:0 -format "%[fx:p.u]" info: 2>/dev/null || echo "0")
			is_blurry=$(awk -v v="$variance" -v t="$BLUR_THRESHOLD" 'BEGIN { print (v+0 < t+0) ? "yes" : "no" }')
			if [[ "$is_blurry" == "yes" ]]; then
				printf '%s %s\n' "$variance" "$img" >>"$BLUR_REPORT"
			fi
		done 2>&1 | tee "$REPORT_DIR/blur_scan_run.log"
	sort -n "$BLUR_REPORT" -o "$BLUR_REPORT"
else
	echo "==> Blur scan disabled. Set RUN_BLUR_SCAN=1 to enable."
fi

echo "==> Summary"
ls -lh "$REPORT_DIR"
printf 'Image groups: '
grep -c '^Found .*images' "$REPORT_DIR/duplicate_images.txt" 2>/dev/null || true
printf 'Video groups: '
grep -c '^Found .*videos' "$REPORT_DIR/duplicate_videos.txt" 2>/dev/null || true
printf 'Exact duplicate groups: '
grep -c '^Found .*files' "$REPORT_DIR/duplicate_files.txt" 2>/dev/null || true
printf 'Video processing warnings: '
grep -c 'Failed to hash file' "$REPORT_DIR/video_scan_run.log" 2>/dev/null || true

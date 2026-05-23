#!/usr/bin/env bash
set -euo pipefail

MEDIA_DIR="/mnt/storage_2tb/cleaning_staging"
REPORT_DIR="$HOME/czkawka_reports"
SIMILARITY="High"
BLUR_THRESHOLD=1000

mkdir -p "$REPORT_DIR"

echo "==> Running Czkawka Duplicates Engine..."
czkawka_cli image --directories "$MEDIA_DIR" --similarity-preset "$SIMILARITY" --file-to-save "$REPORT_DIR/duplicate_images.txt"
czkawka_cli video --directories "$MEDIA_DIR" --file-to-save "$REPORT_DIR/duplicate_videos.txt"

echo "==> Running ImageMagick Blur Scans..."
BLUR_REPORT="$REPORT_DIR/blurry_images.txt"
> "$BLUR_REPORT"

find "$MEDIA_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | \
while read -r img; do
  variance=$(convert "$img" -colorspace Gray -define convolve:scale=1 -morphology Convolve Laplacian:0 -format "%[fx:p.u]" info: 2>/dev/null || echo "0")
  is_blurry=$(awk -v v="$variance" -v t="$BLUR_THRESHOLD" 'BEGIN { print (v+0 < t+0) ? "yes" : "no" }')
  if [[ "$is_blurry" == "yes" ]]; then
    echo "$variance $img" >> "$BLUR_REPORT"
  fi
done
sort -n "$BLUR_REPORT" -o "$BLUR_REPORT"
echo "Reports ready inside $REPORT_DIR"

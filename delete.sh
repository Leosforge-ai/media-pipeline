#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="$HOME/czkawka_reports"
TRASH_DIR="/mnt/storage_2tb/media_trash"
DRY_RUN=true

[[ "${1:-}" == "--confirm" ]] && DRY_RUN=false
mkdir -p "$TRASH_DIR"

move_file() {
  local f="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would trash: $f"
  else
    if [[ -f "$f" ]]; then
      mv "$f" "$TRASH_DIR/"
      echo "Trashed: $f"
    fi
  fi
}

if [[ -f "$REPORT_DIR/duplicate_images.txt" ]]; then
  first=true
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then first=true; continue; fi
    if $first; then first=false; else move_file "$line"; fi
  done < "$REPORT_DIR/duplicate_images.txt"
fi

if [[ -f "$REPORT_DIR/duplicate_videos.txt" ]]; then
  first=true
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then first=true; continue; fi
    if $first; then first=false; else move_file "$line"; fi
  done < "$REPORT_DIR/duplicate_videos.txt"
fi

if [[ -f "$REPORT_DIR/blurry_images.txt" ]]; then
  while IFS= read -r line; do
    filepath=$(echo "$line" | awk '{$1=""; print substr($0,2)}')
    move_file "$filepath"
  done < "$REPORT_DIR/blurry_images.txt"
fi

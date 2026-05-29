#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

REMOTE="${REMOTE:-gdrive}"
DEST="$RAW_GDRIVE"
mkdir -p "$DEST"

cat <<EOF
Google Drive import helper
Remote: $REMOTE:
Destination: $DEST

First list folders with:
  rclone lsf $REMOTE: --dirs-only

Then run this script with folder names as arguments, e.g.:
  ./scripts/03_import_gdrive.sh "Fotos" "Wedding "

Notes:
- Quote folder names.
- Preserve trailing spaces inside quotes, e.g. "Wedding ".
EOF

if [[ $# -eq 0 ]]; then
	echo
	echo "No folders supplied. Listing remote folders only:"
	rclone lsf "$REMOTE:" --dirs-only
	exit 0
fi

INCLUDE='{jpg,jpeg,png,heic,heif,webp,gif,mp4,mov,m4v,avi,mkv,3gp,webm,JPG,JPEG,PNG,HEIC,HEIF,WEBP,GIF,MP4,MOV,M4V,AVI,MKV,3GP,WEBM}'

for folder in "$@"; do
	clean_name="${folder%/}"
	clean_name="${clean_name% }"
	[[ -n "$clean_name" ]] || clean_name="gdrive_folder"
	target="$DEST/$clean_name"
	mkdir -p "$target"
	echo "==> Copying $REMOTE:$folder -> $target"
	rclone copy "$REMOTE:$folder" "$target" \
		--include "*.$INCLUDE" \
		--progress \
		--transfers 4 \
		--checkers 8
done

echo "==> Google Drive import complete"
du -sh "$DEST" || true
find "$DEST" -type f | wc -l

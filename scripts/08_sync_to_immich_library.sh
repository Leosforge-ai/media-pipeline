#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

mkdir -p "$IMMICH_LIBRARY"

cat <<EOF
This will COPY the cleaned library into immich_library.
Source:      $CLEANING_STAGING/
Destination: $IMMICH_LIBRARY/

It does not delete cleaning_staging. Keeping cleaning_staging as a backup is recommended until Immich is verified.
EOF

rsync -aH --info=progress2 "$CLEANING_STAGING/" "$IMMICH_LIBRARY/"

echo "==> Verification"
du -sh "$CLEANING_STAGING" "$IMMICH_LIBRARY"
printf 'cleaning_staging files: '
find "$CLEANING_STAGING" -type f | wc -l
printf 'immich_library files:   '
find "$IMMICH_LIBRARY" -type f | wc -l

echo "==> Make library readable by Immich containers"
chmod -R a+rX "$IMMICH_LIBRARY"

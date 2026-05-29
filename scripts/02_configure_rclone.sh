#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
This script opens rclone's interactive Google Drive configuration.
Recommended remote name: gdrive

In rclone config:
  n) New remote
  name> gdrive
  Storage> drive
  Follow rclone prompts for Google login/authorization.

After configuration, test with:
  rclone lsf gdrive: --dirs-only
EOF

rclone config

echo
rclone lsf gdrive: --dirs-only || {
	echo "ERROR: Could not list gdrive:. Re-run rclone config and verify the remote name is gdrive."
	exit 1
}

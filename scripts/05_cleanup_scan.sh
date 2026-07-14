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

# czkawka_cli's exit code for the image/video/dup subcommands is not a
# plain success flag: 0 means "scan ran, nothing found", and 11 is
# czkawka_cli's fixed sentinel value for "scan ran, found
# duplicates/similar items" (confirmed against czkawka_cli/src/main.rs
# upstream -- it is a fixed constant, not a variable count of how many
# groups were found, despite how it reads at first glance). Either way,
# a non-zero exit here is the normal, expected outcome of a scan that
# found something, not an error (see issue #81). Piping through `tee` for
# logging means `pipefail` would otherwise propagate that exit code as the
# pipeline's exit status and abort the whole script the moment the first
# scan finds anything.
#
# We capture czkawka_cli's real exit code via PIPESTATUS[0] (bash-specific,
# already required by this script) instead of trusting the pipeline's
# overall status. Only 0 (nothing found) and 11 (found-duplicates sentinel)
# are treated as non-fatal; every other code is treated as a genuine tool
# failure and aborts the script -- fail closed, rather than trying to
# enumerate every possible crash code, since this repo's data-loss-
# prevention priority means silently trusting a truncated/corrupt report
# from an actual crash is worse than an occasional false-positive abort.
# Known failure modes this covers, called out for diagnostic value:
#   - 101: the default exit code for an uncaught Rust panic (czkawka_cli is
#     a Rust binary) -- a genuine crash.
#   - 126/127: standard shell "found but not executable" / "command not
#     found" codes -- a genuine invocation failure.
#   - 128-255: the standard POSIX/shell convention for "terminated by
#     signal N" is exit code 128+N (normal process exit codes are 0-127).
#     This matters in practice, not just in theory: czkawka_cli is planned
#     to run inside a memory-limited Docker container (#76/PR #80), where
#     an OOM-kill (SIGKILL, exit 137) is a real, materially likelier way
#     for the tool to die mid-scan. A SIGSEGV crash (exit 139) is another
#     example.
# We also check tee's own exit code (PIPESTATUS[1]) separately, since a
# failure to write the log file is a real error unrelated to czkawka_cli's
# exit code.
run_czkawka_scan() {
	local description="$1"
	local log_file="$2"
	shift 2

	echo "==> Running Czkawka $description"
	set +e
	czkawka_cli "$@" 2>&1 | tee "$log_file"
	# Both indices must be read from PIPESTATUS in the same command: bash
	# resets PIPESTATUS after every simple command, so a second `local`
	# statement here would already see PIPESTATUS reset by the first one.
	local czkawka_exit="${PIPESTATUS[0]}" tee_exit="${PIPESTATUS[1]}"
	set -e

	if ((tee_exit != 0)); then
		echo "ERROR: failed to write $log_file (tee exit $tee_exit) during $description." >&2
		exit 1
	fi

	if ((czkawka_exit == 0)); then
		echo "==> Czkawka $description: no duplicates found."
	elif ((czkawka_exit == 11)); then
		echo "==> Czkawka $description: completed, duplicates found (exit 11; see report)."
	else
		echo "ERROR: czkawka_cli failed during $description (exit $czkawka_exit)." >&2
		echo "       This looks like a real tool failure (crash/signal/exec error), not the" >&2
		echo "       found-duplicates sentinel (11). See $log_file." >&2
		exit 1
	fi
}

run_czkawka_scan "similar image scan" "$REPORT_DIR/image_scan_run.log" \
	image \
	-d "$CLEANING_STAGING" \
	-f "$REPORT_DIR/duplicate_images.txt"

run_czkawka_scan "similar video scan" "$REPORT_DIR/video_scan_run.log" \
	video \
	-d "$CLEANING_STAGING" \
	-f "$REPORT_DIR/duplicate_videos.txt"

run_czkawka_scan "exact duplicate file scan" "$REPORT_DIR/duplicate_files_run.log" \
	dup \
	-d "$CLEANING_STAGING" \
	-f "$REPORT_DIR/duplicate_files.txt"

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

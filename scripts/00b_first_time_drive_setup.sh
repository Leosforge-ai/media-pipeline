#!/usr/bin/env bash
# shellcheck disable=SC2153 # HD_PATH/IMMICH_LIBRARY come from pipeline_config.sh, not typos
# First-time drive/Immich setup: detect unmounted candidate drives, print (never
# silently run) the mount/fstab commands, verify structure, then hand off to
# scripts/09_setup_immich.sh.
#
# SAFETY NOTICE
# -------------
# - Detection (lsblk/blkid/findmnt) is read-only and requires no root.
# - This script NEVER runs mount, apt-get, or edits /etc/fstab without an
#   explicit interactive y/n confirmation from the person running it.
# - This script NEVER formats or partitions a drive.
# - The boot/root disk (whatever backs `/`) is always excluded from candidates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/pipeline_config.sh
. "$SCRIPT_DIR/../config/pipeline_config.sh"

# Minimum candidate partition size in bytes. Default 500GB (decimal), override via env.
SIZE_THRESHOLD_BYTES="${SIZE_THRESHOLD_BYTES:-500000000000}"
FSTAB_PATH="${FSTAB_PATH:-/etc/fstab}"

# ---------------------------------------------------------------------------
# Pure logic (unit-testable): filesystem type -> mount metadata
# ---------------------------------------------------------------------------

# fs_is_supported FSTYPE
# Returns 0 if we know how to mount this filesystem type, 1 otherwise.
fs_is_supported() {
	local fstype="$1"
	case "$fstype" in
	ext4 | ext3 | ext2 | ntfs | exfat) return 0 ;;
	*) return 1 ;;
	esac
}

# fs_mount_type_for FSTYPE
# Echoes the `mount -t` argument to use for a detected blkid TYPE.
fs_mount_type_for() {
	local fstype="$1"
	case "$fstype" in
	ext4 | ext3 | ext2) printf '%s\n' "$fstype" ;;
	ntfs) printf 'ntfs-3g\n' ;;
	exfat) printf 'exfat\n' ;;
	*) return 1 ;;
	esac
}

# fs_required_package FSTYPE
# Echoes the apt package required to mount this filesystem type, or nothing
# if none is required (e.g. ext4 is supported by the kernel directly).
fs_required_package() {
	local fstype="$1"
	case "$fstype" in
	ext4 | ext3 | ext2) printf '' ;;
	ntfs) printf 'ntfs-3g\n' ;;
	exfat) printf 'exfatprogs\n' ;;
	*) return 1 ;;
	esac
}

# build_mount_commands DEVICE FSTYPE MOUNT_POINT
# Prints the exact shell commands (one per line) the user should run to
# install any required package and mount DEVICE at MOUNT_POINT. Prints
# nothing and returns 1 for unsupported filesystem types.
build_mount_commands() {
	local device="$1" fstype="$2" mount_point="$3"
	local pkg mount_type

	fs_is_supported "$fstype" || return 1
	mount_type="$(fs_mount_type_for "$fstype")"
	pkg="$(fs_required_package "$fstype")"

	if [[ -n "$pkg" ]]; then
		printf 'sudo apt-get update && sudo apt-get install -y %s\n' "$pkg"
	fi
	printf 'sudo mkdir -p %q\n' "$mount_point"
	printf 'sudo mount -t %s %q %q\n' "$mount_type" "$device" "$mount_point"
}

# ---------------------------------------------------------------------------
# Pure logic (unit-testable): boot-disk exclusion
# ---------------------------------------------------------------------------

# disk_name_from_partition DEVICE_PATH
# Resolves a block device path (e.g. /dev/sda1, /dev/mapper/vg-root) to the
# name of the top-level whole-disk device it ultimately lives on (e.g.
# `sda`), by walking the `lsblk` PKNAME parent chain until a TYPE=disk
# device is reached -- not just a single hop. This matters for LVM roots
# (`/dev/mapper/vg-root` -> its physical-volume partition, e.g. `sda1` -> the
# disk, `sda`) where a single PKNAME hop would stop at the intermediate
# partition and fail to exclude sibling partitions on the same physical
# disk. Any bracketed btrfs subvolume suffix (e.g. `/dev/sda2[/@]`, as
# `findmnt` reports for a subvolume root) is stripped before resolution.
# Falls back to the current device's own base name if lsblk can't report a
# type/parent for it (e.g. it's already a whole disk, or lsblk has nothing
# to say about it -- as in tests with limited stubs).
disk_name_from_partition() {
	local device="$1"
	device="${device%%\[*}" # strip bracketed btrfs subvolume suffix
	local current="$device" type pk name
	local -i hops=0 max_hops=10

	while true; do
		name="$(basename "$current")"
		# -d/--nodeps is required here: without it, lsblk given a
		# whole-disk device (e.g. /dev/nvme0n1) also lists that disk's
		# children (partitions), so `-no TYPE`/`-no PKNAME` return one
		# line per child in addition to the disk's own line. That
		# multi-line output was then being treated as a single value by
		# the `[[ "$type" == "disk" ]]` compare and `current="/dev/$pk"`
		# concatenation below, producing a malformed, embedded-newline,
		# duplicated device "path" that corrupted every later iteration
		# and ultimately this function's own stdout (observed live as
		# `root_boot_disk` returning "\nnvme0n1\nnvme0n1" instead of
		# "nvme0n1" -- see #57). -d restricts each query to exactly the
		# one device passed in, so type/pk are always a single value.
		# The first-line extraction below is kept as a defensive second
		# layer in case any lsblk/stub still returns extra lines.
		type="$(lsblk -d -no TYPE "$current" 2>/dev/null || true)"
		type="${type%%$'\n'*}"
		if [[ "$type" == "disk" ]]; then
			printf '%s\n' "$name"
			return 0
		fi

		pk="$(lsblk -d -no PKNAME "$current" 2>/dev/null || true)"
		pk="${pk%%$'\n'*}"
		if [[ -z "$pk" ]]; then
			printf '%s\n' "$name"
			return 0
		fi

		current="/dev/$pk"
		hops+=1
		if ((hops > max_hops)); then
			printf '%s\n' "$(basename "$current")"
			return 0
		fi
	done
}

# root_boot_disk
# Resolves the top-level disk name backing the current root filesystem ("/"),
# walking through LVM/device-mapper layers and stripping btrfs subvolume
# suffixes as needed. See disk_name_from_partition for details.
root_boot_disk() {
	local root_src
	root_src="$(findmnt / -no SOURCE)"
	disk_name_from_partition "$root_src"
}

# list_candidate_partitions BOOT_DISK THRESHOLD_BYTES
# Reads `lsblk -b -P -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME` output on
# stdin and prints one candidate partition NAME per line: unmounted
# partitions, at least THRESHOLD_BYTES in size, whose parent disk is not
# BOOT_DISK. Pure filter logic -- never touches the real system itself, so
# it can be unit tested by piping in canned lsblk output.
list_candidate_partitions() {
	local boot_disk="$1" threshold="$2"
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		# shellcheck disable=SC2034 # FSTYPE is set by eval below for readability/documentation, not read here
		local NAME="" SIZE="" TYPE="" MOUNTPOINT="" FSTYPE="" PKNAME=""
		# lsblk -P emits shell-quoted KEY="value" pairs; this is the
		# documented way to parse it without column-width ambiguity.
		# shellcheck disable=SC2294
		eval "$line"

		[[ "$TYPE" == "part" ]] || continue
		[[ -z "$MOUNTPOINT" ]] || continue
		[[ "$SIZE" =~ ^[0-9]+$ ]] || continue
		((SIZE >= threshold)) || continue

		local disk="$PKNAME"
		[[ -n "$disk" ]] || disk="$NAME"
		[[ "$disk" != "$boot_disk" ]] || continue

		printf '%s\n' "$NAME"
	done
}

# ---------------------------------------------------------------------------
# Pure logic (unit-testable): idempotent fstab persistence
# ---------------------------------------------------------------------------

# fstab_uuid_present FSTAB_FILE UUID
fstab_uuid_present() {
	local fstab_file="$1" uuid="$2"
	[[ -f "$fstab_file" ]] || return 1
	grep -q "UUID=${uuid}[[:space:]]" "$fstab_file" 2>/dev/null
}

# build_fstab_line UUID MOUNT_POINT FSTYPE
build_fstab_line() {
	local uuid="$1" mount_point="$2" fstype="$3"
	local mount_type
	mount_type="$(fs_mount_type_for "$fstype")"
	printf 'UUID=%s %s %s defaults,nofail 0 2\n' "$uuid" "$mount_point" "$mount_type"
}

# append_fstab_entry FSTAB_FILE UUID MOUNT_POINT FSTYPE
# Idempotent: does nothing (besides a message) if an entry for UUID already
# exists.
append_fstab_entry() {
	local fstab_file="$1" uuid="$2" mount_point="$3" fstype="$4"
	local line

	if fstab_uuid_present "$fstab_file" "$uuid"; then
		echo "fstab already contains an entry for UUID=$uuid, skipping."
		return 0
	fi

	line="$(build_fstab_line "$uuid" "$mount_point" "$fstype")"
	{
		printf '\n# Added by media-pipeline scripts/00b_first_time_drive_setup.sh\n'
		printf '%s\n' "$line"
	} >>"$fstab_file"
	echo "Appended fstab entry: $line"
}

# ---------------------------------------------------------------------------
# Pure logic (unit-testable): pipeline structure verification
# ---------------------------------------------------------------------------

# verify_pipeline_structure HD_PATH IMMICH_LIBRARY_PATH
# Sanity-checks the mounted path before suggesting the user proceed to
# 09_setup_immich.sh. Does not require immich_library/ to already exist
# (09_setup_immich.sh creates it) but refuses to continue if something looks
# wrong (not mounted-writable, or immich_library exists but isn't a
# directory).
verify_pipeline_structure() {
	local hd_path="$1" immich_library="$2"

	if [[ ! -d "$hd_path" ]]; then
		echo "ERROR: $hd_path does not exist or is not a directory."
		return 1
	fi
	if [[ ! -w "$hd_path" ]]; then
		echo "ERROR: $hd_path is not writable by the current user."
		return 1
	fi
	if [[ -e "$immich_library" && ! -d "$immich_library" ]]; then
		echo "ERROR: $immich_library exists but is not a directory. Refusing to continue."
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Interactive flow
# ---------------------------------------------------------------------------

handle_already_mounted() {
	echo
	echo "==> Verifying pipeline structure at $HD_PATH"
	if verify_pipeline_structure "$HD_PATH" "$IMMICH_LIBRARY"; then
		echo "OK: $HD_PATH looks ready."
		echo "Next: run scripts/09_setup_immich.sh to set up Immich."
		return 0
	fi
	echo "WARNING: pipeline structure check failed. Not proceeding automatically."
	return 1
}

offer_fstab_persist() {
	local device="$1" fstype="$2"
	local uuid

	uuid="$(blkid -o value -s UUID "$device" 2>/dev/null || true)"
	if [[ -z "$uuid" ]]; then
		echo "WARNING: could not read UUID for $device; skipping fstab persistence offer."
		return 0
	fi

	if fstab_uuid_present "$FSTAB_PATH" "$uuid"; then
		echo "fstab already has an entry for this drive (UUID=$uuid)."
		return 0
	fi

	echo
	echo "==> Proposed $FSTAB_PATH entry (persists the mount across reboots, uses nofail):"
	build_fstab_line "$uuid" "$HD_PATH" "$fstype"
	echo
	read -r -p "Append this line to $FSTAB_PATH now? [y/N]: " do_fstab
	if [[ "$do_fstab" =~ ^[Yy]$ ]]; then
		append_fstab_entry "$FSTAB_PATH" "$uuid" "$HD_PATH" "$fstype"
	else
		echo "Skipped. Add the line above manually if you want it to survive a reboot."
	fi
}

detect_candidates() {
	local boot_disk="$1"
	lsblk -b -P -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME | list_candidate_partitions "$boot_disk" "$SIZE_THRESHOLD_BYTES"
}

main() {
	echo "==> First-time drive/Immich setup detection"
	echo "Target mount path (from config): $HD_PATH"
	echo

	if findmnt "$HD_PATH" >/dev/null 2>&1; then
		echo "==> $HD_PATH is already mounted."
		handle_already_mounted
		return
	fi

	local boot_disk
	boot_disk="$(root_boot_disk)"
	echo "==> Boot/root disk detected as: $boot_disk (always excluded from candidates)"
	echo

	local -a candidates=()
	local name
	while IFS= read -r name; do
		[[ -n "$name" ]] && candidates+=("$name")
	done < <(detect_candidates "$boot_disk")

	if [[ "${#candidates[@]}" -eq 0 ]]; then
		local threshold_gb=$((SIZE_THRESHOLD_BYTES / 1000 / 1000 / 1000))
		echo "No unmounted candidate partitions >${threshold_gb}GB found (boot disk excluded)."
		echo "If your drive is already mounted somewhere else, set HD_PATH and re-run."
		return 0
	fi

	echo "==> Candidate partitions (unmounted, boot disk excluded):"
	local -A idx_to_device=() idx_to_fstype=()
	local i=1 dev fstype
	for name in "${candidates[@]}"; do
		dev="/dev/$name"
		fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
		printf '  [%d] %s  filesystem=%s\n' "$i" "$dev" "${fstype:-unknown}"
		idx_to_device[$i]="$dev"
		idx_to_fstype[$i]="$fstype"
		i=$((i + 1))
	done

	echo
	local choice
	read -r -p "Select a partition to mount [1-$((i - 1))] or 'q' to quit: " choice
	if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
		echo "Aborted. No changes made."
		return 0
	fi
	if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ -z "${idx_to_device[$choice]:-}" ]]; then
		echo "ERROR: invalid selection."
		return 1
	fi

	local device="${idx_to_device[$choice]}"
	local fstype="${idx_to_fstype[$choice]}"

	if [[ -z "$fstype" ]]; then
		echo "ERROR: could not detect filesystem type for $device. Aborting."
		return 1
	fi

	echo
	echo "==> Commands to mount $device ($fstype) at $HD_PATH:"
	local cmds
	if ! cmds="$(build_mount_commands "$device" "$fstype" "$HD_PATH")"; then
		echo "ERROR: unsupported filesystem type '$fstype'. Supported: ext4, ext3, ext2, ntfs, exfat."
		return 1
	fi
	echo "$cmds"
	echo

	local run_now
	read -r -p "Run these commands now? This requires sudo. [y/N]: " run_now
	if [[ ! "$run_now" =~ ^[Yy]$ ]]; then
		echo "Not executing. Run the commands above manually, then re-run this script."
		return 0
	fi

	echo "==> Executing mount commands"
	local cmd
	while IFS= read -r cmd; do
		[[ -z "$cmd" ]] && continue
		echo "+ $cmd"
		eval "$cmd"
	done <<<"$cmds"

	if ! findmnt "$HD_PATH" >/dev/null 2>&1; then
		echo "ERROR: $HD_PATH does not appear to be mounted after running the mount commands."
		return 1
	fi

	offer_fstab_persist "$device" "$fstype"
	handle_already_mounted
}

# Allow sourcing this script (e.g. from tests) without running main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

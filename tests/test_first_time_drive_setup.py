from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "00b_first_time_drive_setup.sh"


def run_bash(
    body: str,
    hd_path: Path | None = None,
    report_dir: Path | None = None,
    input_text: str | None = None,
    extra_env: dict[str, str] | None = None,
):
    """Source the script (so main() does NOT run) and evaluate `body`.

    This lets us unit-test the pure-logic functions in isolation, without
    touching any real block devices.
    """
    env = {
        **os.environ,
        "HD_PATH": str(hd_path or (ROOT / "_unused_hd_path")),
        "REPORT_DIR": str(report_dir or (ROOT / "_unused_report_dir")),
        **(extra_env or {}),
    }
    script = textwrap.dedent(
        f"""
        set -euo pipefail
        source "{SCRIPT}"
        {body}
        """
    )
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def make_stub_bin(tmp_dir: Path, name: str, script_body: str) -> None:
    stub = tmp_dir / name
    stub.write_text(f"#!/usr/bin/env bash\n{script_body}\n", encoding="utf-8")
    stub.chmod(0o755)


class FsTypeMountCommandMappingTests(unittest.TestCase):
    def test_ext4_needs_no_extra_package(self):
        result = run_bash('build_mount_commands /dev/sdb1 ext4 /mnt/target_drive')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("apt-get", result.stdout)
        self.assertIn("sudo mount -t ext4 /dev/sdb1 /mnt/target_drive", result.stdout)

    def test_ntfs_prints_ntfs_3g_package_and_mount_driver(self):
        result = run_bash('build_mount_commands /dev/sdb1 ntfs /mnt/target_drive')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sudo apt-get install -y ntfs-3g", result.stdout)
        self.assertIn("sudo mount -t ntfs-3g /dev/sdb1 /mnt/target_drive", result.stdout)

    def test_exfat_prints_exfatprogs_package_and_mount_driver(self):
        result = run_bash('build_mount_commands /dev/sdb1 exfat /mnt/target_drive')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sudo apt-get install -y exfatprogs", result.stdout)
        self.assertIn("sudo mount -t exfat /dev/sdb1 /mnt/target_drive", result.stdout)

    def test_unsupported_filesystem_prints_nothing_and_fails(self):
        result = run_bash('build_mount_commands /dev/sdb1 zfs /mnt/target_drive || echo "RC=$?"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RC=1", result.stdout)
        self.assertNotIn("mount -t", result.stdout)

    def test_never_prints_commands_that_actually_run_mount(self):
        # build_mount_commands must only PRINT text, never execute mount/apt-get.
        result = run_bash(
            textwrap.dedent(
                """
                mount() { echo "REAL MOUNT CALLED"; }
                export -f mount
                build_mount_commands /dev/sdb1 ext4 /mnt/target_drive >/dev/null
                """
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("REAL MOUNT CALLED", result.stdout)

    def test_mount_point_with_spaces_is_quoted_and_safe_to_eval(self):
        # A HD_PATH containing spaces must survive a copy-paste/eval of the
        # printed command as a single argument, not split into two.
        mount_point = "/mnt/My External Drive"
        result = run_bash(
            textwrap.dedent(
                f"""
                cmds="$(build_mount_commands /dev/sdb1 ext4 '{mount_point}')"
                echo "$cmds"
                echo "---"
                mkdir() {{ echo "mkdir got $# args: $*"; }}
                export -f mkdir
                mount() {{ echo "mount got $# args: $*"; }}
                export -f mount
                sudo() {{ "$@"; }}
                export -f sudo
                while IFS= read -r cmd; do
                  eval "$cmd"
                done <<<"$cmds"
                """
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        # 2/4 args (not more) proves the mount point survived as one word,
        # not split on its embedded spaces.
        self.assertIn(f"mkdir got 2 args: -p {mount_point}", result.stdout)
        self.assertIn(f"mount got 4 args: -t ext4 /dev/sdb1 {mount_point}", result.stdout)


class BootDiskExclusionTests(unittest.TestCase):
    def test_excludes_partitions_on_the_boot_disk(self):
        lsblk_output = "\n".join(
            [
                'NAME="sda" SIZE="256000000000" TYPE="disk" MOUNTPOINT="" FSTYPE="" PKNAME=""',
                'NAME="sda1" SIZE="1000000000" TYPE="part" MOUNTPOINT="/boot" FSTYPE="ext4" PKNAME="sda"',
                'NAME="sda2" SIZE="250000000000" TYPE="part" MOUNTPOINT="/" FSTYPE="ext4" PKNAME="sda"',
                'NAME="sdb" SIZE="1000000000000" TYPE="disk" MOUNTPOINT="" FSTYPE="" PKNAME=""',
                'NAME="sdb1" SIZE="999000000000" TYPE="part" MOUNTPOINT="" FSTYPE="ntfs" PKNAME="sdb"',
                "",
            ]
        )
        result = run_bash(
            'list_candidate_partitions sda 500000000000',
            input_text=lsblk_output,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        candidates = [line for line in result.stdout.splitlines() if line]
        self.assertEqual(candidates, ["sdb1"])
        # Root ("sda2") and the other boot-disk partition ("sda1") must never
        # appear as candidates under any circumstance.
        self.assertNotIn("sda1", candidates)
        self.assertNotIn("sda2", candidates)

    def test_excludes_boot_disk_even_when_it_is_the_only_large_unmounted_partition(self):
        # Regression guard: a large *unmounted* partition that happens to sit
        # on the boot disk (e.g. a spare partition on the system drive) must
        # still be excluded.
        lsblk_output = "\n".join(
            [
                'NAME="sda" SIZE="2000000000000" TYPE="disk" MOUNTPOINT="" FSTYPE="" PKNAME=""',
                'NAME="sda1" SIZE="250000000000" TYPE="part" MOUNTPOINT="/" FSTYPE="ext4" PKNAME="sda"',
                'NAME="sda2" SIZE="900000000000" TYPE="part" MOUNTPOINT="" FSTYPE="ext4" PKNAME="sda"',
                "",
            ]
        )
        result = run_bash(
            'list_candidate_partitions sda 500000000000',
            input_text=lsblk_output,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")

    def test_filters_out_mounted_and_undersized_partitions(self):
        lsblk_output = "\n".join(
            [
                'NAME="sdb1" SIZE="999000000000" TYPE="part" MOUNTPOINT="/already" FSTYPE="ntfs" PKNAME="sdb"',
                'NAME="sdc1" SIZE="100000000" TYPE="part" MOUNTPOINT="" FSTYPE="ext4" PKNAME="sdc"',
                'NAME="sdd1" SIZE="600000000000" TYPE="part" MOUNTPOINT="" FSTYPE="exfat" PKNAME="sdd"',
                "",
            ]
        )
        result = run_bash(
            'list_candidate_partitions sda 500000000000',
            input_text=lsblk_output,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        candidates = [line for line in result.stdout.splitlines() if line]
        self.assertEqual(candidates, ["sdd1"])

    def test_disk_name_from_partition_uses_lsblk_pkname(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    [[ "$1" == "-d" ]] && shift
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/sda2) echo "sda" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                'disk_name_from_partition /dev/sda2',
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "sda")

    def test_root_boot_disk_resolves_via_findmnt_and_lsblk(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "findmnt",
                textwrap.dedent(
                    """
                    if [[ "$1" == "/" ]]; then
                      echo "/dev/sda2"
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    [[ "$1" == "-d" ]] && shift
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/sda2) echo "sda" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                "root_boot_disk",
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "sda")

    def test_root_boot_disk_walks_lvm_chain_to_top_level_disk(self):
        # Regression for the Cody MEDIUM finding on PR #56: an LVM root
        # (`findmnt /` -> /dev/mapper/vg-root) must resolve all the way to
        # the top-level whole disk (sda), not stop at the intermediate
        # physical-volume partition (sda1) it happens to sit on. Stopping at
        # sda1 would let a sibling partition on the same physical disk
        # (sda2) slip past the boot-disk exclusion filter.
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "findmnt",
                textwrap.dedent(
                    """
                    if [[ "$1" == "/" ]]; then
                      echo "/dev/mapper/vg-root"
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    [[ "$1" == "-d" ]] && shift
                    if [[ "$1" == "-no" && "$2" == "TYPE" ]]; then
                      case "$3" in
                        /dev/mapper/vg-root) echo "lvm" ;;
                        /dev/sda1) echo "part" ;;
                        /dev/sda) echo "disk" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/mapper/vg-root) echo "sda1" ;;
                        /dev/sda1) echo "sda" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                "root_boot_disk",
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "sda")

    def test_lvm_root_excludes_sibling_partition_on_same_physical_disk(self):
        # End-to-end version of the LVM regression: given the boot disk
        # resolved from an LVM root (sda, via /dev/mapper/vg-root -> sda1 ->
        # sda), a large unmounted sibling partition physically on sda
        # (sda2) must still be excluded from candidates -- it must NOT be
        # offered as a mountable drive just because only sda1 was recorded
        # as "the boot disk".
        boot_disk = "sda"  # what root_boot_disk should resolve to for this LVM setup
        lsblk_output = "\n".join(
            [
                'NAME="sda" SIZE="2000000000000" TYPE="disk" MOUNTPOINT="" FSTYPE="" PKNAME=""',
                'NAME="sda1" SIZE="500000000000" TYPE="part" MOUNTPOINT="" FSTYPE="LVM2_member" PKNAME="sda"',
                'NAME="sda2" SIZE="900000000000" TYPE="part" MOUNTPOINT="" FSTYPE="ext4" PKNAME="sda"',
                "",
            ]
        )
        result = run_bash(
            f'list_candidate_partitions {boot_disk} 500000000000',
            input_text=lsblk_output,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")

    def test_disk_name_from_partition_strips_btrfs_subvolume_bracket_suffix(self):
        # Regression for the Cody MEDIUM finding: findmnt reports btrfs
        # subvolume roots as e.g. "/dev/sda2[/@]". The bracketed suffix must
        # be stripped before resolving the device, not left in place where
        # lsblk can't find any matching device and the exclusion silently
        # breaks.
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    [[ "$1" == "-d" ]] && shift
                    if [[ "$1" == "-no" && "$2" == "TYPE" ]]; then
                      case "$3" in
                        /dev/sda2) echo "part" ;;
                        /dev/sda) echo "disk" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/sda2) echo "sda" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                'disk_name_from_partition "/dev/sda2[/@]"',
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "sda")

    def test_root_boot_disk_handles_btrfs_subvolume_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "findmnt",
                textwrap.dedent(
                    """
                    if [[ "$1" == "/" ]]; then
                      echo "/dev/sda2[/@]"
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    [[ "$1" == "-d" ]] && shift
                    if [[ "$1" == "-no" && "$2" == "TYPE" ]]; then
                      case "$3" in
                        /dev/sda2) echo "part" ;;
                        /dev/sda) echo "disk" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/sda2) echo "sda" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                "root_boot_disk",
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "sda")

    # -- Regression tests for #57 bug 2 --------------------------------
    #
    # These stub `lsblk` to reproduce the exact real-world failure mode:
    # called *without* `-d`/`--nodeps` on a whole-disk device that has
    # children (partitions), `lsblk -no TYPE`/`-no PKNAME` returns one line
    # per child in addition to the disk's own line. `disk_name_from_partition`
    # must always pass `-d` so it only ever sees the single device it asked
    # about; if the fix regresses (drops `-d`), the stub below returns the
    # exact malformed multi-line values observed live
    # ("\nnvme0n1\nnvme0n1") and the assertions here would catch it.

    def test_root_boot_disk_single_line_output_simple_partition(self):
        # Regression for #57 bug 2 (reported exactly as: boot disk nvme0n1,
        # root on /dev/nvme0n1p2, no LVM/btrfs).
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "findmnt",
                textwrap.dedent(
                    """
                    if [[ "$1" == "/" ]]; then
                      echo "/dev/nvme0n1p2"
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    if [[ "$1" == "-d" && "$2" == "-no" && "$3" == "TYPE" ]]; then
                      case "$4" in
                        /dev/nvme0n1p2) echo "part" ;;
                        /dev/nvme0n1) echo "disk" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-d" && "$2" == "-no" && "$3" == "PKNAME" ]]; then
                      case "$4" in
                        /dev/nvme0n1p2) echo "nvme0n1" ;;
                        /dev/nvme0n1) echo "" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    # No -d: simulate the real bug -- lsblk lists the
                    # whole disk's children too, one line per child.
                    if [[ "$1" == "-no" && "$2" == "TYPE" ]]; then
                      case "$3" in
                        /dev/nvme0n1p2) echo "part" ;;
                        /dev/nvme0n1) printf 'disk\\npart\\n' ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/nvme0n1p2) echo "nvme0n1" ;;
                        /dev/nvme0n1) printf '\\nnvme0n1\\n' ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                "root_boot_disk",
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("\n"), 1, repr(result.stdout))
            self.assertEqual(result.stdout.strip(), "nvme0n1")

    def test_root_boot_disk_single_line_output_lvm_chain(self):
        # Regression for #57 bug 2, LVM parent-chain case: every hop
        # (vg-root -> sda1 -> sda) must use -d so none of them return
        # polluted multi-line TYPE/PKNAME values.
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "findmnt",
                textwrap.dedent(
                    """
                    if [[ "$1" == "/" ]]; then
                      echo "/dev/mapper/vg-root"
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    if [[ "$1" == "-d" && "$2" == "-no" && "$3" == "TYPE" ]]; then
                      case "$4" in
                        /dev/mapper/vg-root) echo "lvm" ;;
                        /dev/sda1) echo "part" ;;
                        /dev/sda) echo "disk" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-d" && "$2" == "-no" && "$3" == "PKNAME" ]]; then
                      case "$4" in
                        /dev/mapper/vg-root) echo "sda1" ;;
                        /dev/sda1) echo "sda" ;;
                        /dev/sda) echo "" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    # No -d: simulate the bug for the final disk hop, which
                    # has children (sda1, sda2) that would leak extra lines.
                    if [[ "$1" == "-no" && "$2" == "TYPE" ]]; then
                      case "$3" in
                        /dev/mapper/vg-root) echo "lvm" ;;
                        /dev/sda1) echo "part" ;;
                        /dev/sda) printf 'disk\\npart\\npart\\n' ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/mapper/vg-root) echo "sda1" ;;
                        /dev/sda1) echo "sda" ;;
                        /dev/sda) printf '\\nsda\\nsda\\n' ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                "root_boot_disk",
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("\n"), 1, repr(result.stdout))
            self.assertEqual(result.stdout.strip(), "sda")

    def test_root_boot_disk_single_line_output_btrfs_subvolume(self):
        # Regression for #57 bug 2, btrfs subvolume case: the bracket-suffix
        # must be stripped and the remaining hop(s) must use -d.
        with tempfile.TemporaryDirectory() as tmp:
            stub_dir = Path(tmp)
            make_stub_bin(
                stub_dir,
                "findmnt",
                textwrap.dedent(
                    """
                    if [[ "$1" == "/" ]]; then
                      echo "/dev/sda2[/@]"
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            make_stub_bin(
                stub_dir,
                "lsblk",
                textwrap.dedent(
                    """
                    if [[ "$1" == "-d" && "$2" == "-no" && "$3" == "TYPE" ]]; then
                      case "$4" in
                        /dev/sda2) echo "part" ;;
                        /dev/sda) echo "disk" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-d" && "$2" == "-no" && "$3" == "PKNAME" ]]; then
                      case "$4" in
                        /dev/sda2) echo "sda" ;;
                        /dev/sda) echo "" ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    # No -d: simulate the bug -- sda has children (sda1,
                    # sda2), so listing it without -d leaks extra lines.
                    if [[ "$1" == "-no" && "$2" == "TYPE" ]]; then
                      case "$3" in
                        /dev/sda2) echo "part" ;;
                        /dev/sda) printf 'disk\\npart\\npart\\n' ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                      case "$3" in
                        /dev/sda2) echo "sda" ;;
                        /dev/sda) printf '\\nsda\\nsda\\n' ;;
                        *) echo "" ;;
                      esac
                      exit 0
                    fi
                    exit 1
                    """
                ),
            )
            result = run_bash(
                "root_boot_disk",
                extra_env={"PATH": f"{stub_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("\n"), 1, repr(result.stdout))
            self.assertEqual(result.stdout.strip(), "sda")

class FstabIdempotentAppendTests(unittest.TestCase):
    def test_append_writes_uuid_entry_with_nofail(self):
        with tempfile.TemporaryDirectory() as tmp:
            fstab_file = Path(tmp) / "fstab"
            fstab_file.write_text("# existing fstab\n", encoding="utf-8")

            result = run_bash(
                f'append_fstab_entry "{fstab_file}" "1234-ABCD" "/mnt/target_drive" "ext4"'
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            contents = fstab_file.read_text(encoding="utf-8")
            self.assertIn("UUID=1234-ABCD /mnt/target_drive ext4 defaults,nofail 0 2", contents)

    def test_append_is_idempotent_on_rerun(self):
        with tempfile.TemporaryDirectory() as tmp:
            fstab_file = Path(tmp) / "fstab"
            fstab_file.write_text("", encoding="utf-8")

            run_bash(
                f'append_fstab_entry "{fstab_file}" "1234-ABCD" "/mnt/target_drive" "ext4"'
            )
            result = run_bash(
                f'append_fstab_entry "{fstab_file}" "1234-ABCD" "/mnt/target_drive" "ext4"'
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("already contains an entry", result.stdout)

            contents = fstab_file.read_text(encoding="utf-8")
            self.assertEqual(contents.count("UUID=1234-ABCD"), 1)

    def test_does_not_touch_real_etc_fstab(self):
        # Sanity: the function only ever writes to the FSTAB_FILE argument
        # passed in, never a hardcoded /etc/fstab, so tests never risk the
        # real system file.
        real_fstab_mtime_before = (
            os.path.getmtime("/etc/fstab") if os.path.exists("/etc/fstab") else None
        )
        with tempfile.TemporaryDirectory() as tmp:
            fstab_file = Path(tmp) / "fstab"
            fstab_file.write_text("", encoding="utf-8")
            run_bash(
                f'append_fstab_entry "{fstab_file}" "1234-ABCD" "/mnt/target_drive" "ext4"'
            )
        if real_fstab_mtime_before is not None:
            self.assertEqual(
                os.path.getmtime("/etc/fstab"), real_fstab_mtime_before
            )


class PipelineStructureVerificationTests(unittest.TestCase):
    def test_passes_when_mount_writable_and_no_immich_library_yet(self):
        with tempfile.TemporaryDirectory() as tmp:
            hd_path = Path(tmp) / "target_drive"
            hd_path.mkdir()
            immich_library = hd_path / "immich_library"

            result = run_bash(
                f'verify_pipeline_structure "{hd_path}" "{immich_library}"'
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_fails_when_immich_library_exists_as_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            hd_path = Path(tmp) / "target_drive"
            hd_path.mkdir()
            immich_library = hd_path / "immich_library"
            immich_library.write_text("not a directory", encoding="utf-8")

            result = run_bash(
                f'verify_pipeline_structure "{hd_path}" "{immich_library}" || echo "RC=$?"'
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("RC=1", result.stdout)
            self.assertIn("is not a directory", result.stdout)

    def test_fails_when_mount_path_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            hd_path = Path(tmp) / "does_not_exist"
            immich_library = hd_path / "immich_library"

            result = run_bash(
                f'verify_pipeline_structure "{hd_path}" "{immich_library}" || echo "RC=$?"'
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("RC=1", result.stdout)


class FullScriptDetectionFlowTests(unittest.TestCase):
    """End-to-end tests of the interactive script with stubbed system commands.

    These never touch real block devices: lsblk/blkid/findmnt/sudo are all
    replaced with stubs on PATH.
    """

    def _stub_dir(self, tmp: Path) -> Path:
        stub_dir = tmp / "bin"
        stub_dir.mkdir()
        make_stub_bin(
            stub_dir,
            "findmnt",
            textwrap.dedent(
                """
                if [[ "$1" == "/" ]]; then
                  echo "/dev/sda2"
                  exit 0
                fi
                exit 1
                """
            ),
        )
        make_stub_bin(
            stub_dir,
            "lsblk",
            textwrap.dedent(
                """
                [[ "$1" == "-d" ]] && shift
                if [[ "$1" == "-no" && "$2" == "PKNAME" ]]; then
                  case "$3" in
                    /dev/sda2) echo "sda" ;;
                    *) echo "" ;;
                  esac
                  exit 0
                fi
                if [[ "$*" == *"-P"* ]]; then
                  cat <<'LSBLK'
                NAME="sda" SIZE="256000000000" TYPE="disk" MOUNTPOINT="" FSTYPE="" PKNAME=""
                NAME="sda1" SIZE="1000000000" TYPE="part" MOUNTPOINT="/boot" FSTYPE="ext4" PKNAME="sda"
                NAME="sda2" SIZE="250000000000" TYPE="part" MOUNTPOINT="/" FSTYPE="ext4" PKNAME="sda"
                NAME="sdb" SIZE="1000000000000" TYPE="disk" MOUNTPOINT="" FSTYPE="" PKNAME=""
                NAME="sdb1" SIZE="999000000000" TYPE="part" MOUNTPOINT="" FSTYPE="ntfs" PKNAME="sdb"
                LSBLK
                  exit 0
                fi
                exit 0
                """
            ),
        )
        make_stub_bin(
            stub_dir,
            "blkid",
            textwrap.dedent(
                """
                dev="${*: -1}"
                if [[ "$*" == *"-s TYPE"* ]]; then
                  case "$dev" in
                    /dev/sdb1) echo "ntfs" ;;
                    *) echo "" ;;
                  esac
                  exit 0
                fi
                exit 0
                """
            ),
        )
        return stub_dir

    def test_detection_only_lists_non_boot_candidate_and_takes_no_action_on_quit(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            stub_dir = self._stub_dir(tmp_path)
            hd_path = tmp_path / "target_drive"

            env = {
                **os.environ,
                "HD_PATH": str(hd_path),
                "REPORT_DIR": str(tmp_path / "reports"),
                "PATH": f"{stub_dir}:{os.environ['PATH']}",
            }
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=ROOT,
                env=env,
                input="q\n",
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Boot/root disk detected as: sda", result.stdout)
            self.assertIn("[1] /dev/sdb1  filesystem=ntfs", result.stdout)
            self.assertNotIn("/dev/sda", result.stdout.split("Candidate partitions")[-1])
            self.assertIn("Aborted. No changes made.", result.stdout)
            # Detection-only path must never create/mount anything.
            self.assertFalse(hd_path.exists())

    def test_declining_to_run_mount_commands_makes_no_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            stub_dir = self._stub_dir(tmp_path)
            hd_path = tmp_path / "target_drive"

            env = {
                **os.environ,
                "HD_PATH": str(hd_path),
                "REPORT_DIR": str(tmp_path / "reports"),
                "PATH": f"{stub_dir}:{os.environ['PATH']}",
            }
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=ROOT,
                env=env,
                input="1\nn\n",
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sudo mount -t ntfs-3g /dev/sdb1", result.stdout)
            self.assertIn("Not executing.", result.stdout)
            self.assertFalse(hd_path.exists())


if __name__ == "__main__":
    unittest.main()

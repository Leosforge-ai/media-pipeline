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

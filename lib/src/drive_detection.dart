import 'dart:io';

/// Dart port of the READ-ONLY detection logic in
/// `scripts/00b_first_time_drive_setup.sh` (Phase 0a of issue #76/#77's
/// shared roadmap). This module intentionally covers *only* detection:
/// boot/root-disk resolution, candidate-partition filtering, and
/// filesystem-type detection. It never mounts anything, never edits
/// `/etc/fstab`, and never formats/partitions a drive — matching the Bash
/// script's own safety notice. The confirmation-gated mount/fstab actions
/// stay in the Bash script for now; porting those is a later phase.
///
/// The orchestration/parsing logic mirrors the Bash functions of the same
/// name/purpose (see the doc comments on each Bash function for the full
/// history of bugs this design avoids — #56/#57/#58/#59, PR #66):
/// - `lsblk_ancestor_chain_raw` / `disk_name_from_partition` /
///   `root_boot_disk` -> [DriveDetector.lsblkAncestorChain] /
///   [DriveDetector.diskNameFromPartition] / [DriveDetector.rootBootDisk],
///   built on [parseLsblkPairLines] and [resolveDiskNameFromAncestorChain].
/// - `list_candidate_partitions` -> [filterCandidatePartitions], fed by
///   [DriveDetector.listAllPartitionRows] / [parseLsblkPartitionRows].
/// - `detect_fstype` -> [DriveDetector.detectFstype], built on
///   [extractFirstLine].
///
/// Unlike the Bash version (which has to stub `lsblk`/`blkid`/`findmnt` on
/// `PATH` to unit test its parsing/filtering logic), every pure function
/// below takes plain strings/data and is unit-testable with zero
/// subprocesses. [DriveDetector] is the thin async layer that actually
/// shells out, using `Process.run` the same way `pipeline_runner.dart` does.

/// Default minimum candidate partition size in bytes (500GB decimal),
/// matching the Bash script's `SIZE_THRESHOLD_BYTES` default.
const int defaultSizeThresholdBytes = 500000000000;

// ---------------------------------------------------------------------------
// Pure logic: shell-quoted `lsblk -P` KEY="value" line parsing
// ---------------------------------------------------------------------------

final RegExp _lsblkPairPattern = RegExp(r'(\w+)="([^"]*)"');

/// Parses `lsblk -P` output (one shell-quoted `KEY="value" ...` line per
/// row) into a list of `{KEY: value}` maps, one per non-blank line, in the
/// same order lsblk printed them. This is the Dart-native equivalent of the
/// Bash script's `eval "$line"` parsing trick, without needing to `eval`
/// anything.
List<Map<String, String>> parseLsblkPairLines(String raw) {
  final rows = <Map<String, String>>[];
  for (final line in raw.split('\n')) {
    if (line.trim().isEmpty) continue;
    final row = <String, String>{};
    for (final match in _lsblkPairPattern.allMatches(line)) {
      row[match.group(1)!] = match.group(2)!;
    }
    if (row.isNotEmpty) rows.add(row);
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Pure logic: boot-disk resolution
// ---------------------------------------------------------------------------

/// Strips a bracketed btrfs subvolume suffix (e.g. `/dev/sda2[/@]`, as
/// `findmnt` reports for a subvolume root) from [device], mirroring the
/// Bash script's `device="${device%%\[*}"`.
String stripBtrfsSubvolumeSuffix(String device) {
  final index = device.indexOf('[');
  return index == -1 ? device : device.substring(0, index);
}

/// Returns the base name of a device path (e.g. `/dev/sda1` -> `sda1`),
/// mirroring Bash's `basename`.
String deviceBaseName(String device) {
  final index = device.lastIndexOf('/');
  return index == -1 ? device : device.substring(index + 1);
}

/// Given the rows of an lsblk `-s`/`--inverse` ancestor-chain query (see
/// [DriveDetector.lsblkAncestorChain]), returns the `NAME` of the row whose
/// `TYPE` is `disk` — the top-level whole-disk device the chain resolves
/// to — or `null` if no such row is present.
///
/// A whole-disk device queried with `-s` reports only its own single row
/// (never its children — that's the entire point of the `-s` primitive
/// from PR #66), so at most one `TYPE=disk` row is ever expected in a
/// well-formed chain; if more than one somehow appeared, the last one wins,
/// same as the Bash loop which keeps overwriting `disk_name` as it reads.
String? diskNameFromAncestorRows(List<Map<String, String>> rows) {
  String? diskName;
  for (final row in rows) {
    if (row['TYPE'] == 'disk') {
      diskName = row['NAME'];
    }
  }
  return diskName;
}

/// Resolves a block device path (e.g. `/dev/sda1`, `/dev/mapper/vg-root`,
/// or a bracketed btrfs subvolume path) to the name of its top-level
/// whole-disk device (e.g. `sda`), given the ancestor-chain rows already
/// fetched for it. Falls back to the device's own base name if
/// [ancestorRows] contains no `TYPE=disk` row at all — matching the Bash
/// fallback for when lsblk has nothing to say about the device.
String resolveDiskNameFromAncestorChain({
  required String device,
  required List<Map<String, String>> ancestorRows,
}) {
  final stripped = stripBtrfsSubvolumeSuffix(device);
  return diskNameFromAncestorRows(ancestorRows) ?? deviceBaseName(stripped);
}

// ---------------------------------------------------------------------------
// Pure logic: candidate partition filtering
// ---------------------------------------------------------------------------

/// One row of `lsblk -b -P -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME`
/// output.
class LsblkPartitionRow {
  const LsblkPartitionRow({
    required this.name,
    required this.sizeBytes,
    required this.type,
    required this.mountpoint,
    required this.fstype,
    required this.pkname,
  });

  final String name;

  /// Null if `SIZE` was missing or not a plain non-negative integer —
  /// mirrors the Bash filter's `[[ "$SIZE" =~ ^[0-9]+$ ]]` guard, which
  /// rejects such rows as candidates rather than crashing on them.
  final int? sizeBytes;
  final String type;
  final String mountpoint;
  final String fstype;
  final String pkname;
}

final RegExp _plainNonNegativeInteger = RegExp(r'^[0-9]+$');

/// Parses `lsblk -b -P -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME` output
/// into [LsblkPartitionRow]s.
List<LsblkPartitionRow> parseLsblkPartitionRows(String raw) {
  return [
    for (final row in parseLsblkPairLines(raw))
      LsblkPartitionRow(
        name: row['NAME'] ?? '',
        sizeBytes: _plainNonNegativeInteger.hasMatch(row['SIZE'] ?? '')
            ? int.parse(row['SIZE']!)
            : null,
        type: row['TYPE'] ?? '',
        mountpoint: row['MOUNTPOINT'] ?? '',
        fstype: row['FSTYPE'] ?? '',
        pkname: row['PKNAME'] ?? '',
      ),
  ];
}

/// Filters [rows] down to candidate partition names: unmounted partitions
/// at least [thresholdBytes] in size, whose parent disk is not [bootDisk].
/// Pure filter logic mirroring the Bash `list_candidate_partitions`
/// function — never touches the real system, so it's directly unit
/// testable against canned lsblk rows.
List<String> filterCandidatePartitions({
  required List<LsblkPartitionRow> rows,
  required String bootDisk,
  int thresholdBytes = defaultSizeThresholdBytes,
}) {
  final candidates = <String>[];
  for (final row in rows) {
    if (row.type != 'part') continue;
    if (row.mountpoint.isNotEmpty) continue;
    final size = row.sizeBytes;
    if (size == null || size < thresholdBytes) continue;

    final disk = row.pkname.isNotEmpty ? row.pkname : row.name;
    if (disk == bootDisk) continue;

    candidates.add(row.name);
  }
  return candidates;
}

// ---------------------------------------------------------------------------
// Pure logic: filesystem-type detection (lsblk-first, sudo-blkid-fallback)
// ---------------------------------------------------------------------------

/// Extracts the first line of [raw] (matching the Bash script's
/// `fstype="${fstype%%$'\n'*}"` truncation), trimmed, or `null` if empty.
/// Used for both `lsblk -no FSTYPE` and `blkid -o value -s TYPE` output,
/// which each report a single value on their own first line.
String? extractFirstLine(String raw) {
  final trimmed = raw.split('\n').first.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ---------------------------------------------------------------------------
// Async orchestration: shells out to lsblk/blkid/findmnt via Process.run,
// same pattern as PipelineRunner in pipeline_runner.dart.
// ---------------------------------------------------------------------------

/// Callback fired right before [DriveDetector.detectFstype] falls back to
/// `sudo blkid`, so a caller can surface the same heads-up the Bash script
/// prints — this may trigger a sudo password prompt, so it must never be a
/// silent surprise.
typedef SudoFallbackWarning = void Function(String device);

/// Shells out to `lsblk`/`blkid`/`findmnt` to perform the same read-only
/// drive detection as `scripts/00b_first_time_drive_setup.sh`'s detection
/// phase. Every method here is read-only: none of them mount, format,
/// partition, or edit `/etc/fstab`.
class DriveDetector {
  const DriveDetector();

  /// Runs `lsblk -o NAME,TYPE -P -s DEVICE` and parses its ancestor-chain
  /// rows. Mirrors `lsblk_ancestor_chain_raw`: `-s`/`--inverse` is lsblk's
  /// own "print the dependency chain of this device" mode, so this never
  /// leaks a whole disk's child-partition rows into the result the way an
  /// unqualified `lsblk DEVICE` call would.
  Future<List<Map<String, String>>> lsblkAncestorChain(String device) async {
    final result = await _runIgnoringFailure('lsblk', [
      '-o',
      'NAME,TYPE',
      '-P',
      '-s',
      device,
    ]);
    return parseLsblkPairLines(result);
  }

  /// Resolves [device] (e.g. `/dev/sda1`, `/dev/mapper/vg-root`, or a
  /// bracketed btrfs subvolume path) to the name of its top-level
  /// whole-disk device (e.g. `sda`).
  Future<String> diskNameFromPartition(String device) async {
    final stripped = stripBtrfsSubvolumeSuffix(device);
    final ancestorRows = await lsblkAncestorChain(stripped);
    return resolveDiskNameFromAncestorChain(
      device: device,
      ancestorRows: ancestorRows,
    );
  }

  /// Resolves the top-level disk name backing the current root filesystem
  /// (`/`), walking through LVM/device-mapper layers and stripping btrfs
  /// subvolume suffixes as needed.
  Future<String> rootBootDisk() async {
    final result = await Process.run('findmnt', ['/', '-no', 'SOURCE']);
    final source = (result.stdout as String).trim();
    return diskNameFromPartition(source);
  }

  /// Runs `lsblk -b -P -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME` and
  /// parses every row on the system.
  Future<List<LsblkPartitionRow>> listAllPartitionRows() async {
    final result = await _runIgnoringFailure('lsblk', [
      '-b',
      '-P',
      '-o',
      'NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME',
    ]);
    return parseLsblkPartitionRows(result);
  }

  /// Lists unmounted candidate partition names (>= [thresholdBytes],
  /// excluding [bootDisk]).
  Future<List<String>> candidatePartitions({
    required String bootDisk,
    int thresholdBytes = defaultSizeThresholdBytes,
  }) async {
    final rows = await listAllPartitionRows();
    return filterCandidatePartitions(
      rows: rows,
      bootDisk: bootDisk,
      thresholdBytes: thresholdBytes,
    );
  }

  /// Detects the filesystem type of [device], trying `lsblk -d -no FSTYPE`
  /// first (typically unprivileged/world-readable cached metadata) and
  /// only falling back to `sudo blkid -o value -s TYPE` if lsblk comes back
  /// empty (see #57: unprivileged `blkid` alone was seen returning nothing
  /// for a valid, already-populated ext4 partition on a real machine).
  /// [onSudoFallback], if given, fires before the sudo fallback runs so a
  /// caller can print the same heads-up the Bash script does — this may
  /// trigger a sudo password prompt and must never be a silent surprise.
  Future<String?> detectFstype(
    String device, {
    SudoFallbackWarning? onSudoFallback,
  }) async {
    final lsblkOutput = await _runIgnoringFailure('lsblk', [
      '-d',
      '-no',
      'FSTYPE',
      device,
    ]);
    final fromLsblk = extractFirstLine(lsblkOutput);
    if (fromLsblk != null) return fromLsblk;

    onSudoFallback?.call(device);

    final blkidOutput = await _runIgnoringFailure('sudo', [
      'blkid',
      '-o',
      'value',
      '-s',
      'TYPE',
      device,
    ]);
    return extractFirstLine(blkidOutput);
  }
}

/// Runs [executable] with [arguments], returning stdout as a string.
/// Mirrors the Bash script's `... 2>/dev/null || true` pattern: a
/// non-zero exit code or a process that can't be started at all (e.g. the
/// device doesn't exist) is treated the same as "no answer" rather than
/// thrown, since every caller here only cares about read-only detection
/// output, never about failing loudly on a missing/foreign device.
Future<String> _runIgnoringFailure(
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(executable, arguments);
    return result.stdout as String? ?? '';
  } on ProcessException {
    return '';
  }
}

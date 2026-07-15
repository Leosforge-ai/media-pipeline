import 'dart:io';

/// Shared, safety-critical file-move primitive extracted from
/// `restore_from_trash.dart` (Phase 0b of issue #76/#77's shared roadmap).
///
/// Every confirm-gated destructive script in this pipeline
/// (`06_delete_duplicates.sh`, `11_restore_from_trash.sh`,
/// `12_clean_immich_takeout_duplicates.sh`, `13_dedupe_live_photos.sh`) needs
/// the exact same cross-device-safe move fallback — if the move crosses
/// filesystems and a plain rename fails with `EXDEV`, fall back to copy +
/// byte-length verification + delete-original, the same way real `mv`
/// transparently handles cross-device moves; see
/// [SafeFileMover.copyVerifyAndReplace]. But the four real Bash scripts do
/// NOT all resolve a *destination collision* the same way, so this
/// primitive exposes two distinct collision strategies rather than one:
///
/// - [SafeFileMover.moveNoClobber]: plain `mv -n` semantics — a colliding
///   destination is left alone and the source stays put
///   ([MoveResult.skippedExisting]). This is the exact behavior of
///   `11_restore_from_trash.sh`, whose Bash implementation really is a
///   literal `mv -n` with no renaming logic at all.
/// - [SafeFileMover.moveRenamingOnCollision]: Bash's `unique_destination()`
///   semantics — a colliding destination gets a numbered-suffix alternative
///   (`_1`, `_2`, ...) via [uniqueDestinationPath], and the move always
///   succeeds ([MoveResult.movedWithSuffix]). This is the exact behavior of
///   `06_delete_duplicates.sh`, `12_clean_immich_takeout_duplicates.sh`, and
///   `13_dedupe_live_photos.sh` — `06` and `12` each carry an identical
///   inline copy of the `unique_destination()`/`trash_file()` algorithm;
///   `13`'s `move_or_report_video` follows the same pattern. See
///   [uniqueDestinationPath]'s doc comment for the exact algorithm this port
///   matches, split-point quirks included.
///
/// Earlier revisions of this primitive had every caller skip-on-collision
/// (only [moveNoClobber] existed) — a real, reviewed deviation from Bash for
/// 06/12/13, flagged across PRs #86/#87/#88. Leo's #76/#77 review decision
/// was to match each real Bash script's actual collision behavior exactly,
/// not to invent one uniform Dart-only policy: `restore_from_trash.dart`
/// keeps using [moveNoClobber] unchanged (it already matched its real Bash
/// script), while `delete_duplicates.dart`, `clean_takeout_duplicates.dart`,
/// and `dedupe_live_photos.dart` now use [moveRenamingOnCollision] instead.
///
/// [SafeFileMover] was pulled out of `TrashRestorer` (the only caller at the
/// time) so the other three Dart ports in this series could reuse it instead
/// of each re-implementing this safety-critical logic from scratch.
///
/// This never deletes a source file before its destination copy is verified
/// on disk, and never leaves a partial/corrupt destination file stranded on
/// any copy or verification failure — see [SafeFileMover.copyVerifyAndReplace].

/// Copies [src] to [dst]. The default implementation just calls
/// `File(src).copy(dst)`; [SafeFileMover]'s constructor accepts an
/// alternative so tests can simulate a corrupt/partial copy (e.g. one that
/// writes truncated bytes) without needing a genuine cross-device rename
/// failure to trigger the fallback path that uses it.
typedef FileCopier = Future<void> Function(String src, String dst);

/// Default [FileCopier]: a plain `File.copy`. Public so callers elsewhere
/// (e.g. `restore_from_trash.dart`'s `TrashRestorer`) can reference the same
/// default value for their own pass-through `copier` parameters.
Future<void> defaultFileCopier(String src, String dst) =>
    File(src).copy(dst).then((_) {});

/// What happened when [SafeFileMover.moveNoClobber] or
/// [SafeFileMover.moveRenamingOnCollision] was asked to move a file.
enum MoveResult {
  /// The file was moved from source directly to the requested destination —
  /// no collision was found.
  moved,

  /// [SafeFileMover.moveNoClobber] only: the destination already existed,
  /// so — matching `mv -n`'s no-clobber semantics exactly — the source was
  /// left in place, untouched, rather than overwriting the existing
  /// destination or raising an error.
  skippedExisting,

  /// [SafeFileMover.moveRenamingOnCollision] only: the requested destination
  /// already existed, so — matching Bash's `unique_destination()` exactly —
  /// the file was moved to a numbered-suffix alternative instead. See
  /// [MoveOutcome.destinationPath] for the actual path used.
  movedWithSuffix,
}

/// The result of [SafeFileMover.moveRenamingOnCollision]: what happened, and
/// the actual destination path the file landed at (which may differ from the
/// originally requested destination — see [MoveResult.movedWithSuffix]).
class MoveOutcome {
  const MoveOutcome({required this.result, required this.destinationPath});

  final MoveResult result;

  /// The path the file actually landed at. Equal to the requested
  /// destination for [MoveResult.moved]; a numbered-suffix alternative for
  /// [MoveResult.movedWithSuffix].
  final String destinationPath;
}

/// A safe, cross-device-aware file mover with two collision strategies (see
/// this file's top-level doc comment for which real Bash script matches
/// which strategy): [moveNoClobber] (`mv -n`, skip-on-collision) and
/// [moveRenamingOnCollision] (`unique_destination()`, rename-on-collision).
class SafeFileMover {
  const SafeFileMover({this.copier = defaultFileCopier});

  /// Only ever overridden by tests (see [FileCopier]'s doc comment); real
  /// callers always get the default `File.copy` implementation.
  final FileCopier copier;

  /// Moves [src] to [dst], creating [dst]'s parent directory (recursively)
  /// first if it doesn't already exist. Never overwrites an existing [dst]:
  /// if one is already present, [src] is left untouched and
  /// [MoveResult.skippedExisting] is returned, matching `mv -n` exactly.
  /// Matches `11_restore_from_trash.sh`'s real Bash behavior — see this
  /// file's top-level doc comment.
  ///
  /// Otherwise, moves the file (see [_moveFile] for the rename/cross-device
  /// fallback behavior) and returns [MoveResult.moved].
  Future<MoveResult> moveNoClobber(String src, String dst) async {
    if (await File(dst).exists()) {
      return MoveResult.skippedExisting;
    }
    await Directory(parentDirectory(dst)).create(recursive: true);
    await _moveFile(src, dst);
    return MoveResult.moved;
  }

  /// Moves [src] to [dst] if [dst] doesn't already exist; otherwise resolves
  /// a numbered-suffix alternative via [uniqueDestinationPath] and moves
  /// there instead — the move always succeeds, never skips, matching Bash's
  /// `unique_destination()` guarantee that a move into `$MEDIA_TRASH` always
  /// lands somewhere. Matches `06_delete_duplicates.sh`,
  /// `12_clean_immich_takeout_duplicates.sh`, and
  /// `13_dedupe_live_photos.sh`'s real Bash behavior — see this file's
  /// top-level doc comment.
  ///
  /// Creates the resolved destination's parent directory (recursively)
  /// first if it doesn't already exist, then moves the file (see
  /// [_moveFile] for the rename/cross-device fallback behavior).
  Future<MoveOutcome> moveRenamingOnCollision(String src, String dst) async {
    final resolvedDst = uniqueDestinationPath(
      dst,
      (path) => File(path).existsSync(),
    );
    final result = resolvedDst == dst
        ? MoveResult.moved
        : MoveResult.movedWithSuffix;
    await Directory(parentDirectory(resolvedDst)).create(recursive: true);
    await _moveFile(src, resolvedDst);
    return MoveOutcome(result: result, destinationPath: resolvedDst);
  }

  /// Moves [src] to [dst]. `File.rename` is a single atomic syscall when
  /// both paths share a filesystem/mount point — the common case, and the
  /// direct equivalent of `mv -n`'s fast path. If source and destination
  /// ever live on *different* filesystems, `File.rename` fails the same way
  /// a cross-device `mv` fails at the syscall level (`EXDEV`), unlike real
  /// `mv`, which transparently falls back to copy+delete in that case. This
  /// falls back the same way real `mv` would: copy, verify the copy landed
  /// correctly, then delete the original — never deleting [src] before
  /// [dst] is confirmed on disk.
  Future<void> _moveFile(String src, String dst) async {
    final srcFile = File(src);
    try {
      await srcFile.rename(dst);
    } on FileSystemException catch (e) {
      if (!_isCrossDeviceError(e)) rethrow;
      await copyVerifyAndReplace(src, dst);
    }
  }

  /// The cross-device fallback body: copy [src] to [dst], verify the copy
  /// landed correctly, then delete the original — never deleting [src]
  /// before [dst] is confirmed on disk. On *any* failure of the copy or
  /// its verification, the known-bad partial/corrupt [dst] is deleted
  /// before the failure propagates: [src] is still safely intact at that
  /// point (it's only ever deleted after verification succeeds), so
  /// removing a bad [dst] here is safe cleanup, not a risky one.
  ///
  /// Without this cleanup, [moveNoClobber]'s existence-only no-clobber
  /// check (`File(dst).exists()`) would see the corrupt leftover on any
  /// future move attempt and silently report [MoveResult.skippedExisting]
  /// forever — permanently masking the still-good source file, even though
  /// nothing was technically ever *deleted* (Cody review finding on PR #82,
  /// originally against `TrashRestorer` before this logic was extracted).
  /// [moveRenamingOnCollision] would instead keep finding the same corrupt
  /// leftover "occupied" and keep incrementing its numbered suffix forever
  /// on every retry — the same class of masking bug, just manifesting as an
  /// ever-growing `_N` instead of a permanent skip. This cleanup prevents
  /// both.
  ///
  /// Only public so tests can exercise this exact failure-cleanup path
  /// directly (via [FileCopier] injection simulating a truncated/corrupt
  /// copy) without needing a genuine cross-device (`EXDEV`) rename failure
  /// to trigger it — that requires two distinct mounted filesystems, which
  /// isn't available in this sandbox or in CI. Production code only ever
  /// reaches this via [_moveFile]'s cross-device catch branch above.
  Future<void> copyVerifyAndReplace(String src, String dst) async {
    final srcFile = File(src);
    final srcLength = await srcFile.length();
    try {
      await copier(src, dst);
      final dstLength = await File(dst).length();
      if (dstLength != srcLength) {
        throw FileSystemException(
          'Cross-device move copy verification failed: '
          'expected $srcLength bytes, got $dstLength',
          dst,
        );
      }
    } catch (_) {
      final partial = File(dst);
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    }
    await srcFile.delete();
  }

  /// True if [e] represents a cross-device/cross-filesystem rename failure
  /// (`EXDEV`, errno 18 on Linux/macOS) rather than some other rename
  /// failure (permissions, missing parent, etc.), which should still
  /// propagate as-is.
  bool _isCrossDeviceError(FileSystemException e) {
    final osError = e.osError;
    if (osError != null && osError.errorCode == 18) return true;
    // Fall back to a message check: some platforms/Dart SDK versions don't
    // populate a reliable errorCode for this case, but always mention
    // "Invalid cross-device link" (the standard EXDEV strerror() text) in
    // the exception message.
    return e.message.toLowerCase().contains('cross-device');
  }
}

/// Returns the parent directory of [path] (e.g. `/a/b/c.jpg` -> `/a/b`),
/// mirroring Bash's `dirname`. Used by [SafeFileMover.moveNoClobber]/
/// [SafeFileMover.moveRenamingOnCollision] to know which directories need
/// `mkdir -p` equivalent creation before a move; public (and re-exported
/// from `restore_from_trash.dart`) since it's also a generally useful pure
/// path helper with its own direct test coverage.
String parentDirectory(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return '/';
  return trimmed.substring(0, index);
}

// ---------------------------------------------------------------------------
// Pure logic: Bash-parity port of unique_destination()
// ---------------------------------------------------------------------------

/// Checks whether [path] already exists. Kept as a plain, synchronous
/// function type (rather than [PathExistsChecker]-style async, as
/// `clean_takeout_duplicates.dart` uses for its own file checks) so
/// [uniqueDestinationPath] stays a pure, synchronous, zero-I/O function that
/// tests can exercise against an in-memory `Set<String>` of "existing"
/// paths, with no `Future`/`async` machinery at all — the same
/// injectable-primitive spirit as [FileCopier], just synchronous because the
/// underlying Bash `[[ -e "$dst" ]]` check this mirrors is synchronous too.
typedef PathExists = bool Function(String path);

/// Bash-parity port of `unique_destination()`, the collision-resolution
/// algorithm `scripts/06_delete_duplicates.sh` (inline, inside
/// `trash_file()`) and `scripts/12_clean_immich_takeout_duplicates.sh`
/// (as its own top-level `unique_destination()` function) both carry an
/// identical copy of:
///
/// ```bash
/// unique_destination() {
/// 	local dst="$1"
/// 	if [[ ! -e "$dst" ]]; then
/// 		printf '%s\n' "$dst"
/// 		return
/// 	fi
///
/// 	local base suffix i candidate
/// 	base="${dst%.*}"
/// 	suffix=".${dst##*.}"
/// 	[[ "$base" == "$dst" ]] && suffix=""
/// 	i=1
/// 	while true; do
/// 		candidate="${base}_$i$suffix"
/// 		if [[ ! -e "$candidate" ]]; then
/// 			printf '%s\n' "$candidate"
/// 			return
/// 		fi
/// 		i=$((i + 1))
/// 	done
/// }
/// ```
///
/// If [exists] reports [desiredPath] doesn't already exist, returns it
/// unchanged (`[[ ! -e "$dst" ]]` early return).
///
/// Otherwise, splits [desiredPath] at its **last** `.` — Bash's
/// `${dst%.*}` (shortest suffix match, i.e. the text after the last `.` in
/// the whole string) / `${dst##*.}` (longest prefix-stripped match, the
/// same last-`.`-onward text including the dot). Two quirks of this Bash
/// expansion are deliberately reproduced here exactly, warts included,
/// because Leo's #76/#77 review decision was parity with the real Bash
/// implementation this pipeline has run in production, not a "fixed"
/// version that would silently diverge from what `06`/`12`'s Bash still do
/// verbatim:
///
/// - It operates on the **full path string**, not just the basename. If a
///   *directory* component contains a `.` and the filename itself has none,
///   the split point lands in the directory, not the filename — e.g.
///   `/a/b.c/photo` (no dot in `photo`) splits to base `/a/b`, suffix
///   `.c/photo`, NOT base `/a/b.c/photo` with no suffix. Confirmed against
///   real `bash` during this port (see
///   `test/filesystem_ops_test.dart`'s parity test), not assumed.
/// - A dotfile with no other `.` (e.g. `/a/b/.bashrc`) still "has" a dot —
///   the leading one — so it splits to base `/a/b/`, suffix `.bashrc`, not
///   treated as extension-less.
///
/// If [desiredPath] has no `.` anywhere, there is no suffix: the whole path
/// is the base, and numbered candidates are just `<path>_1`, `<path>_2`, ...
/// with nothing appended after the number.
///
/// Then tries `<base>_1<suffix>`, `<base>_2<suffix>`, `<base>_3<suffix>`,
/// ... in order, returning the first one [exists] reports as not already
/// present. No upper retry bound — this matches Bash's `unique_destination()`
/// exactly, which loops unboundedly too; that unbounded-retry characteristic
/// is a pre-existing property of the real Bash algorithm, not a new risk
/// introduced by this port.
String uniqueDestinationPath(String desiredPath, PathExists exists) {
  if (!exists(desiredPath)) return desiredPath;

  final dotIndex = desiredPath.lastIndexOf('.');
  final base = dotIndex < 0 ? desiredPath : desiredPath.substring(0, dotIndex);
  final suffix = dotIndex < 0 ? '' : desiredPath.substring(dotIndex);

  var i = 1;
  while (true) {
    final candidate = '${base}_$i$suffix';
    if (!exists(candidate)) return candidate;
    i++;
  }
}

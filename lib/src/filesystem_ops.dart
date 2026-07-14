import 'dart:io';

/// Shared, safety-critical file-move primitive extracted from
/// `restore_from_trash.dart` (Phase 0b of issue #76/#77's shared roadmap).
///
/// Every confirm-gated destructive script in this pipeline
/// (`06_delete_duplicates.sh`, `11_restore_from_trash.sh`,
/// `12_clean_immich_takeout_duplicates.sh`, `13_dedupe_live_photos.sh`) needs
/// the exact same move semantics, in both directions (original -> trash, and
/// trash -> original on restore): move a file without ever overwriting an
/// existing destination (`mv -n`'s no-clobber behavior), and — if the move
/// crosses filesystems and a plain rename fails with `EXDEV` — fall back to
/// copy + byte-length verification + delete-original, the same way real `mv`
/// transparently handles cross-device moves. [SafeFileMover] was pulled out
/// of `TrashRestorer` (the only caller so far) so the next three Dart ports
/// in this series (06/12/13, still Bash today) can reuse it instead of each
/// re-implementing this safety-critical logic from scratch.
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

/// What happened when [SafeFileMover.moveNoClobber] was asked to move a
/// file: either it actually moved, or the destination already existed and
/// was left alone.
enum MoveResult {
  /// The file was moved from source to destination.
  moved,

  /// The destination already existed, so — matching `mv -n`'s no-clobber
  /// semantics exactly — the source was left in place, untouched, rather
  /// than overwriting the existing destination or raising an error.
  skippedExisting,
}

/// A safe, no-clobber, cross-device-aware file mover.
///
/// [moveNoClobber] is the primitive every "move this file elsewhere, keeping
/// the original safe until the copy is verified, and never clobbering an
/// existing destination" call site in this pipeline should use.
class SafeFileMover {
  const SafeFileMover({this.copier = defaultFileCopier});

  /// Only ever overridden by tests (see [FileCopier]'s doc comment); real
  /// callers always get the default `File.copy` implementation.
  final FileCopier copier;

  /// Moves [src] to [dst], creating [dst]'s parent directory (recursively)
  /// first if it doesn't already exist. Never overwrites an existing [dst]:
  /// if one is already present, [src] is left untouched and
  /// [MoveResult.skippedExisting] is returned, matching `mv -n` exactly.
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
/// mirroring Bash's `dirname`. Used by [SafeFileMover.moveNoClobber] to know
/// which directories need `mkdir -p` equivalent creation before a move;
/// public (and re-exported from `restore_from_trash.dart`) since it's also a
/// generally useful pure path helper with its own direct test coverage.
String parentDirectory(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return '/';
  return trimmed.substring(0, index);
}

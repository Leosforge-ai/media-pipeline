import 'dart:io';

/// Dart port of `scripts/11_restore_from_trash.sh` (Phase 0b of issue
/// #76/#77's shared roadmap). This is the pipeline's sole recovery
/// mechanism — every other confirm-gated destructive script
/// (`06_delete_duplicates.sh`, `12_clean_immich_takeout_duplicates.sh`,
/// `13_dedupe_live_photos.sh`) moves files into `$MEDIA_TRASH` rather than
/// deleting them, on the assumption that this restore path can always
/// reverse it. Treat correctness here as the highest priority of any port
/// in this series.
///
/// The Bash script never deletes anything either: it only ever moves a file
/// from trash back to its reconstructed original location. This port
/// preserves that invariant exactly — nothing in this file ever calls
/// anything equivalent to `rm`.
///
/// Mirrors the Bash script's two functional pieces:
/// - Path reconstruction (`rel="${f#"$MEDIA_TRASH"/}"; dest="/$rel"`) ->
///   [reconstructOriginalPath], a pure string function with zero
///   filesystem/subprocess dependency — even more trivially unit-testable
///   than the drive-detection port's pure functions, since there is no
///   external tool output to parse at all.
/// - The `find ... | while read` walk + dry-run/confirm `mv -n` loop ->
///   [TrashRestorer.run], the thin async layer that actually touches the
///   filesystem, using `Directory.list`/`File.rename` the same way
///   `DriveDetector` in `drive_detection.dart` uses `Process.run`.
///
/// Bug-class note (regression target for PR #61/#63): the Bash script used
/// to always exit 1 in `--confirm` mode, even on a fully successful
/// restore, because its last statement was a bare
/// `[[ "$DRY_RUN" -eq 1 ]] && echo ...` — under `set -e`, a bare AND-list
/// ending on a false condition becomes the exit status of the whole script
/// when it's the last statement executed. This Dart port has no equivalent
/// footgun by construction: [TrashRestorer.run] signals success by
/// returning a `List<RestoreOutcome>` and signals failure exclusively by
/// throwing (see [TrashRootNotFoundException] and the cross-device-copy
/// verification in [TrashRestorer]); there is no exit-code/last-statement
/// mechanism in Dart for a print statement to accidentally hijack.

// ---------------------------------------------------------------------------
// Pure logic: original-path reconstruction
// ---------------------------------------------------------------------------

/// Thrown by [reconstructOriginalPath] when [trashedFilePath] is not
/// actually located under [trashRoot] — a caller error, since every path
/// fed to this function should have come from walking [trashRoot] itself.
class NotUnderTrashRootException implements Exception {
  NotUnderTrashRootException(this.trashRoot, this.trashedFilePath);

  final String trashRoot;
  final String trashedFilePath;

  @override
  String toString() =>
      'NotUnderTrashRootException: "$trashedFilePath" is not under trash '
      'root "$trashRoot"';
}

/// Reconstructs a trashed file's original absolute path, mirroring the Bash
/// script's `rel="${f#"$MEDIA_TRASH"/}"; dest="/$rel"`: strip the
/// `trashRoot/` prefix from [trashedFilePath] and prepend `/`.
///
/// Pure string manipulation — no filesystem access, no subprocess, so every
/// nested-path/spaces/unicode case is directly unit-testable with plain
/// string fixtures. [trashRoot] may or may not have a trailing slash; both
/// are accepted, matching how Bash's `${var#prefix}` parameter expansion
/// would behave regardless of how `$MEDIA_TRASH` happens to be set.
String reconstructOriginalPath({
  required String trashRoot,
  required String trashedFilePath,
}) {
  final normalizedRoot =
      trashRoot.endsWith('/') && trashRoot.length > 1
          ? trashRoot.substring(0, trashRoot.length - 1)
          : trashRoot;
  final prefix = '$normalizedRoot/';
  if (!trashedFilePath.startsWith(prefix)) {
    throw NotUnderTrashRootException(trashRoot, trashedFilePath);
  }
  final rel = trashedFilePath.substring(prefix.length);
  return '/$rel';
}

/// Returns the parent directory of [path] (e.g. `/a/b/c.jpg` -> `/a/b`),
/// mirroring Bash's `dirname`. Pure string manipulation, used to know which
/// directories need `mkdir -p` equivalent creation before a restore move.
String parentDirectory(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return '/';
  return trimmed.substring(0, index);
}

// ---------------------------------------------------------------------------
// Async orchestration: walks $MEDIA_TRASH and moves files back, the same
// way DriveDetector in drive_detection.dart shells out via Process.run.
// ---------------------------------------------------------------------------

/// Thrown when [TrashRestorer.run] is asked to restore from a trash root
/// that does not exist. Mirrors the Bash script's own behavior: it never
/// `mkdir -p`s `$MEDIA_TRASH` itself (unlike scripts 06/12/13, which create
/// it as their trash *destination*), so `find "$MEDIA_TRASH"` on a missing
/// directory fails loudly under `set -e` rather than silently reporting
/// "nothing to restore".
class TrashRootNotFoundException implements Exception {
  TrashRootNotFoundException(this.trashRoot);

  final String trashRoot;

  @override
  String toString() =>
      'TrashRootNotFoundException: trash root does not exist: "$trashRoot"';
}

/// What happened (or would happen) to a single trashed file, one per entry
/// in the list [TrashRestorer.run] returns.
enum RestoreAction {
  /// Dry-run mode: printed what *would* happen; nothing touched on disk.
  wouldRestore,

  /// Confirm mode: the file was actually moved back to [destinationPath].
  restored,

  /// Confirm mode: [destinationPath] already existed, so — matching `mv
  /// -n`'s no-clobber semantics exactly — the file was left in place in the
  /// trash, untouched, rather than overwriting the existing destination or
  /// raising an error.
  skippedExisting,
}

/// The outcome of processing one trashed file: where it was found, where it
/// reconstructs to, and what happened.
class RestoreOutcome {
  const RestoreOutcome({
    required this.trashPath,
    required this.destinationPath,
    required this.action,
  });

  final String trashPath;
  final String destinationPath;
  final RestoreAction action;

  @override
  String toString() =>
      'RestoreOutcome($action, $trashPath -> $destinationPath)';
}

/// Walks `trashRoot` recursively and, for each file found, restores it to
/// its reconstructed original absolute path — or, in dry-run mode (the
/// default, matching the Bash script), only reports what would happen.
class TrashRestorer {
  const TrashRestorer();

  /// Lists every regular file currently under [trashRoot], recursively, in
  /// sorted order (for deterministic output — the Bash script's `find` has
  /// no guaranteed order either, but sorted output makes tests and logs
  /// reproducible). Throws [TrashRootNotFoundException] if [trashRoot]
  /// doesn't exist, matching the Bash script's own hard failure in that
  /// case (see that exception's doc comment).
  Future<List<String>> listTrashedFilePaths(String trashRoot) async {
    final dir = Directory(trashRoot);
    if (!await dir.exists()) {
      throw TrashRootNotFoundException(trashRoot);
    }
    final paths = <String>[
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      ))
        if (entity is File) entity.path,
    ];
    paths.sort();
    return paths;
  }

  /// Restores every file under [trashRoot] to its reconstructed original
  /// location, or — if [confirm] is `false` (the default) — only reports
  /// what would happen, touching nothing. Mirrors the Bash script's
  /// dry-run-first default and `--confirm` gate exactly; this method never
  /// prompts for a typed confirmation phrase itself, matching script 11
  /// (unlike scripts 12/13, it only requires the `--confirm` flag, not a
  /// typed phrase — callers wire the flag from the same place the Bash
  /// script's CLI argument comes from).
  ///
  /// Returns the list of [RestoreOutcome]s. Never deletes anything: every
  /// action taken is either "no-op" (dry-run, or skip-existing) or a move
  /// from [RestoreOutcome.trashPath] to [RestoreOutcome.destinationPath].
  Future<List<RestoreOutcome>> run({
    required String trashRoot,
    bool confirm = false,
  }) async {
    final trashPaths = await listTrashedFilePaths(trashRoot);
    final outcomes = <RestoreOutcome>[];
    for (final trashPath in trashPaths) {
      final destinationPath = reconstructOriginalPath(
        trashRoot: trashRoot,
        trashedFilePath: trashPath,
      );

      if (!confirm) {
        outcomes.add(
          RestoreOutcome(
            trashPath: trashPath,
            destinationPath: destinationPath,
            action: RestoreAction.wouldRestore,
          ),
        );
        continue;
      }

      if (await File(destinationPath).exists()) {
        // mv -n: never clobber an existing destination. The file stays in
        // the trash — still not deleted, just not yet restorable until the
        // conflict is resolved by hand.
        outcomes.add(
          RestoreOutcome(
            trashPath: trashPath,
            destinationPath: destinationPath,
            action: RestoreAction.skippedExisting,
          ),
        );
        continue;
      }

      await Directory(parentDirectory(destinationPath)).create(
        recursive: true,
      );
      await _moveFile(trashPath, destinationPath);
      outcomes.add(
        RestoreOutcome(
          trashPath: trashPath,
          destinationPath: destinationPath,
          action: RestoreAction.restored,
        ),
      );
    }
    return outcomes;
  }

  /// Moves [src] to [dst]. `File.rename` is a single atomic syscall when
  /// both paths share a filesystem/mount point — the common case, and the
  /// direct equivalent of the Bash script's `mv -n`. If trash and the
  /// reconstructed destination ever live on *different* filesystems (e.g.
  /// `$MEDIA_TRASH` on one mounted drive, the original absolute path
  /// resolving under another), `File.rename` fails the same way a
  /// cross-device `mv` fails at the syscall level (`EXDEV`), unlike real
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

      final srcLength = await srcFile.length();
      await srcFile.copy(dst);
      final dstLength = await File(dst).length();
      if (dstLength != srcLength) {
        throw FileSystemException(
          'Cross-device restore copy verification failed: '
          'expected $srcLength bytes, got $dstLength',
          dst,
        );
      }
      await srcFile.delete();
    }
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

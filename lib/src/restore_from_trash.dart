import 'dart:io';

import 'filesystem_ops.dart';

// `parentDirectory` (dirname port) now lives in `filesystem_ops.dart`, since
// [SafeFileMover.moveNoClobber] needs it too; re-exported here so existing
// callers/tests importing it from this file keep working unchanged.
export 'filesystem_ops.dart' show parentDirectory;

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
///   filesystem, using `Directory.list` the same way `DriveDetector` in
///   `drive_detection.dart` uses `Process.run`, and delegating the actual
///   no-clobber/cross-device-safe move to the shared [SafeFileMover]
///   primitive in `filesystem_ops.dart` (extracted from this file — see
///   that file's doc comment — since the next three Dart ports in this
///   series, 06/12/13, need the exact same move semantics).
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
/// verification in [SafeFileMover]); there is no exit-code/last-statement
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
  final normalizedRoot = trashRoot.endsWith('/') && trashRoot.length > 1
      ? trashRoot.substring(0, trashRoot.length - 1)
      : trashRoot;
  final prefix = '$normalizedRoot/';
  if (!trashedFilePath.startsWith(prefix)) {
    throw NotUnderTrashRootException(trashRoot, trashedFilePath);
  }
  final rel = trashedFilePath.substring(prefix.length);
  return '/$rel';
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
///
/// The actual move — no-clobber, cross-device-safe, copy-verify-delete
/// fallback — is delegated entirely to the shared [SafeFileMover] primitive
/// in `filesystem_ops.dart`; this class is now a thin caller that only
/// handles trash-specific concerns: walking `trashRoot`, reconstructing
/// original paths, and the dry-run/confirm gate.
class TrashRestorer {
  const TrashRestorer({this.copier = defaultFileCopier});

  /// Only ever overridden by tests (see [FileCopier]'s doc comment on
  /// `filesystem_ops.dart`); real callers always get the default
  /// `File.copy` implementation. Threaded straight through to the
  /// [SafeFileMover] this class delegates its actual moves to.
  final FileCopier copier;

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
      await for (final entity in dir.list(recursive: true, followLinks: false))
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
    final mover = SafeFileMover(copier: copier);
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

      // mv -n: never clobber an existing destination. On a skip, the file
      // stays in the trash — still not deleted, just not yet restorable
      // until the conflict is resolved by hand. See [SafeFileMover] in
      // `filesystem_ops.dart` for the no-clobber/cross-device-safe move
      // logic itself.
      final result = await mover.moveNoClobber(trashPath, destinationPath);
      outcomes.add(
        RestoreOutcome(
          trashPath: trashPath,
          destinationPath: destinationPath,
          action: result == MoveResult.moved
              ? RestoreAction.restored
              : RestoreAction.skippedExisting,
        ),
      );
    }
    return outcomes;
  }
}

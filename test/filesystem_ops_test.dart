import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/filesystem_ops.dart';

void main() {
  group('parentDirectory (dirname port)', () {
    test('returns the parent of a nested path', () {
      expect(parentDirectory('/a/b/c.jpg'), '/a/b');
    });

    test('returns "/" for a top-level path', () {
      expect(parentDirectory('/c.jpg'), '/');
    });

    test('returns "/" for the root path itself', () {
      expect(parentDirectory('/'), '/');
    });
  });

  group('SafeFileMover.moveNoClobber (generic move-safety primitive)', () {
    // These tests exercise SafeFileMover directly, independent of any
    // caller (e.g. TrashRestorer) — the primitive is shared by every
    // confirm-gated destructive script that needs "move this file
    // elsewhere, never overwriting an existing destination, safely across
    // filesystems." restore_from_trash_test.dart still covers the
    // trash-specific round-trip (path reconstruction + this primitive
    // together); these tests cover the primitive in isolation.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('filesystem_ops_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('moves a file to a destination, creating parent directories as '
        'needed, and reports MoveResult.moved', () async {
      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('bytes');
      final dst = File('${tempDir.path}/nested/dir/dst.jpg');

      const mover = SafeFileMover();
      final result = await mover.moveNoClobber(src.path, dst.path);

      expect(result, MoveResult.moved);
      expect(await src.exists(), isFalse);
      expect(await dst.exists(), isTrue);
      expect(await dst.readAsString(), 'bytes');
    });

    test('no-clobber: an existing destination is left untouched and '
        'MoveResult.skippedExisting is returned, matching `mv -n`', () async {
      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('new-bytes');
      final dst = File('${tempDir.path}/dst.jpg');
      await dst.writeAsString('existing-bytes');

      const mover = SafeFileMover();
      final result = await mover.moveNoClobber(src.path, dst.path);

      expect(result, MoveResult.skippedExisting);
      // Neither file touched: src stays exactly where it was, dst keeps
      // its original content — nothing overwritten, nothing deleted.
      expect(await src.exists(), isTrue);
      expect(await src.readAsString(), 'new-bytes');
      expect(await dst.readAsString(), 'existing-bytes');
    });
  });

  group('cross-device rename fallback: copyVerifyAndReplace', () {
    // SafeFileMover's private _moveFile tries File.rename first (matching
    // `mv -n`'s fast path) and, only on a cross-device/cross-filesystem
    // failure (EXDEV, errno 18 — detected via
    // FileSystemException.osError.errorCode or a "cross-device" message
    // fallback), falls back to copyVerifyAndReplace(): copy + verify +
    // delete, mirroring what real `mv` does transparently across
    // filesystems.
    //
    // Reproducing a genuine EXDEV to reach this fallback via moveNoClobber
    // itself would require two distinct mounted filesystems/devices, which
    // isn't available in this sandbox or in CI — that specific trigger
    // remains a documented gap (see the last test in this group). But the
    // fallback body itself (copyVerifyAndReplace) is exposed directly and
    // takes an injectable [FileCopier], so its actual copy/verify/cleanup
    // logic — including the failure-cleanup path Cody flagged on PR #82
    // (originally against TrashRestorer, before this logic was extracted
    // here), where a corrupt/partial destination must never be left
    // stranded to silently mask a still-good source file — is fully
    // exercised here without needing EXDEV at all.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('filesystem_ops_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('happy path: copies, verifies, then deletes the original', () async {
      final src = File('${tempDir.path}/src.jpg');
      final dst = File('${tempDir.path}/dst.jpg');
      await src.writeAsString('original-bytes');

      const mover = SafeFileMover();
      await mover.copyVerifyAndReplace(src.path, dst.path);

      expect(await src.exists(), isFalse);
      expect(await dst.exists(), isTrue);
      expect(await dst.readAsString(), 'original-bytes');
    });

    test('verification-failure cleanup: a corrupt/truncated copy is deleted '
        'before the failure propagates, never left stranded to mask the '
        'still-good original (Cody review finding on PR #82)', () async {
      final src = File('${tempDir.path}/src.jpg');
      final dst = File('${tempDir.path}/dst.jpg');
      await src.writeAsString('original-bytes-longer-than-truncated');

      // Simulate a copy that lands a truncated/corrupt destination file
      // rather than throwing outright — the case a real interrupted
      // cross-device copy could produce.
      final mover = SafeFileMover(
        copier: (srcPath, dstPath) async {
          await File(dstPath).writeAsString('truncated');
        },
      );

      await expectLater(
        mover.copyVerifyAndReplace(src.path, dst.path),
        throwsA(isA<FileSystemException>()),
      );

      // The corrupt partial destination must be gone, not stranded...
      expect(await dst.exists(), isFalse);
      // ...and the original must still be safely intact, since it's only
      // ever deleted after verification succeeds.
      expect(await src.exists(), isTrue);
      expect(await src.readAsString(), 'original-bytes-longer-than-truncated');
    });

    test('copier-throws cleanup: if the copier itself throws after partially '
        'writing dst, the partial file is still cleaned up', () async {
      final src = File('${tempDir.path}/src.jpg');
      final dst = File('${tempDir.path}/dst.jpg');
      await src.writeAsString('original-bytes');

      final mover = SafeFileMover(
        copier: (srcPath, dstPath) async {
          // Simulate a copy that writes a partial file, then fails
          // outright (e.g. a real disk-full or I/O error mid-copy).
          await File(dstPath).writeAsString('partial');
          throw const FileSystemException('simulated mid-copy I/O error');
        },
      );

      await expectLater(
        mover.copyVerifyAndReplace(src.path, dst.path),
        throwsA(isA<FileSystemException>()),
      );

      expect(await dst.exists(), isFalse);
      expect(await src.exists(), isTrue);
      expect(await src.readAsString(), 'original-bytes');
    });

    test(
      'no partial destination to clean up: verification failure when the '
      'copier never created dst at all does not throw a secondary error',
      () async {
        final src = File('${tempDir.path}/src.jpg');
        final dst = File('${tempDir.path}/dst.jpg');
        await src.writeAsString('original-bytes');

        final mover = SafeFileMover(
          copier: (srcPath, dstPath) async {
            // Copier reports success without actually writing anything —
            // an extreme edge case, but must not crash the cleanup step
            // (which only deletes dst if it actually exists).
          },
        );

        await expectLater(
          mover.copyVerifyAndReplace(src.path, dst.path),
          throwsA(isA<FileSystemException>()),
        );

        expect(await dst.exists(), isFalse);
        expect(await src.exists(), isTrue);
      },
    );

    test('documented gap: reaching this fallback via a genuine EXDEV rename '
        'failure (rather than calling copyVerifyAndReplace directly, as the '
        'tests above do) requires two real mounted filesystems, not '
        'exercisable via a single temp directory — flagging for reviewer '
        'awareness (Cody/Astrid) rather than claiming coverage that '
        "doesn't exist", () {
      expect(true, isTrue);
    });
  });
}

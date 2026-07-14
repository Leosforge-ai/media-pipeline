import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/restore_from_trash.dart';

void main() {
  group('reconstructOriginalPath (pure, zero filesystem/subprocess deps)', () {
    test('reconstructs a simple nested original path', () {
      expect(
        reconstructOriginalPath(
          trashRoot: '/mnt/data/media_trash',
          trashedFilePath: '/mnt/data/media_trash/home/leo/photo.jpg',
        ),
        '/home/leo/photo.jpg',
      );
    });

    test('reconstructs a deeply nested original path', () {
      expect(
        reconstructOriginalPath(
          trashRoot: '/mnt/data/media_trash',
          trashedFilePath:
              '/mnt/data/media_trash/mnt/target_drive/immich_library/'
              'Takeout/Google Fotos/2024/IMG_0001.HEIC',
        ),
        '/mnt/target_drive/immich_library/Takeout/Google Fotos/2024/'
        'IMG_0001.HEIC',
      );
    });

    test('preserves paths with spaces', () {
      expect(
        reconstructOriginalPath(
          trashRoot: '/mnt/media_trash',
          trashedFilePath:
              '/mnt/media_trash/home/leo/Fotos de 2024/foto vacaciones.jpg',
        ),
        '/home/leo/Fotos de 2024/foto vacaciones.jpg',
      );
    });

    test('preserves unicode characters', () {
      expect(
        reconstructOriginalPath(
          trashRoot: '/mnt/media_trash',
          trashedFilePath: '/mnt/media_trash/home/léo/日本語/写真_①.jpg',
        ),
        '/home/léo/日本語/写真_①.jpg',
      );
    });

    test('accepts a trash root with a trailing slash identically', () {
      final withoutSlash = reconstructOriginalPath(
        trashRoot: '/mnt/media_trash',
        trashedFilePath: '/mnt/media_trash/a/b.jpg',
      );
      final withSlash = reconstructOriginalPath(
        trashRoot: '/mnt/media_trash/',
        trashedFilePath: '/mnt/media_trash/a/b.jpg',
      );
      expect(withSlash, withoutSlash);
      expect(withSlash, '/a/b.jpg');
    });

    test('throws when the path is not actually under the trash root', () {
      expect(
        () => reconstructOriginalPath(
          trashRoot: '/mnt/media_trash',
          trashedFilePath: '/mnt/other_dir/a.jpg',
        ),
        throwsA(isA<NotUnderTrashRootException>()),
      );
    });

    test(
      'a bare filename equal to the trash root (no trailing content) is '
      'rejected, not silently reconstructed to "/"',
      () {
        expect(
          () => reconstructOriginalPath(
            trashRoot: '/mnt/media_trash',
            trashedFilePath: '/mnt/media_trash',
          ),
          throwsA(isA<NotUnderTrashRootException>()),
        );
      },
    );
  });

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

  group('TrashRestorer dry-run mode (real temp directory, no subprocess)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'restore_from_trash_test_',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('reports what would be restored without touching anything', () async {
      final trashRoot = Directory('${tempDir.path}/media_trash');
      final trashedFile = File(
        '${trashRoot.path}${tempDir.path}/original/photo.jpg',
      );
      await trashedFile.create(recursive: true);
      await trashedFile.writeAsString('photo-bytes');
      final beforeStat = await trashedFile.stat();

      final destinationPath = reconstructOriginalPath(
        trashRoot: trashRoot.path,
        trashedFilePath: trashedFile.path,
      );
      final destinationFile = File(destinationPath);

      const restorer = TrashRestorer();
      final outcomes = await restorer.run(trashRoot: trashRoot.path);

      expect(outcomes, hasLength(1));
      expect(outcomes.single.action, RestoreAction.wouldRestore);
      expect(outcomes.single.trashPath, trashedFile.path);
      expect(outcomes.single.destinationPath, destinationPath);

      // Nothing touched: the trashed file is untouched (same content/mtime)
      // and the destination was never created.
      expect(await trashedFile.exists(), isTrue);
      final afterStat = await trashedFile.stat();
      expect(afterStat.modified, beforeStat.modified);
      expect(await trashedFile.readAsString(), 'photo-bytes');
      expect(await destinationFile.exists(), isFalse);
    });

    test('throws TrashRootNotFoundException for a missing trash root', () {
      const restorer = TrashRestorer();
      expect(
        () => restorer.run(trashRoot: '${tempDir.path}/does_not_exist'),
        throwsA(isA<TrashRootNotFoundException>()),
      );
    });

    test('an empty (existing) trash root yields no outcomes', () async {
      final trashRoot = Directory('${tempDir.path}/empty_trash');
      await trashRoot.create(recursive: true);

      const restorer = TrashRestorer();
      final outcomes = await restorer.run(trashRoot: trashRoot.path);

      expect(outcomes, isEmpty);
    });
  });

  group('TrashRestorer confirm mode (real temp directory)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'restore_from_trash_test_',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'moves a trashed file back to its reconstructed destination',
      () async {
        final trashRoot = Directory('${tempDir.path}/media_trash');
        final originalDir = '${tempDir.path}/restored_target';
        final trashedFile = File('${trashRoot.path}$originalDir/photo.jpg');
        await trashedFile.create(recursive: true);
        await trashedFile.writeAsString('photo-bytes');

        final destinationPath = reconstructOriginalPath(
          trashRoot: trashRoot.path,
          trashedFilePath: trashedFile.path,
        );

        const restorer = TrashRestorer();
        final outcomes = await restorer.run(
          trashRoot: trashRoot.path,
          confirm: true,
        );

        expect(outcomes, hasLength(1));
        expect(outcomes.single.action, RestoreAction.restored);
        expect(outcomes.single.destinationPath, destinationPath);

        expect(await trashedFile.exists(), isFalse);
        final destinationFile = File(destinationPath);
        expect(await destinationFile.exists(), isTrue);
        expect(await destinationFile.readAsString(), 'photo-bytes');
      },
    );

    test(
      'no-clobber: an existing destination file is left alone, not '
      'overwritten, matching `mv -n`',
      () async {
        final trashRoot = Directory('${tempDir.path}/media_trash');
        final originalDir = Directory('${tempDir.path}/existing_target');
        await originalDir.create(recursive: true);

        final existingDestination = File(
          '${originalDir.path}/photo.jpg',
        );
        await existingDestination.writeAsString('existing-original-bytes');

        final trashedFile = File(
          '${trashRoot.path}${existingDestination.path}',
        );
        await trashedFile.create(recursive: true);
        await trashedFile.writeAsString('trashed-duplicate-bytes');

        const restorer = TrashRestorer();
        final outcomes = await restorer.run(
          trashRoot: trashRoot.path,
          confirm: true,
        );

        expect(outcomes, hasLength(1));
        expect(outcomes.single.action, RestoreAction.skippedExisting);

        // Existing destination file must be completely untouched.
        expect(
          await existingDestination.readAsString(),
          'existing-original-bytes',
        );
        // The trashed duplicate is neither deleted nor overwritten — it
        // stays exactly where it was, in the trash, unresolved.
        expect(await trashedFile.exists(), isTrue);
        expect(
          await trashedFile.readAsString(),
          'trashed-duplicate-bytes',
        );
      },
    );

    test(
      r'round-trip: a file trashed under the $MEDIA_TRASH/<full-original-'
      'absolute-path> convention (matching scripts 06/12/13) restores to '
      'exactly its original path',
      () async {
        final trashRoot = Directory('${tempDir.path}/media_trash');
        final originalPath =
            '${tempDir.path}/immich_library/Takeout/Google Fotos/'
            'Fotos de 2024/IMG_1951.HEIC';
        // Mirror the convention: dst="$MEDIA_TRASH/$rel" where
        // rel="${duplicate#/}" — i.e. the full original absolute path with
        // its leading slash stripped, appended under the trash root.
        final trashedPath = '${trashRoot.path}$originalPath';
        final trashedFile = File(trashedPath);
        await trashedFile.create(recursive: true);
        await trashedFile.writeAsString('duplicate-heic-bytes');

        const restorer = TrashRestorer();
        final outcomes = await restorer.run(
          trashRoot: trashRoot.path,
          confirm: true,
        );

        expect(outcomes, hasLength(1));
        expect(outcomes.single.destinationPath, originalPath);
        expect(outcomes.single.action, RestoreAction.restored);

        final restoredFile = File(originalPath);
        expect(await restoredFile.exists(), isTrue);
        expect(await restoredFile.readAsString(), 'duplicate-heic-bytes');
        expect(await trashedFile.exists(), isFalse);
      },
    );

    test(
      'restores multiple nested files, creating destination directories '
      'as needed',
      () async {
        final trashRoot = Directory('${tempDir.path}/media_trash');
        final firstOriginal = '${tempDir.path}/a/one.jpg';
        final secondOriginal = '${tempDir.path}/a/b/two.jpg';

        final firstTrashed = File('${trashRoot.path}$firstOriginal');
        final secondTrashed = File('${trashRoot.path}$secondOriginal');
        await firstTrashed.create(recursive: true);
        await firstTrashed.writeAsString('one');
        await secondTrashed.create(recursive: true);
        await secondTrashed.writeAsString('two');

        const restorer = TrashRestorer();
        final outcomes = await restorer.run(
          trashRoot: trashRoot.path,
          confirm: true,
        );

        expect(outcomes, hasLength(2));
        expect(await File(firstOriginal).readAsString(), 'one');
        expect(await File(secondOriginal).readAsString(), 'two');
      },
    );
  });

  group(
    'success/failure signaling has no PR #61/#63-equivalent footgun',
    () {
      // Regression context: the Bash script's --confirm mode used to always
      // exit 1 even on a fully successful restore, because its very last
      // statement was a bare `[[ "$DRY_RUN" -eq 1 ]] && echo ...` — under
      // `set -e`, a false bare AND-list as the script's last executed
      // statement becomes the whole script's exit code. No test exercised
      // --confirm end-to-end at the time, so it went uncaught (fixed in
      // f0bcb70 / PR #61 & #63).
      //
      // This Dart port has no equivalent mechanism by construction: success
      // is signaled by TrashRestorer.run returning a
      // `Future<List<RestoreOutcome>>` that completes normally, and failure
      // is signaled exclusively by that Future completing with an error
      // (thrown exception) — there is no separate "last statement" or
      // "exit code" side channel a trailing print/log statement could
      // accidentally hijack. The tests below prove the Future actually
      // completes successfully (not just that it doesn't throw at some
      // intermediate step) for the exact shape of case the Bash bug hid in:
      // a fully successful --confirm run with real work done and a trailing
      // informational log statement.
      late Directory tempDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'restore_from_trash_test_',
        );
      });

      tearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      test(
        'a fully successful --confirm-equivalent run completes the '
        'Future normally with the expected outcomes, not with an error',
        () async {
          final trashRoot = Directory('${tempDir.path}/media_trash');
          final original = '${tempDir.path}/only/file.jpg';
          final trashed = File('${trashRoot.path}$original');
          await trashed.create(recursive: true);
          await trashed.writeAsString('bytes');

          const restorer = TrashRestorer();

          // expectAsync/expect on a Future directly proves normal
          // completion: if run() completed with an error instead (the bug
          // class this guards against), this await would throw and fail
          // the test loudly, rather than silently reporting success the
          // way the old Bash script's exit code did.
          final outcomes = await restorer.run(
            trashRoot: trashRoot.path,
            confirm: true,
          );

          expect(outcomes, hasLength(1));
          expect(outcomes.single.action, RestoreAction.restored);
        },
      );

      test(
        'a fully successful dry-run-equivalent run (nothing to restore) '
        'also completes normally, not as an error',
        () async {
          final trashRoot = Directory('${tempDir.path}/empty_trash');
          await trashRoot.create(recursive: true);

          const restorer = TrashRestorer();
          final outcomes = await restorer.run(trashRoot: trashRoot.path);

          expect(outcomes, isEmpty);
        },
      );
    },
  );

  group('cross-device rename fallback: copyVerifyAndReplace', () {
    // TrashRestorer._moveFile tries File.rename first (matching `mv -n`'s
    // fast path) and, only on a cross-device/cross-filesystem failure
    // (EXDEV, errno 18 — detected via FileSystemException.osError.errorCode
    // or a "cross-device" message fallback), falls back to
    // copyVerifyAndReplace(): copy + verify + delete, mirroring what real
    // `mv` does transparently across filesystems.
    //
    // Reproducing a genuine EXDEV to reach this fallback via _moveFile
    // itself would require two distinct mounted filesystems/devices, which
    // isn't available in this sandbox or in CI — that specific trigger
    // remains a documented gap (see the last test in this group). But the
    // fallback body itself (copyVerifyAndReplace) is exposed directly and
    // takes an injectable [FileCopier], so its actual copy/verify/cleanup
    // logic — including the failure-cleanup path Cody flagged on PR #82,
    // where a corrupt/partial destination must never be left stranded to
    // silently mask a still-good file sitting safely in trash — is fully
    // exercised here without needing EXDEV at all.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'restore_from_trash_test_',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'happy path: copies, verifies, then deletes the original',
      () async {
        final src = File('${tempDir.path}/src.jpg');
        final dst = File('${tempDir.path}/dst.jpg');
        await src.writeAsString('original-bytes');

        const restorer = TrashRestorer();
        await restorer.copyVerifyAndReplace(src.path, dst.path);

        expect(await src.exists(), isFalse);
        expect(await dst.exists(), isTrue);
        expect(await dst.readAsString(), 'original-bytes');
      },
    );

    test(
      'verification-failure cleanup: a corrupt/truncated copy is deleted '
      'before the failure propagates, never left stranded to mask the '
      'still-good original (Cody review finding on PR #82)',
      () async {
        final src = File('${tempDir.path}/src.jpg');
        final dst = File('${tempDir.path}/dst.jpg');
        await src.writeAsString('original-bytes-longer-than-truncated');

        // Simulate a copy that lands a truncated/corrupt destination file
        // rather than throwing outright — the case a real interrupted
        // cross-device copy could produce.
        final restorer = TrashRestorer(
          copier: (srcPath, dstPath) async {
            await File(dstPath).writeAsString('truncated');
          },
        );

        await expectLater(
          restorer.copyVerifyAndReplace(src.path, dst.path),
          throwsA(isA<FileSystemException>()),
        );

        // The corrupt partial destination must be gone, not stranded...
        expect(await dst.exists(), isFalse);
        // ...and the original must still be safely intact in the trash,
        // since it's only ever deleted after verification succeeds.
        expect(await src.exists(), isTrue);
        expect(
          await src.readAsString(),
          'original-bytes-longer-than-truncated',
        );
      },
    );

    test(
      'copier-throws cleanup: if the copier itself throws after partially '
      'writing dst, the partial file is still cleaned up',
      () async {
        final src = File('${tempDir.path}/src.jpg');
        final dst = File('${tempDir.path}/dst.jpg');
        await src.writeAsString('original-bytes');

        final restorer = TrashRestorer(
          copier: (srcPath, dstPath) async {
            // Simulate a copy that writes a partial file, then fails
            // outright (e.g. a real disk-full or I/O error mid-copy).
            await File(dstPath).writeAsString('partial');
            throw const FileSystemException('simulated mid-copy I/O error');
          },
        );

        await expectLater(
          restorer.copyVerifyAndReplace(src.path, dst.path),
          throwsA(isA<FileSystemException>()),
        );

        expect(await dst.exists(), isFalse);
        expect(await src.exists(), isTrue);
        expect(await src.readAsString(), 'original-bytes');
      },
    );

    test(
      'no partial destination to clean up: verification failure when the '
      'copier never created dst at all does not throw a secondary error',
      () async {
        final src = File('${tempDir.path}/src.jpg');
        final dst = File('${tempDir.path}/dst.jpg');
        await src.writeAsString('original-bytes');

        final restorer = TrashRestorer(
          copier: (srcPath, dstPath) async {
            // Copier reports success without actually writing anything —
            // an extreme edge case, but must not crash the cleanup step
            // (which only deletes dst if it actually exists).
          },
        );

        await expectLater(
          restorer.copyVerifyAndReplace(src.path, dst.path),
          throwsA(isA<FileSystemException>()),
        );

        expect(await dst.exists(), isFalse);
        expect(await src.exists(), isTrue);
      },
    );

    test(
      'documented gap: reaching this fallback via a genuine EXDEV rename '
      'failure (rather than calling copyVerifyAndReplace directly, as the '
      'tests above do) requires two real mounted filesystems, not '
      'exercisable via a single temp directory — flagging for reviewer '
      'awareness (Cody/Astrid) rather than claiming coverage that '
      "doesn't exist",
      () {
        expect(true, isTrue);
      },
    );
  });
}

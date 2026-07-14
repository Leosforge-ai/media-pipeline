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

    test('a bare filename equal to the trash root (no trailing content) is '
        'rejected, not silently reconstructed to "/"', () {
      expect(
        () => reconstructOriginalPath(
          trashRoot: '/mnt/media_trash',
          trashedFilePath: '/mnt/media_trash',
        ),
        throwsA(isA<NotUnderTrashRootException>()),
      );
    });
  });

  // `parentDirectory` (dirname port) tests now live in
  // filesystem_ops_test.dart, alongside the shared primitive that owns
  // that logic; `parentDirectory` itself is re-exported from this file's
  // `restore_from_trash.dart` for callers that still import it from here.

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

    test('no-clobber: an existing destination file is left alone, not '
        'overwritten, matching `mv -n`', () async {
      final trashRoot = Directory('${tempDir.path}/media_trash');
      final originalDir = Directory('${tempDir.path}/existing_target');
      await originalDir.create(recursive: true);

      final existingDestination = File('${originalDir.path}/photo.jpg');
      await existingDestination.writeAsString('existing-original-bytes');

      final trashedFile = File('${trashRoot.path}${existingDestination.path}');
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
      expect(await trashedFile.readAsString(), 'trashed-duplicate-bytes');
    });

    test(r'round-trip: a file trashed under the $MEDIA_TRASH/<full-original-'
        'absolute-path> convention (matching scripts 06/12/13) restores to '
        'exactly its original path', () async {
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
    });

    test('restores multiple nested files, creating destination directories '
        'as needed', () async {
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
    });
  });

  group('success/failure signaling has no PR #61/#63-equivalent footgun', () {
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

    test('a fully successful dry-run-equivalent run (nothing to restore) '
        'also completes normally, not as an error', () async {
      final trashRoot = Directory('${tempDir.path}/empty_trash');
      await trashRoot.create(recursive: true);

      const restorer = TrashRestorer();
      final outcomes = await restorer.run(trashRoot: trashRoot.path);

      expect(outcomes, isEmpty);
    });
  });
}

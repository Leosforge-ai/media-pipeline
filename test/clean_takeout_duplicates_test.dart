import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/clean_takeout_duplicates.dart';
import 'package:media_pipeline_app/src/tools_container.dart';

/// True only if a real Docker daemon is reachable from this machine.
/// Mirrors `test/tools_container_test.dart`'s own `_dockerAvailable`
/// exactly (duplicated here rather than shared, since test files in this
/// repo don't import each other — matching
/// `test/dedupe_live_photos_test.dart`'s own precedent of mirroring, not
/// reusing, that helper).
bool _dockerAvailable() {
  try {
    final result = Process.runSync('docker', [
      'version',
      '--format',
      '{{.Server.Version}}',
    ]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// True only if the `media-pipeline-tools:local` image is already built
/// locally, per `docker/tools/README.md`. Mirrors
/// `test/tools_container_test.dart`'s own `_toolsImageAvailable`.
bool _toolsImageAvailable() {
  try {
    final result = Process.runSync('docker', [
      'image',
      'inspect',
      kDefaultToolsImage,
    ]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

final bool _dockerReady = _dockerAvailable();
final bool _imageReady = _dockerReady && _toolsImageAvailable();

/// Finds the repo root by walking up from this test file's directory until
/// `scripts/12_clean_immich_takeout_duplicates.sh` is found. Mirrors the
/// `ROOT = Path(__file__).resolve().parents[1]` convention
/// `tests/test_shell_scripts.py` uses for the same script, and the
/// `_findRepoRoot` helper `test/delete_duplicates_test.dart` already uses
/// for `06_delete_duplicates.sh`, so the Bash-vs-Dart parity test below runs
/// the exact same file the Python suite already covers.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(
      '${dir.path}/scripts/12_clean_immich_takeout_duplicates.sh',
    ).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current}');
}

void main() {
  group('matchLocalizedYearFolderName', () {
    test('matches "Fotos de YYYY" and extracts the year', () {
      expect(matchLocalizedYearFolderName('Fotos de 2024'), '2024');
    });

    test('returns null for the canonical "YYYY" folder name itself', () {
      expect(matchLocalizedYearFolderName('2024'), isNull);
    });

    test('returns null for an unrelated folder name', () {
      expect(matchLocalizedYearFolderName('Albums'), isNull);
    });

    test('returns null for a non-4-digit year', () {
      expect(matchLocalizedYearFolderName('Fotos de 24'), isNull);
      expect(matchLocalizedYearFolderName('Fotos de 20245'), isNull);
    });

    test('requires an exact match, not just a prefix/substring', () {
      expect(matchLocalizedYearFolderName('Fotos de 2024 extra'), isNull);
      expect(matchLocalizedYearFolderName('prefix Fotos de 2024'), isNull);
    });

    test('is case-sensitive, matching the Bash regex exactly', () {
      expect(matchLocalizedYearFolderName('fotos de 2024'), isNull);
      expect(matchLocalizedYearFolderName('FOTOS DE 2024'), isNull);
    });
  });

  group('confirmation phrase', () {
    test('kTakeoutDuplicatesConfirmPhrase matches the Bash CONFIRM_PHRASE', () {
      expect(kTakeoutDuplicatesConfirmPhrase, 'MOVE TAKEOUT DUPLICATES');
    });

    test('exact phrase is valid', () {
      expect(
        isTakeoutDuplicatesConfirmationPhraseValid('MOVE TAKEOUT DUPLICATES'),
        isTrue,
      );
    });

    test('anything else is invalid (wrong case, trailing space, partial)', () {
      expect(
        isTakeoutDuplicatesConfirmationPhraseValid('move takeout duplicates'),
        isFalse,
      );
      expect(
        isTakeoutDuplicatesConfirmationPhraseValid('MOVE TAKEOUT DUPLICATES '),
        isFalse,
      );
      expect(
        isTakeoutDuplicatesConfirmationPhraseValid('MOVE TAKEOUT'),
        isFalse,
      );
      expect(isTakeoutDuplicatesConfirmationPhraseValid(''), isFalse);
    });
  });

  group('verifyTakeoutDuplicateCandidate (inspect_candidate port)', () {
    test('missingCanonical when no canonical file exists', () async {
      final result = await verifyTakeoutDuplicateCandidate(
        duplicatePath: '/lib/Fotos de 2024/a.jpg',
        canonicalPath: '/lib/2024/a.jpg',
        exists: (path) async => false,
        sizer: (path) async => fail('sizer should not be called'),
        hasher: (path) async => fail('hasher should not be called'),
      );
      expect(result, TakeoutDuplicateVerification.missingCanonical);
    });

    test('sizeMismatch when sizes differ, without ever hashing', () async {
      var hasherCalled = false;
      final result = await verifyTakeoutDuplicateCandidate(
        duplicatePath: '/lib/Fotos de 2024/a.jpg',
        canonicalPath: '/lib/2024/a.jpg',
        exists: (path) async => true,
        sizer: (path) async => path.contains('Fotos de') ? 100 : 200,
        hasher: (path) async {
          hasherCalled = true;
          return 'irrelevant';
        },
      );
      expect(result, TakeoutDuplicateVerification.sizeMismatch);
      expect(
        hasherCalled,
        isFalse,
        reason:
            'a size mismatch must short-circuit before hashing, matching '
            "the Bash script's cheaper-check-first order",
      );
    });

    test('hashMismatch when sizes match but hashes differ', () async {
      final result = await verifyTakeoutDuplicateCandidate(
        duplicatePath: '/lib/Fotos de 2024/a.jpg',
        canonicalPath: '/lib/2024/a.jpg',
        exists: (path) async => true,
        sizer: (path) async => 100,
        hasher: (path) async => path.contains('Fotos de') ? 'hashA' : 'hashB',
      );
      expect(result, TakeoutDuplicateVerification.hashMismatch);
    });

    test('verified only when basename, size, AND hash all agree', () async {
      final result = await verifyTakeoutDuplicateCandidate(
        duplicatePath: '/lib/Fotos de 2024/a.jpg',
        canonicalPath: '/lib/2024/a.jpg',
        exists: (path) async => true,
        sizer: (path) async => 100,
        hasher: (path) async => 'same-hash',
      );
      expect(result, TakeoutDuplicateVerification.verified);
    });

    test(
      'a size-only match (no hash check) must never be reported as '
      'verified — this test fails if the three-way check is ever weakened',
      () async {
        final result = await verifyTakeoutDuplicateCandidate(
          duplicatePath: '/lib/Fotos de 2024/a.jpg',
          canonicalPath: '/lib/2024/a.jpg',
          exists: (path) async => true,
          sizer: (path) async => 100,
          hasher: (path) async =>
              path.contains('Fotos de') ? 'hash-of-different-bytes' : 'hash-B',
        );
        expect(result, isNot(TakeoutDuplicateVerification.verified));
        expect(result, TakeoutDuplicateVerification.hashMismatch);
      },
    );
  });

  group('trashDestinationPath', () {
    test("mirrors move_or_report_duplicate's rel/dst convention", () {
      expect(
        trashDestinationPath(
          trashRoot: '/mnt/target_drive/media_trash',
          originalPath:
              '/mnt/target_drive/immich_library/Takeout/Google Fotos/'
              'Fotos de 2024/a.jpg',
        ),
        '/mnt/target_drive/media_trash/mnt/target_drive/immich_library/'
        'Takeout/Google Fotos/Fotos de 2024/a.jpg',
      );
    });

    test('accepts a trash root with a trailing slash identically', () {
      final withSlash = trashDestinationPath(
        trashRoot: '/mnt/media_trash/',
        originalPath: '/a/b.jpg',
      );
      final withoutSlash = trashDestinationPath(
        trashRoot: '/mnt/media_trash',
        originalPath: '/a/b.jpg',
      );
      expect(withSlash, withoutSlash);
    });
  });

  group('TakeoutDuplicateCleaner.run (async orchestration)', () {
    late Directory tempDir;
    late String googleFotosDir;
    late String trashRoot;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'clean_takeout_duplicates_test_',
      );
      googleFotosDir = '${tempDir.path}/immich_library/Takeout/Google Fotos';
      trashRoot = '${tempDir.path}/media_trash';
      await Directory(googleFotosDir).create(recursive: true);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'missing Google Fotos directory returns an all-zero summary',
      () async {
        final cleaner = TakeoutDuplicateCleaner(
          trashRoot: trashRoot,
          hasher: defaultFileHasher,
        );
        final summary = await cleaner.run(
          googleFotosDir: '${tempDir.path}/does/not/exist',
        );
        expect(summary.inspected, 0);
        expect(summary.verified, 0);
        expect(summary.yearFolders, isEmpty);
      },
    );

    test('dry run reports wouldMove for a verified duplicate and touches '
        'nothing on disk', () async {
      final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
      final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
      await canonical.parent.create(recursive: true);
      await duplicate.parent.create(recursive: true);
      await canonical.writeAsBytes('same-bytes'.codeUnits);
      await duplicate.writeAsBytes('same-bytes'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(googleFotosDir: googleFotosDir);

      expect(summary.inspected, 1);
      expect(summary.verified, 1);
      expect(summary.skippedSize, 0);
      expect(summary.skippedHash, 0);
      expect(summary.skippedMissingCanonicalFile, 0);

      final outcome = summary.yearFolders.single.candidates.single;
      expect(outcome.action, TakeoutDuplicateAction.wouldMove);
      expect(outcome.duplicatePath, duplicate.path);
      expect(outcome.canonicalPath, canonical.path);
      expect(await canonical.exists(), isTrue);
      expect(await duplicate.exists(), isTrue);
    });

    test('confirm mode moves a verified duplicate to media_trash via '
        'SafeFileMover, keeping the canonical file untouched', () async {
      final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
      final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
      await canonical.parent.create(recursive: true);
      await duplicate.parent.create(recursive: true);
      await canonical.writeAsBytes('same-bytes'.codeUnits);
      await duplicate.writeAsBytes('same-bytes'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(
        googleFotosDir: googleFotosDir,
        confirm: true,
      );

      final outcome = summary.yearFolders.single.candidates.single;
      expect(outcome.action, TakeoutDuplicateAction.moved);
      expect(await canonical.exists(), isTrue, reason: 'canonical survives');
      expect(await duplicate.exists(), isFalse, reason: 'duplicate moved');
      expect(await File(outcome.destinationPath!).exists(), isTrue);
      expect(
        await File(outcome.destinationPath!).readAsBytes(),
        'same-bytes'.codeUnits,
      );
    });

    test(
      'a size mismatch is skipped and never moved, even in confirm mode',
      () async {
        final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
        final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
        await canonical.parent.create(recursive: true);
        await duplicate.parent.create(recursive: true);
        await canonical.writeAsBytes('short'.codeUnits);
        await duplicate.writeAsBytes('a much longer duplicate'.codeUnits);

        final cleaner = TakeoutDuplicateCleaner(
          trashRoot: trashRoot,
          hasher: defaultFileHasher,
        );
        final summary = await cleaner.run(
          googleFotosDir: googleFotosDir,
          confirm: true,
        );

        expect(summary.skippedSize, 1);
        expect(summary.verified, 0);
        final outcome = summary.yearFolders.single.candidates.single;
        expect(outcome.action, TakeoutDuplicateAction.sizeMismatch);
        expect(await duplicate.exists(), isTrue, reason: 'never moved');
      },
    );

    test('a hash mismatch despite matching size is skipped and never moved — '
        'proves the three-way check is not weakened to size-only', () async {
      final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
      final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
      await canonical.parent.create(recursive: true);
      await duplicate.parent.create(recursive: true);
      // Same length (10 bytes), different content -> same size, different
      // hash.
      await canonical.writeAsBytes('AAAAAAAAAA'.codeUnits);
      await duplicate.writeAsBytes('BBBBBBBBBB'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(
        googleFotosDir: googleFotosDir,
        confirm: true,
      );

      expect(summary.skippedHash, 1);
      expect(summary.verified, 0);
      final outcome = summary.yearFolders.single.candidates.single;
      expect(outcome.action, TakeoutDuplicateAction.hashMismatch);
      expect(await duplicate.exists(), isTrue, reason: 'never moved');
    });

    test('a duplicate with no matching canonical file is reported missing, '
        'not moved', () async {
      await Directory('$googleFotosDir/2024').create(recursive: true);
      final duplicate = File('$googleFotosDir/Fotos de 2024/orphan.jpg');
      await duplicate.parent.create(recursive: true);
      await duplicate.writeAsBytes('orphan'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(
        googleFotosDir: googleFotosDir,
        confirm: true,
      );

      expect(summary.skippedMissingCanonicalFile, 1);
      final outcome = summary.yearFolders.single.candidates.single;
      expect(outcome.action, TakeoutDuplicateAction.missingCanonical);
      expect(await duplicate.exists(), isTrue, reason: 'never moved');
    });

    test('a "Fotos de YYYY" folder with no matching "YYYY" canonical folder is '
        'reported and its files are never inspected', () async {
      final duplicate = File('$googleFotosDir/Fotos de 2030/orphan_year.jpg');
      await duplicate.parent.create(recursive: true);
      await duplicate.writeAsBytes('orphan-year'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(googleFotosDir: googleFotosDir);

      expect(summary.missingCanonicalYearFolders, ['2030']);
      expect(summary.inspected, 0);
      expect(summary.yearFolders.single.canonicalDirFound, isFalse);
      expect(summary.yearFolders.single.candidates, isEmpty);
    });

    test('a differently-named folder (not "Fotos de YYYY") is ignored '
        'entirely', () async {
      final other = File('$googleFotosDir/Albums/whatever.jpg');
      await other.parent.create(recursive: true);
      await other.writeAsBytes('whatever'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(googleFotosDir: googleFotosDir);

      expect(summary.yearFolders, isEmpty);
      expect(summary.inspected, 0);
      expect(await other.exists(), isTrue);
    });

    test('confirm mode never leaves a verified duplicate un-moved on '
        "collision: a numbered suffix is used instead, matching Bash's "
        'unique_destination()', () async {
      final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
      final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
      await canonical.parent.create(recursive: true);
      await duplicate.parent.create(recursive: true);
      await canonical.writeAsBytes('same-bytes'.codeUnits);
      await duplicate.writeAsBytes('same-bytes'.codeUnits);

      final dst = trashDestinationPath(
        trashRoot: trashRoot,
        originalPath: duplicate.path,
      );
      await Directory(
        dst.substring(0, dst.lastIndexOf('/')),
      ).create(recursive: true);
      await File(dst).writeAsBytes('already-there'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(
        googleFotosDir: googleFotosDir,
        confirm: true,
      );

      final outcome = summary.yearFolders.single.candidates.single;
      expect(outcome.action, TakeoutDuplicateAction.movedWithSuffix);
      // The suffixed destination is `<dst-without-ext>_1<ext>`.
      final expectedSuffixedDst =
          '${dst.substring(0, dst.length - 5)}_1'
          '${dst.substring(dst.length - 5)}';
      expect(outcome.destinationPath, expectedSuffixedDst);
      expect(
        await duplicate.exists(),
        isFalse,
        reason:
            'source is always moved, never left in place, matching '
            "Bash's guarantee that a move into the trash always succeeds",
      );
      expect(await File(dst).readAsBytes(), 'already-there'.codeUnits);
      expect(
        await File(expectedSuffixedDst).readAsBytes(),
        'same-bytes'.codeUnits,
      );
    });

    test('preserves paths with spaces and unicode characters', () async {
      final canonical = File('$googleFotosDir/2024/日本語 写真 vacaciones.jpg');
      final duplicate = File(
        '$googleFotosDir/Fotos de 2024/日本語 写真 vacaciones.jpg',
      );
      await canonical.parent.create(recursive: true);
      await duplicate.parent.create(recursive: true);
      await canonical.writeAsBytes('same-bytes'.codeUnits);
      await duplicate.writeAsBytes('same-bytes'.codeUnits);

      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(
        googleFotosDir: googleFotosDir,
        confirm: true,
      );

      final outcome = summary.yearFolders.single.candidates.single;
      expect(outcome.action, TakeoutDuplicateAction.moved);
      expect(await duplicate.exists(), isFalse);
      expect(await File(outcome.destinationPath!).exists(), isTrue);
    });
  });

  group('Bash-vs-Dart parity: TakeoutDuplicateCleaner matches '
      "12_clean_immich_takeout_duplicates.sh's real dry-run decisions", () {
    test('identical verified/skipped decisions for the same synthetic '
        'fixture, including a size-mismatch and a '
        'hash-mismatch-despite-matching-size case', () async {
      final repoRoot = _findRepoRoot();
      final tempDir = await Directory.systemTemp.createTemp(
        'clean_takeout_duplicates_parity_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final googleFotosPath =
          '${tempDir.path}/immich_library/Takeout/Google Fotos';
      final reportsPath = '${tempDir.path}/reports';
      await Directory(googleFotosPath).create(recursive: true);
      await Directory(reportsPath).create(recursive: true);

      // Case 1: a genuine verified duplicate (same basename, size, and
      // hash).
      final canonical2024 = File('$googleFotosPath/2024/IMG_1951.HEIC');
      final duplicate2024 = File(
        '$googleFotosPath/Fotos de 2024/IMG_1951.HEIC',
      );

      // Case 2: a size mismatch — same basename, different size. Must
      // be skipped by both implementations without ever comparing
      // hashes.
      final canonical2025 = File('$googleFotosPath/2025/IMG_2000.HEIC');
      final duplicate2025 = File(
        '$googleFotosPath/Fotos de 2025/IMG_2000.HEIC',
      );

      // Case 3: a hash mismatch DESPITE matching size — the adversarial
      // case that proves the three-way check isn't weakened to
      // size-only.
      final canonical2026 = File('$googleFotosPath/2026/IMG_3000.HEIC');
      final duplicate2026 = File(
        '$googleFotosPath/Fotos de 2026/IMG_3000.HEIC',
      );

      // Case 4: no canonical file for this basename at all (canonical
      // year folder exists, but doesn't contain this file).
      final duplicate2028 = File(
        '$googleFotosPath/Fotos de 2028/IMG_5000.HEIC',
      );

      for (final f in [
        canonical2024,
        duplicate2024,
        canonical2025,
        duplicate2025,
        canonical2026,
        duplicate2026,
        duplicate2028,
      ]) {
        await f.parent.create(recursive: true);
      }
      await Directory('$googleFotosPath/2028').create(recursive: true);

      await canonical2024.writeAsBytes('same-photo-bytes'.codeUnits);
      await duplicate2024.writeAsBytes('same-photo-bytes'.codeUnits);

      await canonical2025.writeAsBytes('short'.codeUnits);
      await duplicate2025.writeAsBytes(
        'a much longer duplicate payload'.codeUnits,
      );

      await canonical2026.writeAsBytes('AAAAAAAAAA'.codeUnits);
      await duplicate2026.writeAsBytes('BBBBBBBBBB'.codeUnits);

      await duplicate2028.writeAsBytes('orphan'.codeUnits);

      // Run the real Bash script in dry-run mode against this fixture.
      final result = await Process.run(
        'bash',
        ['${repoRoot.path}/scripts/12_clean_immich_takeout_duplicates.sh'],
        environment: {
          ...Platform.environment,
          'HD_PATH': tempDir.path,
          'REPORT_DIR': reportsPath,
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final bashStdout = result.stdout as String;

      expect(
        bashStdout,
        contains('Would move duplicate: ${duplicate2024.path}'),
      );
      expect(bashStdout, contains('Kept canonical: ${canonical2024.path}'));
      expect(
        bashStdout,
        contains('Size mismatch, skipping: ${duplicate2025.path}'),
      );
      expect(
        bashStdout,
        contains('Hash mismatch, skipping: ${duplicate2026.path}'),
      );
      expect(
        bashStdout,
        contains('Missing canonical for 2028: ${duplicate2028.path}'),
      );
      expect(bashStdout, contains('Candidates inspected: 4'));
      expect(bashStdout, contains('Verified duplicates:  1'));

      // Independently compute the Dart port's decision for the exact
      // same fixture, using defaultFileHasher (host Process.run against
      // a real sha256sum binary) rather than containerFileHasher.
      //
      // Unlike dedupe_live_photos_test.dart's ffprobe parity test (which
      // had to swap in a Dart-native marker-file fake because ffprobe's
      // real *decision logic* — the numeric-duration regex, the
      // duration-then-timestamp priority order — lives partly in how
      // its raw stdout gets parsed), this parity test needs no such
      // fake. sha256sum's only job here is producing a real content
      // hash of real bytes, and defaultFileHasher already does exactly
      // that via a real (host) sha256sum binary — the same real
      // `sha256sum` binary the Bash script itself shells out to. The
      // only thing this migration changed is *where* sha256sum runs
      // (host process vs. container exec), not what it computes; using
      // defaultFileHasher here keeps this test decoupled from that
      // "where" question entirely (no Docker required to run this
      // parity comparison) while still exercising a genuine SHA-256
      // computation on genuine file bytes — the case this test actually
      // needs to prove parity for (see the adversarial
      // hash-mismatch-despite-matching-size fixture below). The
      // container-exec *mechanism* itself is covered separately, for
      // real, by the Docker-gated group in this file (see
      // "sha256sum via a real ToolsContainer").
      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: '${tempDir.path}/media_trash',
        hasher: defaultFileHasher,
      );
      final summary = await cleaner.run(googleFotosDir: googleFotosPath);

      expect(summary.inspected, 4);
      expect(summary.verified, 1);
      expect(summary.skippedSize, 1);
      expect(summary.skippedHash, 1);
      expect(summary.skippedMissingCanonicalFile, 1);

      final allCandidates = summary.yearFolders.expand((y) => y.candidates);

      final verifiedOutcome = allCandidates.firstWhere(
        (c) => c.duplicatePath == duplicate2024.path,
      );
      expect(verifiedOutcome.action, TakeoutDuplicateAction.wouldMove);

      final sizeMismatchOutcome = allCandidates.firstWhere(
        (c) => c.duplicatePath == duplicate2025.path,
      );
      expect(sizeMismatchOutcome.action, TakeoutDuplicateAction.sizeMismatch);

      final hashMismatchOutcome = allCandidates.firstWhere(
        (c) => c.duplicatePath == duplicate2026.path,
      );
      expect(hashMismatchOutcome.action, TakeoutDuplicateAction.hashMismatch);

      final missingCanonicalOutcome = allCandidates.firstWhere(
        (c) => c.duplicatePath == duplicate2028.path,
      );
      expect(
        missingCanonicalOutcome.action,
        TakeoutDuplicateAction.missingCanonical,
      );
    }, skip: !Platform.isLinux && !Platform.isMacOS);
  });

  group('sha256sum via a real ToolsContainer (requires Docker + the '
      'media-pipeline-tools:local image built per docker/tools/README.md)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'clean_takeout_duplicates_container_test_',
      );
      // The `media-pipeline-tools` image runs as a fixed non-root UID
      // (`tools`, uid 10000 — see docker/tools/Dockerfile), which will not
      // generally match this test's own host UID. Real UID/GID mapping
      // for bind-mounted writes is Phase 3 of issue #76 (not yet
      // implemented); until then, this test-only fixture directory is
      // made world-writable so the container can read the fixture files
      // this test writes into it. This does not touch or work around
      // anything in `lib/`/`docker/` — it's scoped to this temp test
      // fixture only. Mirrors
      // `test/dedupe_live_photos_test.dart`'s identical workaround.
      await Process.run('chmod', ['0777', tempDir.path]);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'containerFileHasher hashes a real file through the full path: '
      'host path -> container path translation -> real sha256sum exec '
      'inside the pinned tools image -> hash returned, and it matches a '
      'host-side sha256sum computed independently for the same bytes',
      () async {
        final content = 'takeout-duplicate-verification-fixture-bytes';
        final hostFilePath = '${tempDir.path}/candidate.jpg';
        await File(hostFilePath).writeAsString(content);
        // chmod after write so the container (running as a different
        // UID) can still read it, matching this group's setUp comment.
        await Process.run('chmod', ['0666', hostFilePath]);

        // Independently compute the expected hash via a real host-side
        // sha256sum (defaultFileHasher) — a cross-check computed by a
        // completely separate invocation of the same real binary,
        // proving containerFileHasher's result isn't just "whatever the
        // container happened to return" but the actual, correct SHA-256
        // of the file's real bytes.
        final expectedHash = await defaultFileHasher(hostFilePath);
        expect(
          expectedHash,
          matches(RegExp(r'^[0-9a-f]{64}$')),
          reason:
              'sanity check: a SHA-256 hex digest is 64 lowercase '
              'hex characters',
        );

        final container = ToolsContainer(hostMountRoot: tempDir.path);
        await container.start();
        try {
          final reader = containerFileHasher(container: container);
          // Pass the HOST path — exactly how
          // TakeoutDuplicateCleaner._processCandidate calls hasher with
          // paths from its directory walk. containerFileHasher is
          // responsible for translating it internally via
          // ToolsContainer.hostToContainerPath.
          final containerHash = await reader(hostFilePath);

          expect(containerHash, expectedHash);
        } finally {
          await container.stop();
        }
      },
      skip: _imageReady
          ? false
          : 'Docker or the media-pipeline-tools:local image is not '
                'available in this environment (build it per '
                'docker/tools/README.md).',
    );

    test(
      'containerFileHasher throws FileSystemException (never silently '
      'returns a bogus hash) when the given path does not exist inside '
      'the container',
      () async {
        final container = ToolsContainer(hostMountRoot: tempDir.path);
        await container.start();
        try {
          final missingHostPath = '${tempDir.path}/does_not_exist.jpg';
          final reader = containerFileHasher(container: container);
          await expectLater(
            reader(missingHostPath),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          await container.stop();
        }
      },
      skip: _imageReady
          ? false
          : 'Docker or the media-pipeline-tools:local image is not '
                'available in this environment.',
    );

    test(
      'TakeoutDuplicateCleaner using containerFileHasher end-to-end: a '
      'genuine duplicate (matching basename+size+hash, verified via real '
      'sha256sum exec through the container) is correctly reported as '
      'wouldMove',
      () async {
        final googleFotosDir =
            '${tempDir.path}/immich_library/Takeout/Google Fotos';
        final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
        final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
        await canonical.parent.create(recursive: true);
        await duplicate.parent.create(recursive: true);
        await canonical.writeAsBytes('same-bytes-via-container'.codeUnits);
        await duplicate.writeAsBytes('same-bytes-via-container'.codeUnits);
        // Container runs as a different UID than this test process — see
        // this group's setUp comment.
        await Process.run('chmod', ['-R', '0666', canonical.path]);
        await Process.run('chmod', ['-R', '0666', duplicate.path]);

        final container = ToolsContainer(hostMountRoot: tempDir.path);
        await container.start();
        try {
          final cleaner = TakeoutDuplicateCleaner(
            trashRoot: '${tempDir.path}/media_trash',
            hasher: containerFileHasher(container: container),
          );
          final summary = await cleaner.run(googleFotosDir: googleFotosDir);

          expect(summary.inspected, 1);
          expect(summary.verified, 1);
          final outcome = summary.yearFolders.single.candidates.single;
          expect(outcome.action, TakeoutDuplicateAction.wouldMove);
        } finally {
          await container.stop();
        }
      },
      skip: _imageReady
          ? false
          : 'Docker or the media-pipeline-tools:local image is not '
                'available in this environment.',
    );
  });

  group('Docker/image availability self-check (meta-test)', () {
    test('this test file is actually exercising real Docker, not silently '
        'skipping — makes the skip reason visible in test output', () {
      if (!_dockerReady) {
        // ignore: avoid_print
        print(
          'NOTE: Docker daemon not reachable — the "sha256sum via a real '
          'ToolsContainer" group above was skipped, not run.',
        );
      } else if (!_imageReady) {
        // ignore: avoid_print
        print(
          'NOTE: Docker is available but media-pipeline-tools:local is '
          'not built — the "sha256sum via a real ToolsContainer" group '
          'above was skipped, not run. Build it per '
          'docker/tools/README.md.',
        );
      } else {
        // ignore: avoid_print
        print(
          'Docker + media-pipeline-tools:local are both available — the '
          '"sha256sum via a real ToolsContainer" group above actually ran '
          'against a real container.',
        );
      }
    });
  });
}

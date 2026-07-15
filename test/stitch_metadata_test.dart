import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/stitch_metadata.dart';

/// Finds the repo root by walking up from this test file's directory until
/// `scripts/04_stitch_metadata.py` is found. Mirrors the same
/// `_findRepoRoot` convention `test/dedupe_live_photos_test.dart` and
/// `tests/test_stitch_metadata.py`'s own `ROOT` use, so the Bash^H^H
/// Python-vs-Dart parity test below runs the exact same file the Python
/// suite already covers.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/scripts/04_stitch_metadata.py').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current}');
}

/// Writes a fake `exiftool` stand-in. `04_stitch_metadata.py` hard-codes
/// the literal command name `exiftool` (unlike the Bash scripts' own
/// `FFPROBE_BIN`-style env-var overrides), so the parity test below invokes
/// the real Python script with this fake binary's directory prepended onto
/// `PATH` instead. Protocol: reads the target media file (the invocation's
/// last argument) and inspects its first line — `FAIL_EXIFTOOL` makes the
/// fake exit non-zero (simulating exiftool being unable to write metadata
/// to a corrupt file), anything else exits `0`.
Future<File> _writeFakeExiftool(Directory root) async {
  final fake = File('${root.path}/fake_exiftool.sh');
  await fake.writeAsString('''
#!/usr/bin/env bash
file="\${@: -1}"
first_line="\$(head -n1 "\$file" 2>/dev/null || true)"
if [[ "\$first_line" == "FAIL_EXIFTOOL" ]]; then
  echo "fake exiftool: simulated corrupt file" >&2
  exit 1
fi
exit 0
''');
  final result = await Process.run('chmod', ['0755', fake.path]);
  expect(result.exitCode, 0);
  return fake;
}

void main() {
  group('archiveStem', () {
    test('strips .tar.gz', () {
      expect(archiveStem('takeout-20240101.tar.gz'), 'takeout-20240101');
    });
    test('strips .tgz', () {
      expect(archiveStem('takeout-20240101.tgz'), 'takeout-20240101');
    });
    test('strips .zip', () {
      expect(archiveStem('takeout-20240101-001.zip'), 'takeout-20240101-001');
    });
    test('is case-insensitive on the suffix', () {
      expect(archiveStem('Takeout.ZIP'), 'Takeout');
    });
    test('falls back to stripping a single extension for unknown suffixes', () {
      expect(archiveStem('archive.rar'), 'archive');
    });
  });

  group('isMediaExtension', () {
    test('matches known media extensions case-insensitively', () {
      expect(isMediaExtension('/a/b/IMG_1.JPG'), isTrue);
      expect(isMediaExtension('/a/b/img_2.heic'), isTrue);
      expect(isMediaExtension('/a/b/clip.MOV'), isTrue);
    });
    test('rejects non-media extensions', () {
      expect(isMediaExtension('/a/b/sidecar.json'), isFalse);
      expect(isMediaExtension('/a/b/readme.txt'), isFalse);
    });
  });

  group('isSupportedArchiveFileName', () {
    test('matches the three supported suffixes case-sensitively', () {
      expect(isSupportedArchiveFileName('takeout.zip'), isTrue);
      expect(isSupportedArchiveFileName('takeout.tgz'), isTrue);
      expect(isSupportedArchiveFileName('takeout.tar.gz'), isTrue);
    });
    test('does not match a different-case suffix (mirrors Path.glob)', () {
      expect(isSupportedArchiveFileName('takeout.ZIP'), isFalse);
    });
    test('does not match unsupported suffixes', () {
      expect(isSupportedArchiveFileName('takeout.rar'), isFalse);
    });
  });

  group('extractTimestamp', () {
    test('uses photoTakenTime.timestamp', () {
      expect(
        extractTimestamp({
          'photoTakenTime': {'timestamp': '0'},
        }),
        '1970:01:01 00:00:00',
      );
    });
    test('falls back to creationTime when photoTakenTime is absent', () {
      expect(
        extractTimestamp({
          'creationTime': {'timestamp': '3600'},
        }),
        '1970:01:01 01:00:00',
      );
    });
    test('prefers photoTakenTime over creationTime', () {
      expect(
        extractTimestamp({
          'photoTakenTime': {'timestamp': '0'},
          'creationTime': {'timestamp': '3600'},
        }),
        '1970:01:01 00:00:00',
      );
    });
    test('returns null for a non-numeric timestamp', () {
      expect(
        extractTimestamp({
          'photoTakenTime': {'timestamp': 'bad'},
        }),
        isNull,
      );
    });
    test('returns null when neither key is present', () {
      expect(extractTimestamp({'title': 'no time here'}), isNull);
    });
  });

  group('isPathTraversalSafe', () {
    test('allows a normal nested member path', () {
      expect(isPathTraversalSafe('/dest', 'Google Photos/IMG_1.jpg'), isTrue);
    });
    test('blocks a parent-directory escape', () {
      expect(isPathTraversalSafe('/dest', '../evil.jpg'), isFalse);
    });
    test('blocks an absolute member path', () {
      expect(isPathTraversalSafe('/dest', '/etc/passwd'), isFalse);
    });
    test('blocks a nested escape that only resolves negative after ..', () {
      expect(
        isPathTraversalSafe('/dest', 'a/../../evil.jpg'),
        isFalse,
      );
    });
    test('allows a member path with an internal .. that stays inside root', () {
      expect(
        isPathTraversalSafe('/dest', 'a/b/../c.jpg'),
        isTrue,
      );
    });
  });

  group('candidateJsonsForMedia', () {
    test(
      'includes exact, supplemental, and truncated matches in priority order',
      () async {
        final tmp = await Directory.systemTemp.createTemp(
          'stitch_candidates_',
        );
        addTearDown(() => tmp.delete(recursive: true));

        final album = Directory('${tmp.path}/album');
        await album.create();
        final mediaName =
            'IMG_20200101_abcdefghijklmnopqrstuvwxyzzzzzzzzzz.jpg';
        final media = File('${album.path}/$mediaName');
        await media.writeAsBytes('image'.codeUnits);
        final stem = mediaName.substring(0, mediaName.length - 4);

        final expected = [
          '${album.path}/$mediaName.json',
          '${album.path}/$stem.json',
          '${album.path}/$mediaName.supplemental-metadata.json',
          '${album.path}/$stem.supplemental-metadata.json',
          '${album.path}/${mediaName.substring(0, 45)}-truncated.json',
        ];
        for (final path in expected) {
          await File(path).writeAsString('{}');
        }

        final candidates = await candidateJsonsForMedia(media.path);
        expect(candidates, expected);
      },
    );

    test('returns an empty list when no sidecar exists', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_candidates_');
      addTearDown(() => tmp.delete(recursive: true));
      final media = File('${tmp.path}/photo.jpg');
      await media.writeAsBytes('image'.codeUnits);

      expect(await candidateJsonsForMedia(media.path), isEmpty);
    });
  });

  group('applyMetadataWithExiftool', () {
    test(
      'still invokes exiftool with just -overwrite_original when the JSON '
      'has no usable tags at all (matches the real Python script\'s literal '
      'len(args) == 3 check, which only skips exiftool for the '
      'exactly-one-tag case below, not the zero-tag case)',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stitch_apply_');
        addTearDown(() => tmp.delete(recursive: true));
        final json = File('${tmp.path}/sidecar.json');
        await json.writeAsString(jsonEncode({}));
        final media = File('${tmp.path}/photo.jpg');
        await media.writeAsBytes('img'.codeUnits);

        List<String>? capturedArgs;
        final ok = await applyMetadataWithExiftool(
          media.path,
          json.path,
          runner: (args) async {
            capturedArgs = args;
            return (0, '', '');
          },
          warn: (_) async {},
        );

        expect(ok, isTrue);
        expect(capturedArgs, ['-overwrite_original', media.path]);
      },
    );

    test(
      'preserves the exact len(args)==3 quirk: a title-only sidecar is '
      'treated as having no useful tags and exiftool is never invoked',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stitch_apply_');
        addTearDown(() => tmp.delete(recursive: true));
        final json = File('${tmp.path}/sidecar.json');
        await json.writeAsString(jsonEncode({'title': 'Only a title'}));
        final media = File('${tmp.path}/photo.jpg');
        await media.writeAsBytes('img'.codeUnits);

        var invoked = false;
        final ok = await applyMetadataWithExiftool(
          media.path,
          json.path,
          runner: (args) async {
            invoked = true;
            return (0, '', '');
          },
          warn: (_) async {},
        );

        expect(
          ok,
          isFalse,
          reason:
              'This mirrors a preserved quirk in the real Python script — '
              'see stitch_metadata.dart\'s module doc comment.',
        );
        expect(invoked, isFalse);
      },
    );

    test('invokes exiftool with date/title/description/GPS flags', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_apply_');
      addTearDown(() => tmp.delete(recursive: true));
      final json = File('${tmp.path}/sidecar.json');
      await json.writeAsString(
        jsonEncode({
          'photoTakenTime': {'timestamp': '0'},
          'title': 'A title',
          'description': 'A description',
          'geoData': {'latitude': 12.5, 'longitude': -45.25},
        }),
      );
      final media = File('${tmp.path}/photo.jpg');
      await media.writeAsBytes('img'.codeUnits);

      List<String>? capturedArgs;
      final ok = await applyMetadataWithExiftool(
        media.path,
        json.path,
        runner: (args) async {
          capturedArgs = args;
          return (0, '', '');
        },
        warn: (_) async {},
      );

      expect(ok, isTrue);
      expect(capturedArgs, isNotNull);
      expect(capturedArgs, contains('-overwrite_original'));
      expect(capturedArgs, contains('-DateTimeOriginal=1970:01:01 00:00:00'));
      expect(capturedArgs, contains('-Title=A title'));
      expect(capturedArgs, contains('-Description=A description'));
      expect(capturedArgs, contains('-GPSLatitude=12.5'));
      expect(capturedArgs, contains('-GPSLongitudeRef=W'));
      expect(capturedArgs!.last, media.path);
    });

    test('omits GPS flags when latitude/longitude are both zero', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_apply_');
      addTearDown(() => tmp.delete(recursive: true));
      final json = File('${tmp.path}/sidecar.json');
      await json.writeAsString(
        jsonEncode({
          'title': 'x',
          'description': 'y',
          'geoData': {'latitude': 0, 'longitude': 0},
        }),
      );
      final media = File('${tmp.path}/photo.jpg');
      await media.writeAsBytes('img'.codeUnits);

      List<String>? capturedArgs;
      await applyMetadataWithExiftool(
        media.path,
        json.path,
        runner: (args) async {
          capturedArgs = args;
          return (0, '', '');
        },
        warn: (_) async {},
      );

      expect(capturedArgs!.any((a) => a.startsWith('-GPSLatitude')), isFalse);
    });

    test('logs a warning and returns false when the JSON is unreadable', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_apply_');
      addTearDown(() => tmp.delete(recursive: true));
      final json = File('${tmp.path}/missing.json');
      final media = File('${tmp.path}/photo.jpg');
      await media.writeAsBytes('img'.codeUnits);

      final warnings = <String>[];
      final ok = await applyMetadataWithExiftool(
        media.path,
        json.path,
        runner: (args) async => (0, '', ''),
        warn: (msg) async => warnings.add(msg),
      );

      expect(ok, isFalse);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('Could not read JSON sidecar'));
    });

    test('logs a warning and returns false when exiftool exits non-zero', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_apply_');
      addTearDown(() => tmp.delete(recursive: true));
      final json = File('${tmp.path}/sidecar.json');
      await json.writeAsString(
        jsonEncode({
          'photoTakenTime': {'timestamp': '0'},
        }),
      );
      final media = File('${tmp.path}/photo.jpg');
      await media.writeAsBytes('img'.codeUnits);

      final warnings = <String>[];
      final ok = await applyMetadataWithExiftool(
        media.path,
        json.path,
        runner: (args) async => (1, 'boom', ''),
        warn: (msg) async => warnings.add(msg),
      );

      expect(ok, isFalse);
      expect(warnings.single, contains('exiftool failed for'));
      expect(warnings.single, contains('boom'));
    });
  });

  group('TakeoutArchiveExtractor', () {
    test('extracts when every member is a safe path', () async {
      var extractCalled = false;
      final extractor = TakeoutArchiveExtractor(
        zipLister: (_) async => ['Google Photos/IMG_1.jpg', 'Google Photos/IMG_1.jpg.json'],
        zipExtractor: (archivePath, destDir) async {
          extractCalled = true;
        },
      );

      await extractor.extract('/archives/takeout.zip', '/dest', ArchiveKind.zip);
      expect(extractCalled, isTrue);
    });

    test('blocks extraction when any member escapes the destination', () async {
      var extractCalled = false;
      final extractor = TakeoutArchiveExtractor(
        zipLister: (_) async => ['Google Photos/IMG_1.jpg', '../evil.jpg'],
        zipExtractor: (archivePath, destDir) async {
          extractCalled = true;
        },
      );

      await expectLater(
        extractor.extract('/archives/takeout.zip', '/dest', ArchiveKind.zip),
        throwsA(isA<StateError>()),
      );
      expect(
        extractCalled,
        isFalse,
        reason:
            'Every member must be validated before extraction starts — no '
            'partial extraction of an untrusted archive.',
      );
    });

    test('uses the tar lister/extractor for ArchiveKind.tarGz', () async {
      var tarExtractCalled = false;
      var zipExtractCalled = false;
      final extractor = TakeoutArchiveExtractor(
        zipLister: (_) async => [],
        zipExtractor: (a, d) async => zipExtractCalled = true,
        tarLister: (_) async => ['Google Photos/IMG_1.jpg'],
        tarExtractor: (a, d) async => tarExtractCalled = true,
      );

      await extractor.extract(
        '/archives/takeout.tgz',
        '/dest',
        ArchiveKind.tarGz,
      );
      expect(tarExtractCalled, isTrue);
      expect(zipExtractCalled, isFalse);
    });
  });

  group('moveToStaging', () {
    test('renames a colliding destination with a numbered suffix', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_move_');
      addTearDown(() => tmp.delete(recursive: true));

      final extracted = Directory('${tmp.path}/takeout');
      final sourceDir = Directory('${extracted.path}/Google Photos');
      await sourceDir.create(recursive: true);
      final media = File('${sourceDir.path}/photo.jpg');
      await media.writeAsBytes('new'.codeUnits);

      final staging = Directory('${tmp.path}/cleaning_staging');
      final existingDir = Directory('${staging.path}/Google Photos');
      await existingDir.create(recursive: true);
      final existing = File('${existingDir.path}/photo.jpg');
      await existing.writeAsBytes('existing'.codeUnits);

      final dest = await moveToStaging(
        media.path,
        extracted.path,
        staging.path,
      );

      expect(dest, '${existingDir.path}/photo_1.jpg');
      expect(await File(dest).exists(), isTrue);
      expect(await media.exists(), isFalse);
      expect(await existing.readAsBytes(), 'existing'.codeUnits);
    });

    test('moves cleanly to the mirrored relative path when no collision', () async {
      final tmp = await Directory.systemTemp.createTemp('stitch_move_');
      addTearDown(() => tmp.delete(recursive: true));

      final extracted = Directory('${tmp.path}/takeout');
      final sourceDir = Directory('${extracted.path}/Album');
      await sourceDir.create(recursive: true);
      final media = File('${sourceDir.path}/photo.jpg');
      await media.writeAsBytes('bytes'.codeUnits);

      final staging = '${tmp.path}/cleaning_staging';
      final dest = await moveToStaging(media.path, extracted.path, staging);

      expect(dest, '$staging/Album/photo.jpg');
      expect(await File(dest).exists(), isTrue);
      expect(await media.exists(), isFalse);
    });
  });

  group('processExtractedTree', () {
    test(
      'clean match applies metadata; missing sidecar and exiftool failure '
      'both log a warning and still move the file, without aborting',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stitch_tree_');
        addTearDown(() => tmp.delete(recursive: true));

        final extracted = Directory('${tmp.path}/extracted');
        await extracted.create(recursive: true);
        final staging = '${tmp.path}/cleaning_staging';

        // Clean match.
        final clean = File('${extracted.path}/clean.jpg');
        await clean.writeAsBytes('img'.codeUnits);
        await File('${extracted.path}/clean.jpg.json').writeAsString(
          jsonEncode({
            'photoTakenTime': {'timestamp': '0'},
          }),
        );

        // Missing sidecar.
        final noSidecar = File('${extracted.path}/nosidecar.jpg');
        await noSidecar.writeAsBytes('img'.codeUnits);

        // Corrupt file: sidecar exists but exiftool reports failure.
        final corrupt = File('${extracted.path}/corrupt.jpg');
        await corrupt.writeAsBytes('img'.codeUnits);
        await File('${extracted.path}/corrupt.jpg.json').writeAsString(
          jsonEncode({
            'photoTakenTime': {'timestamp': '0'},
          }),
        );

        final warnings = <String>[];
        final summary = await processExtractedTree(
          extracted.path,
          cleaningStaging: staging,
          exiftool: (args) async {
            if (args.last == corrupt.path) {
              return (1, 'simulated corruption', '');
            }
            return (0, '', '');
          },
          warn: (msg) async => warnings.add(msg),
        );

        expect(summary.processed, 3);
        expect(summary.warnings, 2);
        expect(
          warnings.any((w) => w.contains('no matched/processed JSON sidecar')),
          isTrue,
        );
        expect(
          warnings.any((w) => w.contains('exiftool failed for')),
          isTrue,
        );

        // All three files still moved to staging, regardless of warnings —
        // this is the hard "continue past corrupt files" rule.
        expect(await File('$staging/clean.jpg').exists(), isTrue);
        expect(await File('$staging/nosidecar.jpg').exists(), isTrue);
        expect(await File('$staging/corrupt.jpg').exists(), isTrue);
        expect(await clean.exists(), isFalse);
        expect(await noSidecar.exists(), isFalse);
        expect(await corrupt.exists(), isFalse);
      },
    );
  });

  group('MetadataStitcher.run', () {
    test(
      'processes an archive end-to-end: extracts, applies metadata, moves '
      'to staging, deletes the archive, and cleans up the scratch dir',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stitch_run_');
        addTearDown(() => tmp.delete(recursive: true));
        final hdPath = tmp.path;

        final rawZips = Directory(rawTakeoutZipsPath(hdPath));
        await rawZips.create(recursive: true);

        // Build a real zip archive containing a clean match and a
        // missing-sidecar file.
        final srcDir = Directory('${tmp.path}/src/Google Photos');
        await srcDir.create(recursive: true);
        await File('${srcDir.path}/clean.jpg').writeAsBytes('img'.codeUnits);
        await File('${srcDir.path}/clean.jpg.json').writeAsString(
          jsonEncode({
            'photoTakenTime': {'timestamp': '0'},
          }),
        );
        await File(
          '${srcDir.path}/nosidecar.jpg',
        ).writeAsBytes('img'.codeUnits);

        final archivePath = '${rawZips.path}/takeout-001.zip';
        final zipResult = await Process.run('zip', [
          '-r',
          archivePath,
          '.',
        ], workingDirectory: '${tmp.path}/src');
        expect(zipResult.exitCode, 0, reason: zipResult.stderr as String);

        final stitcher = MetadataStitcher(
          exiftool: (args) async => (0, '', ''),
        );
        final logs = <String>[];
        final summary = await stitcher.run(hdPath, print: logs.add);

        expect(summary.archivesProcessed, 1);
        expect(summary.mediaMoved, 2);
        expect(summary.warnings, 1);
        expect(
          await File(
            '${cleaningStagingPath(hdPath)}/Google Photos/clean.jpg',
          ).exists(),
          isTrue,
        );
        expect(
          await File(
            '${cleaningStagingPath(hdPath)}/Google Photos/nosidecar.jpg',
          ).exists(),
          isTrue,
        );
        expect(
          await File(archivePath).exists(),
          isFalse,
          reason: 'the processed archive is deleted after success',
        );
        expect(
          await Directory(takeoutExtractedPath(hdPath)).list().isEmpty,
          isTrue,
          reason: 'the extraction scratch directory is always cleaned up',
        );
        expect(
          await File(stitchWarningLogPath(hdPath)).readAsString(),
          contains('no matched/processed JSON sidecar'),
        );
      },
    );

    test(
      'an unsafe archive member aborts the run and keeps the archive for retry',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stitch_run_');
        addTearDown(() => tmp.delete(recursive: true));
        final hdPath = tmp.path;
        await Directory(rawTakeoutZipsPath(hdPath)).create(recursive: true);
        final archivePath = '${rawTakeoutZipsPath(hdPath)}/evil.zip';
        await File(archivePath).writeAsBytes('not a real zip'.codeUnits);

        final stitcher = MetadataStitcher(
          exiftool: (args) async => (0, '', ''),
          archiveExtractor: TakeoutArchiveExtractor(
            zipLister: (_) async => ['../evil.jpg'],
          ),
        );

        await expectLater(
          stitcher.run(hdPath),
          throwsA(isA<StateError>()),
        );

        expect(
          await File(archivePath).exists(),
          isTrue,
          reason: 'a failed archive is kept in place for retry, never deleted',
        );
      },
    );
  });

  group(
    'Python-vs-Dart parity: MetadataStitcher matches '
    "04_stitch_metadata.py's real decisions",
    () {
      test(
        'identical processed/warning outcomes for a clean match, a '
        'missing-sidecar file, and a corrupt (exiftool-failing) file, '
        'using the same fake-exiftool stubbing protocol as the Bash-vs-Dart '
        'parity tests for the other four ports in this series',
        () async {
          final repoRoot = _findRepoRoot();
          final fakeBinDir = await Directory.systemTemp.createTemp(
            'stitch_parity_bin_',
          );
          addTearDown(() async {
            if (await fakeBinDir.exists()) {
              await fakeBinDir.delete(recursive: true);
            }
          });
          final fakeExiftool = await _writeFakeExiftool(fakeBinDir);
          // 04_stitch_metadata.py hard-codes the literal command name
          // "exiftool" (no FFPROBE_BIN-style override), so make the fake
          // binary resolvable under that exact name via PATH.
          final exiftoolAlias = File('${fakeBinDir.path}/exiftool');
          await fakeExiftool.copy(exiftoolAlias.path);
          await Process.run('chmod', ['0755', exiftoolAlias.path]);

          Future<Directory> buildFixtureSourceTree(String rootPath) async {
            final srcDir = Directory('$rootPath/Google Photos');
            await srcDir.create(recursive: true);

            // Case 1: clean match — media + matching JSON sidecar, no
            // exiftool failure.
            await File(
              '${srcDir.path}/clean.jpg',
            ).writeAsBytes('img-clean'.codeUnits);
            await File('${srcDir.path}/clean.jpg.json').writeAsString(
              jsonEncode({
                'photoTakenTime': {'timestamp': '0'},
                'title': 'Clean',
              }),
            );

            // Case 2: missing sidecar — file kept, warning logged.
            await File(
              '${srcDir.path}/nosidecar.jpg',
            ).writeAsBytes('img-nosidecar'.codeUnits);

            // Case 3: corrupt file — sidecar present, but the (fake)
            // exiftool invocation fails. File kept without metadata
            // update, warning logged, run continues past it.
            await File(
              '${srcDir.path}/corrupt.jpg',
            ).writeAsString('FAIL_EXIFTOOL\n');
            await File('${srcDir.path}/corrupt.jpg.json').writeAsString(
              jsonEncode({
                'photoTakenTime': {'timestamp': '0'},
                'title': 'Corrupt',
              }),
            );

            return srcDir;
          }

          // --- Run the real Python script. ---
          final pyTemp = await Directory.systemTemp.createTemp(
            'stitch_parity_py_',
          );
          addTearDown(() async {
            if (await pyTemp.exists()) await pyTemp.delete(recursive: true);
          });
          final pyHdPath = pyTemp.path;
          final pySrc = await buildFixtureSourceTree('${pyTemp.path}/src');
          final pyRawZips = Directory(rawTakeoutZipsPath(pyHdPath));
          await pyRawZips.create(recursive: true);
          final pyArchive = '${pyRawZips.path}/takeout-parity.zip';
          final pyZip = await Process.run('zip', [
            '-r',
            pyArchive,
            '.',
          ], workingDirectory: pySrc.parent.path);
          expect(pyZip.exitCode, 0, reason: pyZip.stderr as String);

          final pyResult = await Process.run(
            'python3',
            [
              '${repoRoot.path}/scripts/04_stitch_metadata.py',
            ],
            environment: {
              ...Platform.environment,
              'HD_PATH': pyHdPath,
              'PATH':
                  '${fakeBinDir.path}:${Platform.environment['PATH'] ?? ''}',
            },
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(pyResult.exitCode, 0, reason: pyResult.stderr as String);
          final pyStdout = pyResult.stdout as String;
          expect(pyStdout, contains('media moved: 3; warnings: 2'));
          final pyWarnings = await File(
            stitchWarningLogPath(pyHdPath),
          ).readAsString();
          expect(pyWarnings, contains('nosidecar.jpg'));
          expect(pyWarnings, contains('corrupt.jpg'));
          expect(
            await File(
              '${cleaningStagingPath(pyHdPath)}/Google Photos/clean.jpg',
            ).exists(),
            isTrue,
          );
          expect(
            await File(
              '${cleaningStagingPath(pyHdPath)}/Google Photos/nosidecar.jpg',
            ).exists(),
            isTrue,
          );
          expect(
            await File(
              '${cleaningStagingPath(pyHdPath)}/Google Photos/corrupt.jpg',
            ).exists(),
            isTrue,
          );

          // --- Run the Dart port against an identical fixture. ---
          final dartTemp = await Directory.systemTemp.createTemp(
            'stitch_parity_dart_',
          );
          addTearDown(() async {
            if (await dartTemp.exists()) {
              await dartTemp.delete(recursive: true);
            }
          });
          final dartHdPath = dartTemp.path;
          final dartSrc = await buildFixtureSourceTree(
            '${dartTemp.path}/src',
          );
          final dartRawZips = Directory(rawTakeoutZipsPath(dartHdPath));
          await dartRawZips.create(recursive: true);
          final dartArchive = '${dartRawZips.path}/takeout-parity.zip';
          final dartZip = await Process.run('zip', [
            '-r',
            dartArchive,
            '.',
          ], workingDirectory: dartSrc.parent.path);
          expect(dartZip.exitCode, 0, reason: dartZip.stderr as String);

          final stitcher = MetadataStitcher(
            exiftool: exiftoolRunner(exiftoolBin: fakeExiftool.path),
          );
          final summary = await stitcher.run(dartHdPath);

          expect(summary.mediaMoved, 3);
          expect(summary.warnings, 2);
          expect(
            await File(
              '${cleaningStagingPath(dartHdPath)}/Google Photos/clean.jpg',
            ).exists(),
            isTrue,
          );
          expect(
            await File(
              '${cleaningStagingPath(dartHdPath)}/Google Photos/nosidecar.jpg',
            ).exists(),
            isTrue,
          );
          expect(
            await File(
              '${cleaningStagingPath(dartHdPath)}/Google Photos/corrupt.jpg',
            ).exists(),
            isTrue,
          );
          final dartWarnings = await File(
            stitchWarningLogPath(dartHdPath),
          ).readAsString();
          expect(dartWarnings, contains('nosidecar.jpg'));
          expect(dartWarnings, contains('corrupt.jpg'));

          // The two implementations must agree on processed/warning counts
          // — the actual parity assertion this test exists for.
          expect(summary.mediaMoved, 3);
          expect(
            pyStdout.contains('media moved: 3; warnings: 2'),
            isTrue,
          );
        },
      );
    },
  );
}

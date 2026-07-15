import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/stitch_metadata.dart';
import 'package:media_pipeline_app/src/tools_container.dart';

/// True only if a real Docker daemon is reachable from this machine. Mirrors
/// `test/tools_container_test.dart`'s/`test/dedupe_live_photos_test.dart`'s
/// own `_dockerAvailable` exactly (duplicated here rather than shared,
/// matching those files' own precedent of duplicating this small check
/// rather than sharing it across test files in this repo).
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

/// A Dart-native stand-in for [_writeFakeExiftool]'s marker protocol, used
/// only by the Bash^H^H Python-vs-Dart parity test's *Dart* side below.
///
/// ## Why the parity test's Dart side no longer shells out to `exiftool`
/// (real or fake) at all
///
/// Before this migration (`lib/src/stitch_metadata.dart`'s top-level
/// "Design decision: all three external tools ... route through
/// [ToolsContainer]" doc comment), the Dart side of this test called
/// `exiftoolRunner(exiftoolBin: fakeExiftool.path)` — i.e. it exercised the
/// *host* `Process.run` mechanism against a fake binary on disk, mirroring
/// exactly what the real Python script also does via its `PATH` override.
/// Now that real `exiftool` invocation is routed through a [ToolsContainer]
/// exec in production, reusing that host-shelling approach here would mean
/// either (a) standing up a real container and somehow getting a stub
/// `exiftool` installed *inside* the pinned `media-pipeline-tools` image
/// just for this one test — a lot of moving parts for a test whose actual
/// job is verifying `apply_metadata_with_exiftool`'s tag-building and
/// skip-on-len-3 decision logic, not the container-exec mechanism — or (b)
/// keeping the host-process seam wired in as if it were still the
/// production path, which it no longer is (see PR #94's identical call on
/// this exact tradeoff for `dedupe_live_photos.dart`'s `ffprobe` migration).
///
/// This test's real job is proving the Dart port's processed/warning counts
/// and file placement match the real Python script's exactly; that has
/// nothing to do with *how* `exiftool`'s exit code and output get fetched.
/// So this function replicates [_writeFakeExiftool]'s exact marker-file
/// protocol directly in Dart, with zero process/container involvement —
/// the Python-vs-Dart comparison below stays meaningful (both sides consume
/// the identical synthetic fixture files under the identical marker
/// protocol; only the *mechanism* invoking "exiftool" differs, which is not
/// what this test is verifying). The real container-exec mechanism (host
/// path -> container path translation -> real `exiftool` -> file actually
/// tagged) is covered separately, for real, by the Docker-gated group in
/// this file below (see "stitch metadata via a real ToolsContainer").
Future<(int, String, String)> _fakeExiftoolRunnerFromMarkerFile(
  List<String> args,
) async {
  if (args.isEmpty) return (1, 'no media path given', '');
  final mediaPath = args.last;
  final file = File(mediaPath);
  var firstLine = '';
  if (await file.exists()) {
    final lines = await file.readAsLines();
    firstLine = lines.isEmpty ? '' : lines.first;
  }
  if (firstLine == 'FAIL_EXIFTOOL') {
    return (1, 'fake exiftool: simulated corrupt file', '');
  }
  return (0, '', '');
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
          archiveExtractor: TakeoutArchiveExtractor(),
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
            exiftool: _fakeExiftoolRunnerFromMarkerFile,
            archiveExtractor: TakeoutArchiveExtractor(),
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

  group(
    'container path-safety composition (no Docker needed — fake docker '
    'runner exercises the argument-building/error-handling logic '
    'deterministically, same posture as test/tools_container_test.dart\'s '
    'own "fake docker runner" group)',
    () {
      /// Builds a [ToolsContainer] whose fake `docker` runner: answers
      /// `docker run` with a canned container ID, records every other call
      /// into [execCalls], answers an `unzip -Z1` listing call with
      /// [zipMembers] (one member per line), and answers every other exec
      /// (an actual extraction, or an unrecognized command) with a bare
      /// success.
      Future<ToolsContainer> startFakeContainer({
        required List<List<String>> execCalls,
        List<String> zipMembers = const [],
      }) async {
        final container = ToolsContainer(
          hostMountRoot: '/mnt/target_drive',
          runner: (args) async {
            if (args.first == 'run') {
              return ProcessResult(0, 0, 'container123\n', '');
            }
            execCalls.add(args);
            if (args.contains('-Z1')) {
              return ProcessResult(0, 0, '${zipMembers.join('\n')}\n', '');
            }
            return ProcessResult(0, 0, '', '');
          },
        );
        await container.start();
        return container;
      }

      test(
        'containerZipLister and containerZipExtractor translate every host '
        'path (archive path, destDir) to its container equivalent before '
        'exec\'ing',
        () async {
          final execCalls = <List<String>>[];
          final container = await startFakeContainer(
            execCalls: execCalls,
            zipMembers: ['Google Photos/IMG_1.jpg'],
          );

          final lister = containerZipLister(container: container);
          final members = await lister(
            '/mnt/target_drive/raw_takeout_zips/takeout.zip',
          );
          expect(members, ['Google Photos/IMG_1.jpg']);
          expect(execCalls.last, [
            'exec',
            'container123',
            'unzip',
            '-Z1',
            '/data/raw_takeout_zips/takeout.zip',
          ]);

          final extractor = containerZipExtractor(container: container);
          await extractor(
            '/mnt/target_drive/raw_takeout_zips/takeout.zip',
            '/mnt/target_drive/takeout_extracted/takeout',
          );
          expect(execCalls.last, [
            'exec',
            'container123',
            'unzip',
            '-o',
            '-d',
            '/data/takeout_extracted/takeout',
            '/data/raw_takeout_zips/takeout.zip',
          ]);
        },
      );

      test(
        'containerTarLister and containerTarExtractor translate every host '
        'path to its container equivalent before exec\'ing',
        () async {
          final execCalls = <List<String>>[];
          final container = await startFakeContainer(execCalls: execCalls);

          final extractor = containerTarExtractor(container: container);
          await extractor(
            '/mnt/target_drive/raw_takeout_zips/takeout.tgz',
            '/mnt/target_drive/takeout_extracted/takeout',
          );
          expect(execCalls.last, [
            'exec',
            'container123',
            'tar',
            '-xzf',
            '/data/raw_takeout_zips/takeout.tgz',
            '-C',
            '/data/takeout_extracted/takeout',
          ]);

          final lister = containerTarLister(container: container);
          await lister('/mnt/target_drive/raw_takeout_zips/takeout.tgz');
          expect(execCalls.last, [
            'exec',
            'container123',
            'tar',
            '-tzf',
            '/data/raw_takeout_zips/takeout.tgz',
          ]);
        },
      );

      test(
        'an unsafe archive member is blocked before any container extract '
        'exec runs, even when routed entirely through the container-backed '
        'lister/extractor (isPathTraversalSafe still runs first, on '
        'host-domain paths, unaware a container is even involved)',
        () async {
          final execCalls = <List<String>>[];
          final container = await startFakeContainer(
            execCalls: execCalls,
            zipMembers: ['../evil.jpg'],
          );

          final extractor = containerTakeoutArchiveExtractor(
            container: container,
          );
          await expectLater(
            extractor.extract(
              '/mnt/target_drive/raw_takeout_zips/evil.zip',
              '/mnt/target_drive/takeout_extracted/evil',
              ArchiveKind.zip,
            ),
            throwsA(isA<StateError>()),
          );

          // Only the listing exec (-Z1) ran; no extraction exec (-o) was
          // ever issued — the member-safety check aborted first.
          expect(execCalls.where((c) => c.contains('-o')), isEmpty);
        },
      );

      test(
        'a destDir outside the container\'s mount root is rejected — even '
        'when every archive member is individually safe — because '
        'ToolsContainer.hostToContainerPath checks a completely separate '
        'axis (mount boundary) from isPathTraversalSafe (member vs. '
        'destDir), and neither substitutes for the other',
        () async {
          final execCalls = <List<String>>[];
          final container = await startFakeContainer(
            execCalls: execCalls,
            zipMembers: ['Google Photos/IMG_1.jpg'],
          );

          final extractor = containerTakeoutArchiveExtractor(
            container: container,
          );
          await expectLater(
            extractor.extract(
              '/mnt/target_drive/raw_takeout_zips/takeout.zip',
              // Outside hostMountRoot ("/mnt/target_drive") entirely.
              '/mnt/other_drive/takeout_extracted/takeout',
              ArchiveKind.zip,
            ),
            throwsArgumentError,
          );

          // Every member passed isPathTraversalSafe (it's a perfectly
          // normal relative path) — the rejection came entirely from the
          // mount-boundary check, and no extraction exec was ever issued.
          expect(execCalls.where((c) => c.contains('-o')), isEmpty);
        },
      );

      test(
        'containerExiftoolRunner translates only the trailing media-path '
        'argument, leaving every flag/value argument untouched',
        () async {
          final execCalls = <List<String>>[];
          final container = await startFakeContainer(execCalls: execCalls);

          final runner = containerExiftoolRunner(container: container);
          final result = await runner([
            '-overwrite_original',
            '-Title=Clean',
            '/mnt/target_drive/takeout_extracted/x/clean.jpg',
          ]);

          expect(result.$1, 0);
          expect(execCalls.last, [
            'exec',
            'container123',
            'exiftool',
            '-overwrite_original',
            '-Title=Clean',
            '/data/takeout_extracted/x/clean.jpg',
          ]);
        },
      );

      test(
        'containerExiftoolRunner throws ArgumentError (never silently '
        'mistranslates) for a media path outside the container\'s mount '
        'root',
        () async {
          final execCalls = <List<String>>[];
          final container = await startFakeContainer(execCalls: execCalls);

          final runner = containerExiftoolRunner(container: container);
          await expectLater(
            runner(['-overwrite_original', '/etc/passwd']),
            throwsArgumentError,
          );
          expect(
            execCalls,
            isEmpty,
            reason:
                'the path-translation failure must happen before any '
                'exec is issued',
          );
        },
      );
    },
  );

  group(
    'stitch metadata via a real ToolsContainer (requires Docker + the '
    'media-pipeline-tools:local image built per docker/tools/README.md)',
    () {
      late Directory tempDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'stitch_metadata_container_test_',
        );
        // No chmod workaround needed here any more: ToolsContainer.start()
        // now passes `--user <host-uid>:<host-gid>` to `docker run` (#76
        // Phase 3, lib/src/tools_container.dart), overriding the image's
        // baked-in fixed non-root UID (`tools`, uid 10000) so the container
        // reads/writes as the real host user instead. See
        // test/tools_container_test.dart's "host UID/GID mapping" group
        // for the dedicated proof.
      });

      tearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      test(
        'extracts a real zip archive with real unzip, applies real '
        'exiftool metadata to a genuine generated image, and moves both '
        'the tagged file and a missing-sidecar file to cleaning_staging — '
        'proving the full host path -> container path translation -> real '
        'unzip/exiftool exec -> host-visible result chain, not just its '
        'pieces in isolation',
        () async {
          final hdPath = tempDir.path;
          final container = ToolsContainer(hostMountRoot: hdPath);
          await container.start();
          try {
            final srcDir = Directory('$hdPath/src/Google Photos');
            await srcDir.create(recursive: true);

            // Generate a real, genuinely-encoded 1-frame JPEG using the
            // pinned image's own ffmpeg (not a pre-baked fixture checked
            // into the repo), writing directly to the bind-mounted host
            // directory via a container exec — this is the same "generate
            // with the image's own tools" pattern
            // dedupe_live_photos_test.dart's real-ToolsContainer group uses
            // for its synthetic video.
            final hostImagePath = '${srcDir.path}/clean.jpg';
            final containerImagePath = container.hostToContainerPath(
              hostImagePath,
            );
            final genResult = await container.exec([
              'ffmpeg',
              '-y',
              '-f',
              'lavfi',
              '-i',
              'color=c=red:s=32x32:d=1',
              '-frames:v',
              '1',
              '-update',
              '1',
              containerImagePath,
            ]);
            expect(
              genResult.exitCode,
              0,
              reason:
                  'ffmpeg synthetic-image generation failed: '
                  '${genResult.stderr}',
            );
            expect(
              await File(hostImagePath).exists(),
              isTrue,
              reason:
                  'the file ffmpeg wrote inside the container at '
                  '$containerImagePath must appear on the host at '
                  '$hostImagePath via the bind mount — this is the "where '
                  'extraction happens" contract this PR\'s doc comment '
                  'documents, exercised here for a plain container write '
                  'rather than an unzip/tar extraction specifically.',
            );
            await File('${srcDir.path}/clean.jpg.json').writeAsString(
              jsonEncode({
                'photoTakenTime': {'timestamp': '0'},
                'title': 'Clean Title',
              }),
            );

            // A second media file with no JSON sidecar at all — proves the
            // "continue past a file that can't get metadata, still move
            // it" hard rule holds when the archive extraction and (for the
            // other file) the exiftool call are both real container execs,
            // not just mocked Dart functions.
            await File(
              '${srcDir.path}/nosidecar.jpg',
            ).writeAsBytes('not a real image, no sidecar exists'.codeUnits);

            final rawZips = Directory(rawTakeoutZipsPath(hdPath));
            await rawZips.create(recursive: true);
            final archivePath = '${rawZips.path}/takeout-e2e.zip';
            final zipResult = await Process.run('zip', [
              '-r',
              archivePath,
              '.',
            ], workingDirectory: srcDir.parent.path);
            expect(zipResult.exitCode, 0, reason: zipResult.stderr as String);

            // extractArchive() (lib/src/stitch_metadata.dart) creates the
            // extraction destDir on the HOST, with the host process's
            // default umask. Previously (#76 Phase 3 not yet implemented)
            // that directory wasn't writable by the container's fixed
            // non-root uid (10000), requiring a chmod-after-create
            // workaround here; now that ToolsContainer.start() passes
            // `--user <host-uid>:<host-gid>` to `docker run`, the container
            // runs as the same uid that created destDir, so no workaround
            // is needed — the extractors are used unwrapped, straight from
            // the container-routed seams.
            final stitcher = MetadataStitcher(
              exiftool: containerExiftoolRunner(container: container),
              archiveExtractor: TakeoutArchiveExtractor(
                zipLister: containerZipLister(container: container),
                zipExtractor: containerZipExtractor(container: container),
                tarLister: containerTarLister(container: container),
                tarExtractor: containerTarExtractor(container: container),
              ),
            );
            final summary = await stitcher.run(hdPath);

            expect(summary.archivesProcessed, 1);
            expect(summary.mediaMoved, 2);
            expect(
              summary.warnings,
              1,
              reason: 'only nosidecar.jpg (no matched JSON sidecar) warns',
            );

            final stagedCleanPath =
                '${cleaningStagingPath(hdPath)}/Google Photos/clean.jpg';
            final stagedNoSidecarPath =
                '${cleaningStagingPath(hdPath)}/Google Photos/nosidecar.jpg';
            expect(await File(stagedCleanPath).exists(), isTrue);
            expect(await File(stagedNoSidecarPath).exists(), isTrue);
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

            // Independently verify — via a fresh, separate real exiftool
            // exec, not by trusting applyMetadataWithExiftool's own return
            // value — that the tag was actually written to the staged
            // file.
            final containerStagedCleanPath = container.hostToContainerPath(
              stagedCleanPath,
            );
            final checkResult = await container.exec([
              'exiftool',
              '-s3',
              '-Title',
              containerStagedCleanPath,
            ]);
            expect(checkResult.exitCode, 0);
            expect(
              (checkResult.stdout as String).trim(),
              'Clean Title',
              reason:
                  'proves exiftool -Title=... actually ran and persisted, '
                  'not just that applyMetadataWithExiftool returned true',
            );
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
    },
  );

  group('Docker/image availability self-check (meta-test)', () {
    test(
      'this test file is actually exercising real Docker, not silently '
      'skipping — makes the skip reason visible in test output',
      () {
        if (!_dockerReady) {
          // ignore: avoid_print
          print(
            'NOTE: Docker daemon not reachable — the "stitch metadata via '
            'a real ToolsContainer" group above was skipped, not run.',
          );
        } else if (!_imageReady) {
          // ignore: avoid_print
          print(
            'NOTE: Docker is available but media-pipeline-tools:local is '
            'not built — the "stitch metadata via a real ToolsContainer" '
            'group above was skipped, not run. Build it per '
            'docker/tools/README.md.',
          );
        } else {
          // ignore: avoid_print
          print(
            'Docker + media-pipeline-tools:local are both available — the '
            '"stitch metadata via a real ToolsContainer" group above '
            'actually ran against a real container.',
          );
        }
      },
    );
  });
}

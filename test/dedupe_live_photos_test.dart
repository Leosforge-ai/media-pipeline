import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/dedupe_live_photos.dart';

/// Finds the repo root by walking up from this test file's directory until
/// `scripts/13_dedupe_live_photos.sh` is found. Mirrors the
/// `ROOT = Path(__file__).resolve().parents[1]` convention
/// `tests/test_shell_scripts.py` uses for the same script, and the
/// `_findRepoRoot` helper `test/clean_takeout_duplicates_test.dart` already
/// uses, so the Bash-vs-Dart parity test below runs the exact same file the
/// Python suite already covers.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/scripts/13_dedupe_live_photos.sh').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current}');
}

/// Writes a fake `ffprobe` stand-in, mirroring
/// `tests/test_shell_scripts.py`'s own `write_fake_ffprobe` exactly (same
/// marker protocol), so the Bash-vs-Dart parity test below and the real
/// Python test suite exercise the two implementations against an
/// identical stubbing mechanism:
///
/// - first line `DURATION=<seconds>` -> prints `<seconds>` (like real
///   `ffprobe`'s `-show_entries format=duration` output).
/// - first line `UNKNOWN` -> exits non-zero with no stdout, simulating
///   `ffprobe` being unable to determine a duration at all.
Future<File> _writeFakeFfprobe(Directory root) async {
  final fake = File('${root.path}/fake_ffprobe.sh');
  await fake.writeAsString('''
#!/usr/bin/env bash
file="\${@: -1}"
first_line="\$(head -n1 "\$file" 2>/dev/null || true)"
case "\$first_line" in
DURATION=*) echo "\${first_line#DURATION=}" ;;
UNKNOWN) exit 1 ;;
*) echo "1.500000" ;;
esac
''');
  final result = await Process.run('chmod', ['0755', fake.path]);
  expect(result.exitCode, 0);
  return fake;
}

void main() {
  group('pairStillsAndVideos', () {
    test('pairs a still and video sharing a basename', () {
      final pairing = pairStillsAndVideos([
        '/dir/IMG_1234.HEIC',
        '/dir/IMG_1234.MOV',
      ]);
      expect(pairing.videoOrder, ['IMG_1234']);
      expect(pairing.stillPathByBase['IMG_1234'], '/dir/IMG_1234.HEIC');
      expect(pairing.videoPathByBase['IMG_1234'], '/dir/IMG_1234.MOV');
    });

    test('is case-insensitive on the extension only', () {
      final pairing = pairStillsAndVideos([
        '/dir/IMG_1.heic',
        '/dir/IMG_1.MOV',
        '/dir/IMG_2.JPG',
        '/dir/IMG_2.mp4',
      ]);
      expect(pairing.stillPathByBase['IMG_1'], '/dir/IMG_1.heic');
      expect(pairing.videoPathByBase['IMG_1'], '/dir/IMG_1.MOV');
      expect(pairing.stillPathByBase['IMG_2'], '/dir/IMG_2.JPG');
      expect(pairing.videoPathByBase['IMG_2'], '/dir/IMG_2.mp4');
    });

    test('ignores unrelated extensions entirely', () {
      final pairing = pairStillsAndVideos([
        '/dir/notes.txt',
        '/dir/IMG_1.HEIC',
      ]);
      expect(pairing.videoOrder, isEmpty);
      expect(pairing.stillPathByBase['IMG_1'], '/dir/IMG_1.HEIC');
    });

    test('skips a filename with no extension at all', () {
      final pairing = pairStillsAndVideos(['/dir/README', '/dir/IMG_1.MOV']);
      expect(pairing.videoOrder, ['IMG_1']);
      expect(pairing.stillPathByBase, isEmpty);
    });

    test('a video with no paired still has no entry in stillPathByBase', () {
      final pairing = pairStillsAndVideos(['/dir/IMG_1.MOV']);
      expect(pairing.videoOrder, ['IMG_1']);
      expect(pairing.stillPathByBase.containsKey('IMG_1'), isFalse);
    });

    test(
      'never matches across directories — only same-directory input is '
      'ever passed to this function',
      () {
        // Simulates what would happen if a caller mistakenly passed paths
        // from two different directories sharing a basename: the pairing
        // is purely basename-keyed within whatever list it's given, so the
        // caller (LivePhotoDedupeCleaner.run) is responsible for only ever
        // calling this once per directory — verified by the async
        // orchestration tests below, which use two directories with the
        // same basename and confirm they are NOT paired together.
        final pairing = pairStillsAndVideos([
          '/dirA/IMG_1.HEIC',
          '/dirB/IMG_1.MOV',
        ]);
        expect(pairing.stillPathByBase['IMG_1'], '/dirA/IMG_1.HEIC');
        expect(pairing.videoPathByBase['IMG_1'], '/dirB/IMG_1.MOV');
      },
    );
  });

  group('evaluateVideoDuration', () {
    test('verified when duration is numeric and <= threshold', () {
      expect(
        evaluateVideoDuration(rawDuration: '2.000000'),
        DurationVerification.verified,
      );
      expect(
        evaluateVideoDuration(rawDuration: '5.000000'),
        DurationVerification.verified,
      );
      expect(
        evaluateVideoDuration(rawDuration: '5'),
        DurationVerification.verified,
      );
    });

    test('tooLong when duration is numeric and > threshold', () {
      expect(
        evaluateVideoDuration(rawDuration: '5.000001'),
        DurationVerification.tooLong,
      );
      expect(
        evaluateVideoDuration(rawDuration: '612.000000'),
        DurationVerification.tooLong,
      );
    });

    test('unknown when rawDuration is null (ffprobe failed)', () {
      expect(
        evaluateVideoDuration(rawDuration: null),
        DurationVerification.unknown,
      );
    });

    test('unknown when rawDuration is empty or non-numeric', () {
      expect(
        evaluateVideoDuration(rawDuration: ''),
        DurationVerification.unknown,
      );
      expect(
        evaluateVideoDuration(rawDuration: 'N/A'),
        DurationVerification.unknown,
      );
    });

    test(
      'unknown for forms the Bash regex would reject: negative, exponent, '
      'leading dot',
      () {
        expect(
          evaluateVideoDuration(rawDuration: '-1.0'),
          DurationVerification.unknown,
        );
        expect(
          evaluateVideoDuration(rawDuration: '1e10'),
          DurationVerification.unknown,
        );
        expect(
          evaluateVideoDuration(rawDuration: '.5'),
          DurationVerification.unknown,
        );
      },
    );
  });

  group('evaluateLivePhotoPair (evaluate_pair port)', () {
    test('duration <= threshold verifies by duration', () {
      expect(
        evaluateLivePhotoPair(
          rawDuration: '2.0',
          stillEpochSeconds: 1000,
          videoEpochSeconds: 5000, // far apart — irrelevant, duration wins
        ),
        PairVerification.verifiedByDuration,
      );
    });

    test(
      'a known-too-long duration is rejected FINALLY — even when the '
      'timestamps are extremely close. This is the safety-critical '
      'regression guard for #60/#61: a known-too-long duration must never '
      'fall through to the timestamp-proximity fallback.',
      () {
        expect(
          evaluateLivePhotoPair(
            rawDuration: '612.0',
            stillEpochSeconds: 1000,
            videoEpochSeconds: 1000, // identical mtimes
          ),
          PairVerification.tooLong,
        );
      },
    );

    test(
      'duration unknown + timestamps within proximity verifies by '
      'timestamp fallback',
      () {
        expect(
          evaluateLivePhotoPair(
            rawDuration: null,
            stillEpochSeconds: 1000,
            videoEpochSeconds: 1003,
          ),
          PairVerification.verifiedByTimestampProximity,
        );
      },
    );

    test(
      'duration unknown + timestamps exactly at the boundary (5s) verifies',
      () {
        expect(
          evaluateLivePhotoPair(
            rawDuration: null,
            stillEpochSeconds: 1000,
            videoEpochSeconds: 1005,
          ),
          PairVerification.verifiedByTimestampProximity,
        );
      },
    );

    test(
      'duration unknown + timestamps just past the boundary (6s) is '
      'ambiguous',
      () {
        expect(
          evaluateLivePhotoPair(
            rawDuration: null,
            stillEpochSeconds: 1000,
            videoEpochSeconds: 1006,
          ),
          PairVerification.ambiguousDurationUnknownAndTimestampsFar,
        );
      },
    );

    test('duration unknown + an mtime unreadable is ambiguous', () {
      expect(
        evaluateLivePhotoPair(
          rawDuration: null,
          stillEpochSeconds: null,
          videoEpochSeconds: 1000,
        ),
        PairVerification.ambiguousDurationUnknownAndTimestampsFar,
      );
    });
  });

  group('trashDestinationPath', () {
    test("mirrors move_or_report_video's rel/dst convention", () {
      expect(
        trashDestinationPath(
          trashRoot: '/mnt/target_drive/media_trash',
          originalPath: '/mnt/target_drive/immich_library/Album/IMG_1.MOV',
        ),
        '/mnt/target_drive/media_trash/mnt/target_drive/immich_library/'
        'Album/IMG_1.MOV',
      );
    });

    test('accepts a trash root with a trailing slash identically', () {
      final withSlash = trashDestinationPath(
        trashRoot: '/mnt/media_trash/',
        originalPath: '/a/b.MOV',
      );
      final withoutSlash = trashDestinationPath(
        trashRoot: '/mnt/media_trash',
        originalPath: '/a/b.MOV',
      );
      expect(withSlash, withoutSlash);
    });
  });

  group('confirmation phrase', () {
    test('kLivePhotoDedupeConfirmPhrase matches the Bash CONFIRM_PHRASE', () {
      expect(kLivePhotoDedupeConfirmPhrase, 'MOVE LIVE PHOTO VIDEOS');
    });

    test('exact phrase is valid', () {
      expect(
        isLivePhotoDedupeConfirmationPhraseValid('MOVE LIVE PHOTO VIDEOS'),
        isTrue,
      );
    });

    test('anything else is invalid (wrong case, trailing space, partial)', () {
      expect(
        isLivePhotoDedupeConfirmationPhraseValid('move live photo videos'),
        isFalse,
      );
      expect(
        isLivePhotoDedupeConfirmationPhraseValid('MOVE LIVE PHOTO VIDEOS '),
        isFalse,
      );
      expect(
        isLivePhotoDedupeConfirmationPhraseValid('MOVE LIVE PHOTO'),
        isFalse,
      );
      expect(isLivePhotoDedupeConfirmationPhraseValid(''), isFalse);
    });
  });

  group('LivePhotoDedupeCleaner.run (async orchestration)', () {
    late Directory tempDir;
    late String targetDir;
    late String trashRoot;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'dedupe_live_photos_test_',
      );
      targetDir = '${tempDir.path}/immich_library';
      trashRoot = '${tempDir.path}/media_trash';
      await Directory(targetDir).create(recursive: true);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('missing target directory returns an all-zero summary', () async {
      final cleaner = LivePhotoDedupeCleaner(
        trashRoot: trashRoot,
        durationReader: (_) async => fail('should not be called'),
      );
      final summary = await cleaner.run(
        targetDir: '${tempDir.path}/does/not/exist',
      );
      expect(summary.inspected, 0);
      expect(summary.verified, 0);
      expect(summary.outcomes, isEmpty);
    });

    test(
      'dry run reports wouldMove for a short verified pair and touches '
      'nothing on disk',
      () async {
        final still = File('$targetDir/IMG_1234.HEIC');
        final video = File('$targetDir/IMG_1234.MOV');
        await still.writeAsBytes('still-bytes'.codeUnits);
        await video.writeAsBytes('video-bytes'.codeUnits);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => '2.000000',
        );
        final summary = await cleaner.run(targetDir: targetDir);

        expect(summary.inspected, 1);
        expect(summary.verified, 1);
        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.wouldMove);
        expect(outcome.videoPath, video.path);
        expect(outcome.stillPath, still.path);
        expect(outcome.reason, 'duration 2.000000s');
        expect(await video.exists(), isTrue);
        expect(await still.exists(), isTrue);
      },
    );

    test(
      'confirm mode moves a verified video to media_trash via SafeFileMover, '
      'keeping the still untouched',
      () async {
        final still = File('$targetDir/IMG_1234.HEIC');
        final video = File('$targetDir/IMG_1234.MOV');
        await still.writeAsBytes('still-bytes'.codeUnits);
        await video.writeAsBytes('video-bytes'.codeUnits);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => '2.000000',
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.moved);
        expect(await still.exists(), isTrue, reason: 'still survives');
        expect(await video.exists(), isFalse, reason: 'video moved');
        expect(await File(outcome.destinationPath!).exists(), isTrue);
      },
    );

    test(
      'a video over the duration threshold is skipped, never moved, even '
      'in confirm mode',
      () async {
        final still = File('$targetDir/IMG_9999.HEIC');
        final video = File('$targetDir/IMG_9999.MOV');
        await still.writeAsBytes('still'.codeUnits);
        await video.writeAsBytes('a real standalone video'.codeUnits);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => '612.000000',
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        expect(summary.skippedTooLong, 1);
        expect(summary.verified, 0);
        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.tooLong);
        expect(await video.exists(), isTrue, reason: 'never moved');
      },
    );

    test(
      'a video with no paired still is skipped and reported missing, '
      'never moved',
      () async {
        final video = File('$targetDir/IMG_5555.MOV');
        await video.writeAsBytes('video-bytes'.codeUnits);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => fail('should not be called'),
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        expect(summary.skippedMissing, 1);
        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.missingStill);
        expect(outcome.stillPath, isNull);
        expect(await video.exists(), isTrue, reason: 'never moved');
      },
    );

    test(
      'duration-unknown pair within timestamp proximity is verified by the '
      'fallback and moved in confirm mode',
      () async {
        final still = File('$targetDir/IMG_0001.HEIC');
        final video = File('$targetDir/IMG_0001.MOV');
        await still.writeAsBytes('still'.codeUnits);
        await video.writeAsBytes('video'.codeUnits);
        final closeTime = DateTime.fromMillisecondsSinceEpoch(
          1800000000 * 1000,
        );
        await still.setLastModified(closeTime);
        await video.setLastModified(closeTime);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => null,
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        expect(summary.skippedDurationUnknown, 1);
        expect(summary.skippedAmbiguous, 0);
        expect(summary.verified, 1);
        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.moved);
        expect(outcome.reason, contains('duration unknown, timestamps'));
        expect(await video.exists(), isFalse);
      },
    );

    test(
      'duration-unknown pair NOT within timestamp proximity is left '
      'ambiguous and never moved',
      () async {
        final still = File('$targetDir/IMG_0002.HEIC');
        final video = File('$targetDir/IMG_0002.MOV');
        await still.writeAsBytes('still'.codeUnits);
        await video.writeAsBytes('video'.codeUnits);
        final baseTime = DateTime.fromMillisecondsSinceEpoch(
          1800000000 * 1000,
        );
        await still.setLastModified(baseTime);
        await video.setLastModified(baseTime.add(const Duration(seconds: 300)));

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => null,
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        expect(summary.skippedDurationUnknown, 1);
        expect(summary.skippedAmbiguous, 1);
        expect(summary.verified, 0);
        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.ambiguous);
        expect(await video.exists(), isTrue, reason: 'never moved');
      },
    );

    test(
      'confirm mode never leaves a verified redundant video un-moved on '
      "collision: a numbered suffix is used instead, matching Bash's "
      'unique_destination()',
      () async {
        final still = File('$targetDir/IMG_1234.HEIC');
        final video = File('$targetDir/IMG_1234.MOV');
        await still.writeAsBytes('still-bytes'.codeUnits);
        await video.writeAsBytes('video-bytes'.codeUnits);

        final dst = trashDestinationPath(
          trashRoot: trashRoot,
          originalPath: video.path,
        );
        await Directory(dst.substring(0, dst.lastIndexOf('/'))).create(
          recursive: true,
        );
        await File(dst).writeAsBytes('already-there'.codeUnits);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => '2.000000',
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.movedWithSuffix);
        // The suffixed destination is `<dst-without-ext>_1<ext>`.
        final expectedSuffixedDst =
            '${dst.substring(0, dst.length - 4)}_1'
            '${dst.substring(dst.length - 4)}';
        expect(outcome.destinationPath, expectedSuffixedDst);
        expect(
          await video.exists(),
          isFalse,
          reason: 'source is always moved, never left in place, matching '
              "Bash's guarantee that a move into the trash always succeeds",
        );
        expect(await File(dst).readAsBytes(), 'already-there'.codeUnits);
        expect(
          await File(expectedSuffixedDst).readAsBytes(),
          'video-bytes'.codeUnits,
        );
      },
    );

    test(
      'pairs in different subdirectories sharing a basename are NOT '
      'cross-matched',
      () async {
        final dirA = Directory('$targetDir/A')..createSync();
        final dirB = Directory('$targetDir/B')..createSync();
        final stillA = File('${dirA.path}/IMG_1.HEIC');
        final videoB = File('${dirB.path}/IMG_1.MOV');
        await stillA.writeAsBytes('still-A'.codeUnits);
        await videoB.writeAsBytes('video-B'.codeUnits);

        final cleaner = LivePhotoDedupeCleaner(
          trashRoot: trashRoot,
          durationReader: (_) async => '2.000000',
        );
        final summary = await cleaner.run(targetDir: targetDir, confirm: true);

        // videoB has no paired still in its own directory (dirB), so it
        // must be reported missing, never matched against stillA in dirA.
        expect(summary.skippedMissing, 1);
        expect(summary.verified, 0);
        final outcome = summary.outcomes.single;
        expect(outcome.action, LivePhotoPairAction.missingStill);
        expect(outcome.videoPath, videoB.path);
        expect(await videoB.exists(), isTrue);
        expect(await stillA.exists(), isTrue);
      },
    );

    test('preserves paths with spaces and unicode characters', () async {
      final still = File('$targetDir/日本語 写真 vacaciones.HEIC');
      final video = File('$targetDir/日本語 写真 vacaciones.MOV');
      await still.writeAsBytes('still'.codeUnits);
      await video.writeAsBytes('video'.codeUnits);

      final cleaner = LivePhotoDedupeCleaner(
        trashRoot: trashRoot,
        durationReader: (_) async => '2.000000',
      );
      final summary = await cleaner.run(targetDir: targetDir, confirm: true);

      final outcome = summary.outcomes.single;
      expect(outcome.action, LivePhotoPairAction.moved);
      expect(await video.exists(), isFalse);
      expect(await File(outcome.destinationPath!).exists(), isTrue);
    });
  });

  group(
    'Bash-vs-Dart parity: LivePhotoDedupeCleaner matches '
    "13_dedupe_live_photos.sh's real dry-run decisions",
    () {
      test(
        'identical verified/skipped decisions for the same synthetic '
        'fixture, using the same fake-ffprobe stubbing protocol as the '
        'Python test suite: a valid short-duration pair, an over-duration '
        'video (rejected), a missing-still case (skipped), a '
        'duration-unknown pair within timestamp proximity (fallback '
        'accepts), and a duration-unknown pair NOT within proximity '
        '(fallback rejects)',
        () async {
          final repoRoot = _findRepoRoot();
          final tempDir = await Directory.systemTemp.createTemp(
            'dedupe_live_photos_parity_test_',
          );
          addTearDown(() async {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          });

          final fakeFfprobe = await _writeFakeFfprobe(tempDir);
          final libDir = '${tempDir.path}/immich_library/Takeout/Album';
          final reportsPath = '${tempDir.path}/reports';
          await Directory(libDir).create(recursive: true);
          await Directory(reportsPath).create(recursive: true);

          // Case 1: a valid short-duration pair — verified by duration.
          final still1 = File('$libDir/IMG_1111.HEIC');
          final video1 = File('$libDir/IMG_1111.MOV');
          await still1.writeAsBytes('still-1'.codeUnits);
          await video1.writeAsString('DURATION=2.000000\n');

          // Case 2: an over-duration video — a real standalone video that
          // happens to share a basename. Must be rejected.
          final still2 = File('$libDir/IMG_2222.HEIC');
          final video2 = File('$libDir/IMG_2222.MOV');
          await still2.writeAsBytes('still-2'.codeUnits);
          await video2.writeAsString('DURATION=612.000000\n');

          // Case 3: a missing-still case — no paired still at all.
          final video3 = File('$libDir/IMG_3333.MOV');
          await video3.writeAsString('DURATION=2.000000\n');

          // Case 4: duration-unknown, timestamps close — fallback accepts.
          final still4 = File('$libDir/IMG_4444.HEIC');
          final video4 = File('$libDir/IMG_4444.MOV');
          await still4.writeAsBytes('still-4'.codeUnits);
          await video4.writeAsString('UNKNOWN\n');
          final closeTime = DateTime.fromMillisecondsSinceEpoch(
            1800000000 * 1000,
          );
          await still4.setLastModified(closeTime);
          await video4.setLastModified(closeTime);

          // Case 5: duration-unknown, timestamps far apart — fallback
          // rejects.
          final still5 = File('$libDir/IMG_5555.HEIC');
          final video5 = File('$libDir/IMG_5555.MOV');
          await still5.writeAsBytes('still-5'.codeUnits);
          await video5.writeAsString('UNKNOWN\n');
          await still5.setLastModified(closeTime);
          await video5.setLastModified(
            closeTime.add(const Duration(seconds: 300)),
          );

          // Run the real Bash script in dry-run mode against this fixture.
          final result = await Process.run('bash', [
            '${repoRoot.path}/scripts/13_dedupe_live_photos.sh',
          ], environment: {
            ...Platform.environment,
            'HD_PATH': tempDir.path,
            'REPORT_DIR': reportsPath,
            'FFPROBE_BIN': fakeFfprobe.path,
          }, stdoutEncoding: utf8, stderrEncoding: utf8);
          expect(result.exitCode, 0, reason: result.stderr as String);
          final bashStdout = result.stdout as String;

          expect(
            bashStdout,
            contains(
              'Would move standalone Live Photo video (duration '
              '2.000000s): ${video1.path}',
            ),
          );
          expect(
            bashStdout,
            contains(
              'Video too long (612.000000s > 5s), skipping: ${video2.path}',
            ),
          );
          expect(
            bashStdout,
            contains('No paired still for video, skipping: ${video3.path}'),
          );
          expect(
            bashStdout,
            contains(
              'Would move standalone Live Photo video (duration unknown, '
              'timestamps 0s apart): ${video4.path}',
            ),
          );
          expect(
            bashStdout,
            contains(
              'Duration unknown and timestamps not close enough, skipping: '
              '${video5.path}',
            ),
          );
          expect(bashStdout, contains('Candidates inspected:     5'));
          expect(bashStdout, contains('Verified pairs:           2'));
          expect(bashStdout, contains('Missing paired still:     1'));
          expect(bashStdout, contains('Video too long:           1'));
          expect(bashStdout, contains('Duration unknown (total): 2'));
          expect(bashStdout, contains('Skipped, ambiguous match: 1'));

          // Independently compute the Dart port's decision for the exact
          // same fixture, using the same fake ffprobe binary via the
          // overridable VideoDurationReader seam.
          final cleaner = LivePhotoDedupeCleaner(
            trashRoot: '${tempDir.path}/media_trash',
            durationReader: ffprobeDurationReader(
              ffprobeBin: fakeFfprobe.path,
            ),
          );
          final summary = await cleaner.run(
            targetDir: '${tempDir.path}/immich_library',
          );

          expect(summary.inspected, 5);
          expect(summary.verified, 2);
          expect(summary.skippedMissing, 1);
          expect(summary.skippedTooLong, 1);
          expect(summary.skippedDurationUnknown, 2);
          expect(summary.skippedAmbiguous, 1);

          final byVideoPath = {
            for (final o in summary.outcomes) o.videoPath: o,
          };

          expect(
            byVideoPath[video1.path]!.action,
            LivePhotoPairAction.wouldMove,
          );
          expect(byVideoPath[video2.path]!.action, LivePhotoPairAction.tooLong);
          expect(
            byVideoPath[video3.path]!.action,
            LivePhotoPairAction.missingStill,
          );
          expect(
            byVideoPath[video4.path]!.action,
            LivePhotoPairAction.wouldMove,
          );
          expect(
            byVideoPath[video5.path]!.action,
            LivePhotoPairAction.ambiguous,
          );
        },
        skip: !Platform.isLinux && !Platform.isMacOS,
      );
    },
  );
}

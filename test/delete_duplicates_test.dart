import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/delete_duplicates.dart';
import 'package:media_pipeline_app/src/duplicate_report.dart';

/// Finds the repo root by walking up from this test file's directory until
/// `scripts/06_delete_duplicates.sh` is found. Mirrors the `ROOT =
/// Path(__file__).resolve().parents[1]` convention `tests/test_shell_scripts
/// .py` uses for the same script, so the Bash-vs-Dart parity test below runs
/// the exact same file the Python suite already covers.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/scripts/06_delete_duplicates.sh').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current}');
}

void main() {
  group('scoreKeepPath (score_keep_path port)', () {
    test('scores a clean Google Photos year folder as 0 (most preferred)', () {
      expect(
        scoreKeepPath(
          '/mnt/target_drive/immich_library/Takeout/Google Fotos/2024/'
          'IMG_0001.HEIC',
        ),
        0,
      );
    });

    test('scores a localized "Fotos de YYYY" folder as 10', () {
      expect(
        scoreKeepPath(
          '/mnt/target_drive/immich_library/Takeout/Google Fotos/'
          'Fotos de 2024/IMG_0001.HEIC',
        ),
        10,
      );
    });

    test('scores any other Google Fotos path as 12', () {
      expect(
        scoreKeepPath(
          '/mnt/target_drive/immich_library/Takeout/Google Fotos/'
          'misc/IMG_0001.HEIC',
        ),
        12,
      );
    });

    test('scores a cleaning_staging/Fotos path as 20', () {
      expect(
        scoreKeepPath('/mnt/target_drive/cleaning_staging/Fotos/a.jpg'),
        20,
      );
    });

    test('scores an unrelated path as 5', () {
      expect(scoreKeepPath('/mnt/target_drive/cleaning_staging/a.jpg'), 5);
    });

    test('orders scores canonical < plain-staging < localized < '
        'other-google-fotos < staging-fotos', () {
      final canonical = scoreKeepPath(
        '/mnt/target_drive/immich_library/Takeout/Google Fotos/2024/a.jpg',
      );
      final plainStaging = scoreKeepPath(
        '/mnt/target_drive/cleaning_staging/a.jpg',
      );
      final localized = scoreKeepPath(
        '/mnt/target_drive/immich_library/Takeout/Google Fotos/'
        'Fotos de 2024/a.jpg',
      );
      final otherGoogleFotos = scoreKeepPath(
        '/mnt/target_drive/immich_library/Takeout/Google Fotos/misc/a.jpg',
      );
      final stagingFotos = scoreKeepPath(
        '/mnt/target_drive/cleaning_staging/Fotos/a.jpg',
      );
      // Mirrors the Bash script's literal scores (0/5/10/12/20) exactly —
      // note a plain staging path (5) actually outranks both Google-Fotos
      // variants that AREN'T the canonical year folder, which is
      // counter-intuitive but matches `score_keep_path`'s real values.
      expect(canonical, lessThan(plainStaging));
      expect(plainStaging, lessThan(localized));
      expect(localized, lessThan(otherGoogleFotos));
      expect(otherGoogleFotos, lessThan(stagingFotos));
    });
  });

  group('decideCzkawkaReportGroups (process_czkawka_report port)', () {
    const stagingRoot = '/mnt/target_drive/cleaning_staging';

    test('picks the lowest-scoring path in a group as keep, trashes the '
        'rest', () {
      final report =
          '"$stagingRoot/Fotos/a.jpg" - 10 KiB\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      // "$stagingRoot/Fotos/a.jpg" scores 20 (cleaning_staging/Fotos/),
      // "$stagingRoot/b.jpg" scores 5 (no special pattern matches) -> the
      // plain path wins even though it appeared second.
      expect(decisions.single.keepPath, '$stagingRoot/b.jpg');
      expect(decisions.single.trashPaths, ['$stagingRoot/Fotos/a.jpg']);
    });

    test('a quoted path outside stagingRoot is never added to the group, '
        'even if a real group later forms from other lines', () {
      final report =
          '"/mnt/target_drive/immich_library/Takeout/Google Fotos/2024/'
          'a.jpg" - 10 KiB\n'
          '"$stagingRoot/a_copy.jpg" - 10 KiB\n'
          '"$stagingRoot/a_copy2.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      // Only the two staging-rooted paths are ever grouped; the
      // Google-Fotos path (not under stagingRoot) is excluded entirely.
      expect(decisions, hasLength(1));
      final allPaths = [
        decisions.single.keepPath,
        ...decisions.single.trashPaths,
      ];
      expect(allPaths, hasLength(2));
      expect(
        allPaths,
        isNot(
          contains(
            '/mnt/target_drive/immich_library/Takeout/Google Fotos/2024/'
            'a.jpg',
          ),
        ),
      );
    });

    test('never treats a bare "Found N files" header as a path', () {
      final report =
          'Found 2 files which are duplicates\n'
          '"$stagingRoot/a.jpg" - 10 KiB\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      expect(decisions.single.keepPath, '$stagingRoot/a.jpg');
      expect(decisions.single.trashPaths, ['$stagingRoot/b.jpg']);
    });

    test('never treats an unquoted dimension line (e.g. "1920x1080") as a '
        'path', () {
      final report =
          '"$stagingRoot/a.jpg" - 10 KiB\n'
          '1920x1080\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      expect(decisions.single.trashPaths, ['$stagingRoot/b.jpg']);
    });

    test('never treats an unquoted size annotation line as a path', () {
      final report =
          '"$stagingRoot/a.jpg" - 10 KiB\n'
          'Size: 10485760 bytes (10 MiB)\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      expect(decisions.single.trashPaths, ['$stagingRoot/b.jpg']);
    });

    test('a quoted header/label line is still never a path if it is not '
        'under stagingRoot', () {
      final report =
          '"Results" - header that must not be parsed\n'
          '"$stagingRoot/a.jpg" - 10 KiB\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      expect(decisions.single.keepPath, '$stagingRoot/a.jpg');
      expect(decisions.single.trashPaths, ['$stagingRoot/b.jpg']);
    });

    test('a quoted path outside stagingRoot is excluded from the group, '
        'never trashed', () {
      final report =
          '"$stagingRoot/a.jpg" - 10 KiB\n'
          '"/outside/staging.jpg" - must be ignored\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      expect(decisions.single.trashPaths, ['$stagingRoot/b.jpg']);
      expect(
        decisions.expand((d) => [d.keepPath, ...d.trashPaths]),
        isNot(contains('/outside/staging.jpg')),
      );
    });

    test('a group of a single member produces no decision (nothing to '
        'deduplicate)', () {
      final report = '"$stagingRoot/a.jpg" - 10 KiB\n\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, isEmpty);
    });

    test('a "Found " header line flushes the current group, keeping later '
        'groups independent', () {
      final report =
          '"$stagingRoot/a.jpg" - 10 KiB\n'
          '"$stagingRoot/b.jpg" - 10 KiB\n'
          'Found 2 files which are duplicates\n'
          '"$stagingRoot/c.jpg" - 10 KiB\n'
          '"$stagingRoot/d.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(2));
      expect(decisions[0].keepPath, '$stagingRoot/a.jpg');
      expect(decisions[1].keepPath, '$stagingRoot/c.jpg');
    });

    test('multiple groups separated by blank lines stay independent', () {
      final report =
          '"$stagingRoot/groupA/keep.jpg" - 10 KiB\n'
          '"$stagingRoot/groupA/trash.jpg" - 10 KiB\n'
          '\n'
          '"$stagingRoot/groupB/keep.jpg" - 10 KiB\n'
          '"$stagingRoot/groupB/trash.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(2));
      expect(decisions[0].keepPath, '$stagingRoot/groupA/keep.jpg');
      expect(decisions[1].keepPath, '$stagingRoot/groupB/keep.jpg');
    });

    test('handles a final line with no trailing newline', () {
      final report =
          '"$stagingRoot/a.jpg" - 10 KiB\n"$stagingRoot/b.jpg" - 10 KiB';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      expect(decisions.single.trashPaths, ['$stagingRoot/b.jpg']);
    });

    test('preserves paths with spaces and unicode characters', () {
      final report =
          '"$stagingRoot/Fotos de 2024/foto vacaciones.jpg" - 10 KiB\n'
          '"$stagingRoot/日本語/写真_①.jpg" - 10 KiB\n'
          '\n';
      final decisions = decideCzkawkaReportGroups(
        report,
        stagingRoot: stagingRoot,
      );
      expect(decisions, hasLength(1));
      final allPaths = [
        decisions.single.keepPath,
        ...decisions.single.trashPaths,
      ];
      expect(
        allPaths,
        unorderedEquals([
          '$stagingRoot/Fotos de 2024/foto vacaciones.jpg',
          '$stagingRoot/日本語/写真_①.jpg',
        ]),
      );
    });

    test('empty report content produces no decisions', () {
      expect(decideCzkawkaReportGroups('', stagingRoot: stagingRoot), isEmpty);
    });
  });

  group('trashDestinationPath', () {
    test("mirrors trash_file's rel/dst convention", () {
      expect(
        trashDestinationPath(
          trashRoot: '/mnt/target_drive/media_trash',
          originalPath: '/mnt/target_drive/cleaning_staging/a.jpg',
        ),
        '/mnt/target_drive/media_trash/mnt/target_drive/cleaning_staging/'
        'a.jpg',
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

  group('DuplicateDeleter.run (async orchestration)', () {
    late Directory tempDir;
    late String stagingRoot;
    late String trashRoot;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'delete_duplicates_test_',
      );
      stagingRoot = '${tempDir.path}/cleaning_staging';
      trashRoot = '${tempDir.path}/media_trash';
      await Directory(stagingRoot).create(recursive: true);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<String> writeReport(String name, String content) async {
      final reportDir = Directory('${tempDir.path}/reports');
      await reportDir.create(recursive: true);
      final file = File('${reportDir.path}/$name');
      await file.writeAsString(content);
      return file.path;
    }

    test('dry run reports wouldTrash and touches nothing on disk', () async {
      final a = File('$stagingRoot/a.jpg');
      final b = File('$stagingRoot/b.jpg');
      await a.writeAsString('first');
      await b.writeAsString('second');

      final reportPath = await writeReport(
        'duplicate_files.txt',
        '"${a.path}" - 10 KiB\n"${b.path}" - 10 KiB\n\n',
      );

      final deleter = DuplicateDeleter(
        stagingRoot: stagingRoot,
        trashRoot: trashRoot,
      );
      final results = await deleter.run(reportPaths: [reportPath]);

      expect(results, hasLength(1));
      expect(results.single.found, isTrue);
      expect(results.single.groups, hasLength(1));
      final group = results.single.groups.single;
      expect(group.keepPath, a.path);
      expect(
        group.trashOutcomes.single.action,
        DuplicateFileAction.wouldTrash,
      );
      expect(await a.exists(), isTrue);
      expect(await b.exists(), isTrue);
    });

    test(
      'confirm mode moves the non-kept file to media_trash via '
      'SafeFileMover',
      () async {
        final a = File('$stagingRoot/a.jpg');
        final b = File('$stagingRoot/b.jpg');
        await a.writeAsString('first');
        await b.writeAsString('second');

        final reportPath = await writeReport(
          'duplicate_files.txt',
          '"${a.path}" - 10 KiB\n"${b.path}" - 10 KiB\n\n',
        );

        final deleter = DuplicateDeleter(
          stagingRoot: stagingRoot,
          trashRoot: trashRoot,
        );
        final results = await deleter.run(
          reportPaths: [reportPath],
          confirm: true,
        );

        final outcome = results.single.groups.single.trashOutcomes.single;
        expect(outcome.action, DuplicateFileAction.trashed);
        expect(await a.exists(), isTrue, reason: 'kept file must survive');
        expect(
          await b.exists(),
          isFalse,
          reason: 'trashed file must be moved',
        );
        expect(await File(outcome.destinationPath!).exists(), isTrue);
      },
    );

    test('a missing report file is not an error; found is false', () async {
      final deleter = DuplicateDeleter(
        stagingRoot: stagingRoot,
        trashRoot: trashRoot,
      );
      final results = await deleter.run(
        reportPaths: ['${tempDir.path}/reports/missing.txt'],
      );
      expect(results.single.found, isFalse);
      expect(results.single.groups, isEmpty);
    });

    test(
      'a group member missing from disk is reported as missing, not '
      'moved',
      () async {
        final a = File('$stagingRoot/a.jpg');
        await a.writeAsString('first');
        final missingPath = '$stagingRoot/gone.jpg';

        final reportPath = await writeReport(
          'duplicate_files.txt',
          '"${a.path}" - 10 KiB\n"$missingPath" - 10 KiB\n\n',
        );

        final deleter = DuplicateDeleter(
          stagingRoot: stagingRoot,
          trashRoot: trashRoot,
        );
        final results = await deleter.run(
          reportPaths: [reportPath],
          confirm: true,
        );

        final group = results.single.groups.single;
        // Both paths score 5 (no special pattern matches); ties keep the
        // first-encountered path, so `a.jpg` (listed first) is kept.
        expect(group.keepPath, a.path);
        expect(
          group.trashOutcomes.single.action,
          DuplicateFileAction.missing,
        );
      },
    );

    test(
      'confirm mode never clobbers an existing destination '
      '(mv -n semantics)',
      () async {
        final a = File('$stagingRoot/a.jpg');
        final b = File('$stagingRoot/b.jpg');
        await a.writeAsString('first');
        await b.writeAsString('second');

        final dst = trashDestinationPath(
          trashRoot: trashRoot,
          originalPath: b.path,
        );
        await Directory(
          dst.substring(0, dst.lastIndexOf('/')),
        ).create(recursive: true);
        await File(dst).writeAsString('already-there');

        final reportPath = await writeReport(
          'duplicate_files.txt',
          '"${a.path}" - 10 KiB\n"${b.path}" - 10 KiB\n\n',
        );

        final deleter = DuplicateDeleter(
          stagingRoot: stagingRoot,
          trashRoot: trashRoot,
        );
        final results = await deleter.run(
          reportPaths: [reportPath],
          confirm: true,
        );

        final outcome = results.single.groups.single.trashOutcomes.single;
        expect(outcome.action, DuplicateFileAction.skippedExisting);
        expect(await b.exists(), isTrue, reason: 'source stays put on skip');
        expect(await File(dst).readAsString(), 'already-there');
      },
    );
  });

  group('renderDryRunKeepTrashLines <-> duplicate_report.dart round trip', () {
    test(
      'a rendered dry-run outcome parses back into identical '
      'keep/trash pairs via parseDuplicateDryRunOutput',
      () {
        const outcome = DuplicateGroupOutcome(
          keepPath: '/mnt/target_drive/cleaning_staging/keep.jpg',
          trashOutcomes: [
            DuplicateFileOutcome(
              path: '/mnt/target_drive/cleaning_staging/dup1.jpg',
              action: DuplicateFileAction.wouldTrash,
              destinationPath: '/mnt/target_drive/media_trash/dup1.jpg',
            ),
            DuplicateFileOutcome(
              path: '/mnt/target_drive/cleaning_staging/dup2.jpg',
              action: DuplicateFileAction.wouldTrash,
              destinationPath: '/mnt/target_drive/media_trash/dup2.jpg',
            ),
          ],
        );

        final rendered = renderDryRunKeepTrashLines([outcome]);
        final parsed = parseDuplicateDryRunOutput(rendered);

        expect(parsed.pairs, [
          const DuplicateReviewPair(
            keepPath: '/mnt/target_drive/cleaning_staging/keep.jpg',
            trashPath: '/mnt/target_drive/cleaning_staging/dup1.jpg',
          ),
          const DuplicateReviewPair(
            keepPath: '/mnt/target_drive/cleaning_staging/keep.jpg',
            trashPath: '/mnt/target_drive/cleaning_staging/dup2.jpg',
          ),
        ]);
        expect(parsed.orphanTrashLineCount, 0);
      },
    );

    test(
      'a non-wouldTrash outcome (e.g. missing) is never rendered as a '
      '"Would trash:" line',
      () {
        const outcome = DuplicateGroupOutcome(
          keepPath: '/staging/keep.jpg',
          trashOutcomes: [
            DuplicateFileOutcome(
              path: '/staging/gone.jpg',
              action: DuplicateFileAction.missing,
            ),
          ],
        );
        final rendered = renderDryRunKeepTrashLines([outcome]);
        expect(rendered, isNot(contains('Would trash:')));
      },
    );
  });

  group(
    'Bash-vs-Dart parity: decideCzkawkaReportGroups matches '
    "06_delete_duplicates.sh's real dry-run decisions",
    () {
      test(
        'identical Keep/Would-trash decisions for the same synthetic '
        'Czkawka report fixture',
        () async {
          final repoRoot = _findRepoRoot();
          final tempDir = await Directory.systemTemp.createTemp(
            'delete_duplicates_parity_test_',
          );
          addTearDown(() async {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          });

          final stagingPath = '${tempDir.path}/cleaning_staging';
          final reportsPath = '${tempDir.path}/reports';
          await Directory(stagingPath).create(recursive: true);
          await Directory(reportsPath).create(recursive: true);

          // A fixture deliberately shaped like the adversarial cases above:
          // a report header, an unquoted dimension-ish line, a quoted
          // out-of-staging path, and a real multi-file duplicate group —
          // real files on disk are required so the Bash script's own
          // `[[ -f "$src" ]]` / trash_file checks behave identically to the
          // Dart port's.
          final canonicalDirPath =
              '${tempDir.path}/immich_library/Takeout/Google Fotos/2024';
          await Directory(canonicalDirPath).create(recursive: true);
          final canonical = File('$canonicalDirPath/a.jpg');
          final stagingCopy = File('$stagingPath/a_copy.jpg');
          await Directory('$stagingPath/Fotos').create(recursive: true);
          final stagingFotosCopy = File('$stagingPath/Fotos/a_copy2.jpg');
          await canonical.writeAsString('same-bytes');
          await stagingCopy.writeAsString('same-bytes');
          await stagingFotosCopy.writeAsString('same-bytes');

          final reportContent =
              'Found 3 files which are duplicates\n'
              '"Results" - header that must not be parsed\n'
              '"${canonical.path}" - 10 KiB\n'
              '1920x1080\n'
              '"${stagingCopy.path}" - 10 KiB\n'
              '"/outside/should-be-ignored.jpg" - must be ignored\n'
              '"${stagingFotosCopy.path}" - 10 KiB\n'
              '\n';
          await File(
            '$reportsPath/duplicate_files.txt',
          ).writeAsString(reportContent);

          // Run the real Bash script in dry-run mode against this fixture.
          final result = await Process.run(
            'bash',
            ['${repoRoot.path}/scripts/06_delete_duplicates.sh'],
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

          // The Bash script only ever groups quoted paths under its own
          // $CLEANING_STAGING (== stagingPath here); the canonical Google
          // Fotos path is NOT under staging, so — exactly like the Dart
          // port — it is excluded from the group entirely, leaving only
          // the two staging copies to compare against each other.
          final bashKeepLines = bashStdout
              .split('\n')
              .where((l) => l.startsWith('Keep: '))
              .toList();
          final bashTrashLines = bashStdout
              .split('\n')
              .where((l) => l.startsWith('Would trash: '))
              .toList();

          // Independently compute the Dart port's decision for the exact
          // same report content and staging root.
          final dartDecisions = decideCzkawkaReportGroups(
            reportContent,
            stagingRoot: stagingPath,
          );

          expect(dartDecisions, hasLength(1));
          expect(bashKeepLines, hasLength(1));
          expect(bashTrashLines, hasLength(1));

          expect(
            bashKeepLines.single,
            'Keep: ${dartDecisions.single.keepPath}',
            reason: 'Bash and Dart must agree on which file is kept',
          );
          expect(
            bashTrashLines.single,
            'Would trash: ${dartDecisions.single.trashPaths.single}',
            reason: 'Bash and Dart must agree on which file is trashed',
          );

          // Also verify neither implementation ever mistakes the header,
          // dimension line, or out-of-staging quoted path for a real path.
          expect(bashStdout, isNot(contains('Would trash: Results')));
          expect(bashStdout, isNot(contains('Would trash: 1920x1080')));
          expect(
            bashStdout,
            isNot(contains('Would trash: /outside/should-be-ignored.jpg')),
          );
          final dartAllPaths = dartDecisions.expand(
            (d) => [d.keepPath, ...d.trashPaths],
          );
          expect(dartAllPaths, isNot(contains('Results')));
          expect(dartAllPaths, isNot(contains('1920x1080')));
          expect(
            dartAllPaths,
            isNot(contains('/outside/should-be-ignored.jpg')),
          );
        },
        skip: !Platform.isLinux && !Platform.isMacOS,
      );
    },
  );
}

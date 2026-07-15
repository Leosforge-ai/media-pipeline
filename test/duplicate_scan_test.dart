import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/duplicate_scan.dart';
import 'package:media_pipeline_app/src/tools_container.dart';

/// Finds the repo root by walking up from this test file's directory until
/// `scripts/05_cleanup_scan.sh` is found. Mirrors
/// `test/delete_duplicates_test.dart`'s `_findRepoRoot` convention exactly.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/scripts/05_cleanup_scan.sh').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current}');
}

/// Mirrors `test/pipeline_step_actions_test.dart`'s own
/// `_dockerAvailable`/`_toolsImageAvailable` exactly (duplicated per this
/// repo's existing precedent of mirroring, not importing, between test
/// files).
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
const String _dockerSkipReason =
    'Docker or the media-pipeline-tools:local image is not available in '
    'this environment (build it per docker/tools/README.md).';

/// Extracts the real `czkawka_cli` binary baked into the
/// `media-pipeline-tools:local` image onto the host filesystem (via `docker
/// create` + `docker cp`, never `docker run`) so the Bash-vs-Dart parity
/// tests below can run the exact same binary [ToolsContainer] execs into,
/// natively on the host, for the Bash side of the comparison — no
/// separately-installed host `czkawka_cli` is assumed to exist (and
/// normally does not in this repo's CI/dev environments; only the
/// container-bundled copy is guaranteed present).
Future<File> _extractRealCzkawkaCliBinary(Directory destDir) async {
  final createResult = await Process.run('docker', [
    'create',
    kDefaultToolsImage,
  ]);
  expect(createResult.exitCode, 0, reason: createResult.stderr as String);
  final containerId = (createResult.stdout as String).trim();
  try {
    final destPath = '${destDir.path}/czkawka_cli';
    final cpResult = await Process.run('docker', [
      'cp',
      '$containerId:/usr/local/bin/czkawka_cli',
      destPath,
    ]);
    expect(cpResult.exitCode, 0, reason: cpResult.stderr as String);
    await Process.run('chmod', ['+x', destPath]);
    return File(destPath);
  } finally {
    await Process.run('docker', ['rm', '-f', containerId]);
  }
}

void main() {
  group('isCzkawkaScanExitFatal (pure classification)', () {
    test('0 (nothing found) is not fatal', () {
      expect(isCzkawkaScanExitFatal(0), isFalse);
    });

    test(
      '11 (czkawka\'s fixed found-duplicates sentinel) is not fatal',
      () {
        expect(isCzkawkaScanExitFatal(11), isFalse);
      },
    );

    // 101: uncaught Rust panic. 126/127: exec errors. 137/139: signal
    // deaths (128+N — SIGKILL/OOM-kill, SIGSEGV). 55: an arbitrary other
    // non-zero code with no special meaning, proving this is a denylist of
    // known-safe codes, not an allowlist of known-fatal ones.
    for (final code in [101, 126, 127, 137, 139, 55]) {
      test('$code is fatal', () {
        expect(isCzkawkaScanExitFatal(code), isTrue);
      });
    }
  });

  group(
    'isCzkawkaScanExitFatal parity with the real 05_cleanup_scan.sh '
    '(issue #81/#83)',
    () {
      // Exactly the code set issue #81/#83's own Python test suite
      // (tests/test_shell_scripts.py::CleanupScanExitCodeTests) covered
      // for the Bash fix, now proven to match this Dart port's own
      // classification directly — not just re-tested against the Bash
      // script in isolation. For each code, a fake `czkawka_cli` that
      // unconditionally exits that code is put on PATH, and the real,
      // untouched `05_cleanup_scan.sh` is run against it: the script
      // either aborts (fatal) or reaches its summary section (non-fatal).
      // That real, observed Bash behavior must agree exactly with
      // [isCzkawkaScanExitFatal]'s own verdict for the same code.
      for (final code in [0, 11, 101, 126, 127, 137, 139, 55]) {
        test('exit code $code: Bash abort/continue matches Dart', () async {
          final repoRoot = _findRepoRoot();
          final root = await Directory.systemTemp.createTemp(
            'cleanup-scan-exit-parity-',
          );
          addTearDown(() async {
            if (await root.exists()) await root.delete(recursive: true);
          });

          final staging = Directory('${root.path}/cleaning_staging');
          await staging.create(recursive: true);
          await File('${staging.path}/a.jpg').writeAsBytes([1, 2, 3]);

          final fakeBin = Directory('${root.path}/fakebin');
          await fakeBin.create();
          final czkawka = File('${fakeBin.path}/czkawka_cli');
          await czkawka.writeAsString('#!/usr/bin/env bash\nexit $code\n');
          await Process.run('chmod', ['+x', czkawka.path]);
          for (final tool in ['ffmpeg', 'ffprobe', 'convert']) {
            final stub = File('${fakeBin.path}/$tool');
            await stub.writeAsString('#!/usr/bin/env bash\nexit 0\n');
            await Process.run('chmod', ['+x', stub.path]);
          }

          final result = await Process.run(
            'bash',
            ['${repoRoot.path}/scripts/05_cleanup_scan.sh'],
            environment: {
              ...Platform.environment,
              'PATH': '${fakeBin.path}:${Platform.environment['PATH']}',
              'HD_PATH': root.path,
              'REPORT_DIR': '${root.path}/reports',
              'RUN_BLUR_SCAN': '0',
            },
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );

          final bashAborted = result.exitCode != 0;
          expect(
            bashAborted,
            isCzkawkaScanExitFatal(code),
            reason:
                'Bash script exited ${result.exitCode} for a stub '
                'czkawka_cli exit code of $code.\nstdout: '
                '${result.stdout}\nstderr: ${result.stderr}',
          );
          if (bashAborted) {
            expect(result.stdout, isNot(contains('==> Summary')));
          } else {
            expect(result.stdout, contains('==> Summary'));
          }
        });
      }
    },
    skip: Platform.isWindows ? 'Requires bash.' : false,
  );

  group(
    'runSingleCzkawkaScan / DuplicateScanRunner error handling '
    '(fake ToolsContainer, no real Docker needed)',
    () {
      test(
        'throws CzkawkaScanFailedException on a fatal exit code, without '
        'ever treating it as found-duplicates',
        () async {
          final container = ToolsContainer(
            hostMountRoot: '/mnt/target_drive',
            runner: (args) async {
              if (args.first == 'run') {
                return ProcessResult(0, 0, 'fakecontainerid\n', '');
              }
              if (args.first == 'exec') {
                return ProcessResult(0, 101, '', 'simulated Rust panic');
              }
              return ProcessResult(0, 0, '', '');
            },
          );
          await container.start();
          addTearDown(container.stop);

          final logLines = <String>[];
          await expectLater(
            runSingleCzkawkaScan(
              container: container,
              kind: CzkawkaScanKind.dup,
              stagingContainerPath: '/data/cleaning_staging',
              reportContainerPath: '/data/.duplicate_scan_tmp/dup.txt',
              homeContainerPath: '/data/.duplicate_scan_tmp',
              onLog: logLines.add,
            ),
            throwsA(
              isA<CzkawkaScanFailedException>()
                  .having((e) => e.exitCode, 'exitCode', 101)
                  .having((e) => e.kind, 'kind', CzkawkaScanKind.dup),
            ),
          );
          // The "before" progress line was still emitted; no false "no
          // duplicates"/"found duplicates" result line was ever printed
          // for a genuine crash.
          expect(logLines, ['==> Running Czkawka exact duplicate file scan']);
        },
      );

      test(
        'passes env HOME=<homeContainerPath> ahead of czkawka_cli — the '
        'discovered fix for the arbitrary-host-uid cache-write panic',
        () async {
          List<String>? capturedExecArgs;
          final container = ToolsContainer(
            hostMountRoot: '/mnt/target_drive',
            runner: (args) async {
              if (args.first == 'run') {
                return ProcessResult(0, 0, 'fakecontainerid\n', '');
              }
              if (args.first == 'exec') {
                capturedExecArgs = args;
                return ProcessResult(0, 0, '', '');
              }
              return ProcessResult(0, 0, '', '');
            },
          );
          await container.start();
          addTearDown(container.stop);

          await runSingleCzkawkaScan(
            container: container,
            kind: CzkawkaScanKind.image,
            stagingContainerPath: '/data/cleaning_staging',
            reportContainerPath: '/data/.duplicate_scan_tmp/images.txt',
            homeContainerPath: '/data/.duplicate_scan_tmp',
          );

          expect(capturedExecArgs, isNotNull);
          expect(
            capturedExecArgs,
            containsAllInOrder([
              'env',
              'HOME=/data/.duplicate_scan_tmp',
              'czkawka_cli',
              'image',
              '-d',
              '/data/cleaning_staging',
              '-f',
              '/data/.duplicate_scan_tmp/images.txt',
            ]),
          );
        },
      );

      test(
        'DuplicateScanRunner.run throws CleaningStagingNotFoundException '
        'without ever calling into the container, when the staging '
        r"directory ($CLEANING_STAGING) doesn't exist",
        () async {
          var execCalled = false;
          final container = ToolsContainer(
            hostMountRoot: '/mnt/target_drive',
            runner: (args) async {
              if (args.first == 'exec') execCalled = true;
              return ProcessResult(0, 0, 'fakecontainerid\n', '');
            },
          );
          await container.start();
          addTearDown(container.stop);

          final root = await Directory.systemTemp.createTemp(
            'duplicate-scan-missing-staging-',
          );
          addTearDown(() async {
            if (await root.exists()) await root.delete(recursive: true);
          });

          const runner = DuplicateScanRunner();
          await expectLater(
            runner.run(
              stagingDir: '${root.path}/cleaning_staging',
              reportDir: '${root.path}/reports',
              container: container,
            ),
            throwsA(isA<CleaningStagingNotFoundException>()),
          );
          expect(execCalled, isFalse);
        },
      );
    },
  );

  group(
    'DuplicateScanRunner.run end-to-end, cross-checked against the real '
    '05_cleanup_scan.sh (real Docker + real czkawka_cli, identical fixtures)',
    () {
      test(
        'a real byte-identical duplicate pair is found by both the Dart '
        'port (via a real ToolsContainer) and the real Bash script (via '
        'the exact same czkawka_cli binary, extracted from the image and '
        'run natively on the host)',
        () async {
          final repoRoot = _findRepoRoot();
          final dartRoot = await Directory.systemTemp.createTemp(
            'duplicate_scan_parity_dart_',
          );
          final bashRoot = await Directory.systemTemp.createTemp(
            'duplicate_scan_parity_bash_',
          );
          final binDir = await Directory.systemTemp.createTemp(
            'duplicate_scan_parity_bin_',
          );
          addTearDown(() async {
            for (final dir in [dartRoot, bashRoot, binDir]) {
              if (await dir.exists()) {
                await dir.delete(recursive: true);
              }
            }
          });

          Future<void> seedFixture(Directory root) async {
            final staging = Directory('${root.path}/cleaning_staging');
            await staging.create(recursive: true);
            // `czkawka_cli dup`'s own default `--minimal-file-size` is 8192
            // bytes (files smaller than that are skipped entirely,
            // documented in docker/tools/README.md's "Debugging" section) —
            // padded well past that so this fixture is actually scanned.
            final bytes = List<int>.generate(20000, (i) => i % 256);
            await File('${staging.path}/a.jpg').writeAsBytes(bytes);
            await File('${staging.path}/b.jpg').writeAsBytes(bytes);
            await File(
              '${staging.path}/unique.txt',
            ).writeAsBytes(List<int>.generate(9000, (i) => (i * 7) % 256));
          }

          await seedFixture(dartRoot);
          await seedFixture(bashRoot);

          // --- Dart side: real ToolsContainer, real czkawka_cli inside it.
          const dartRunner = DuplicateScanRunner();
          final dartLogLines = <String>[];
          final dartSummary = await ToolsContainer.withSession(
            hostMountRoot: dartRoot.path,
            body: (container) => dartRunner.run(
              stagingDir: '${dartRoot.path}/cleaning_staging',
              reportDir: '${dartRoot.path}/reports',
              container: container,
              onLog: dartLogLines.add,
            ),
          );

          expect(dartSummary.duplicateFileGroups, 1);
          expect(dartSummary.imageGroups, 0);
          expect(dartSummary.videoGroups, 0);
          final dartReportContent = await File(
            dartSummary.duplicateFilesReportPath,
          ).readAsString();
          expect(dartReportContent, contains('a.jpg'));
          expect(dartReportContent, contains('b.jpg'));
          expect(
            dartLogLines.join(),
            contains('exact duplicate file scan: completed, duplicates '
                'found'),
          );
          // The hidden temp staging dir is cleaned up afterward.
          expect(
            await Directory(
              '${dartRoot.path}/$kDuplicateScanTempDirName',
            ).exists(),
            isFalse,
          );

          // --- Bash side: the real, untouched script, driven with the
          // exact same czkawka_cli binary the container runs (extracted
          // from the image, run natively on the host) — never a fake/stub.
          final realCzkawka = await _extractRealCzkawkaCliBinary(binDir);
          expect(await realCzkawka.exists(), isTrue);
          for (final tool in ['ffmpeg', 'ffprobe', 'convert']) {
            final stub = File('${binDir.path}/$tool');
            await stub.writeAsString('#!/usr/bin/env bash\nexit 0\n');
            await Process.run('chmod', ['+x', stub.path]);
          }

          final bashResult = await Process.run(
            'bash',
            ['${repoRoot.path}/scripts/05_cleanup_scan.sh'],
            environment: {
              ...Platform.environment,
              'PATH': '${binDir.path}:${Platform.environment['PATH']}',
              'HD_PATH': bashRoot.path,
              'REPORT_DIR': '${bashRoot.path}/reports',
              'RUN_BLUR_SCAN': '0',
            },
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(bashResult.exitCode, 0, reason: bashResult.stderr as String);

          final bashReportContent = await File(
            '${bashRoot.path}/reports/duplicate_files.txt',
          ).readAsString();
          expect(bashReportContent, contains('a.jpg'));
          expect(bashReportContent, contains('b.jpg'));

          // --- Cross-check: same "Found" group counts on both sides,
          // computed independently (Dart's own regex count vs the real
          // script's own `grep -c` summary line), for all three scan
          // kinds.
          final summaryLine = RegExp(
            r'Exact duplicate groups: (\d+)',
          ).firstMatch(bashResult.stdout as String)!;
          expect(int.parse(summaryLine.group(1)!), dartSummary.duplicateFileGroups);
          final imageLine = RegExp(
            r'Image groups: (\d+)',
          ).firstMatch(bashResult.stdout as String)!;
          expect(int.parse(imageLine.group(1)!), dartSummary.imageGroups);
          final videoLine = RegExp(
            r'Video groups: (\d+)',
          ).firstMatch(bashResult.stdout as String)!;
          expect(int.parse(videoLine.group(1)!), dartSummary.videoGroups);
        },
      );
    },
    skip: _imageReady ? false : _dockerSkipReason,
  );
}

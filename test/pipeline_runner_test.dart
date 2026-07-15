import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

Future<File> _createReaderScript(Directory root) async {
  final script = File('${root.path}/read_stdin.sh');
  await script.writeAsString('''
#!/usr/bin/env bash
set -euo pipefail

typed=""
if ! IFS= read -r typed; then
  typed=""
fi

echo "typed=\${typed:-<empty>}"
''');
  return script;
}

void main() {
  test('runner passes configured stdin text to child processes', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'pipeline-runner-stdin-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final script = await _createReaderScript(tempRoot);
    final runner = PipelineRunner(workingDirectory: tempRoot.path);
    final step = PipelineStep(
      id: 'stdin-confirm',
      title: 'stdin confirm',
      description: 'reads stdin',
      risk: PipelineRisk.confirmRequired,
      command: PipelineCommand('bash', [
        script.path,
      ], stdinText: 'MOVE TAKEOUT DUPLICATES\n'),
    );

    final result = await runner.run(
      step,
      const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
    );

    expect(result.succeeded, isTrue);
    expect(result.output, contains('typed=MOVE TAKEOUT DUPLICATES'));
  });

  test('runner closes stdin when no stdin text is configured', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'pipeline-runner-stdin-empty-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final script = await _createReaderScript(tempRoot);
    final runner = PipelineRunner(workingDirectory: tempRoot.path);
    final step = PipelineStep(
      id: 'stdin-empty',
      title: 'stdin empty',
      description: 'reads stdin',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', [script.path]),
    );

    final result = await runner.run(
      step,
      const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
    );

    expect(result.succeeded, isTrue);
    expect(result.output, contains('typed=<empty>'));
  });

  group('stdout/stderr separation (issue #54)', () {
    Future<Directory> makeTempRoot(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() async {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      });
      return dir;
    }

    test(
      'stdoutOutput contains only stdout lines even when stderr is '
      'heavily interleaved between them',
      () async {
        final tempRoot = await makeTempRoot('pipeline-runner-streams-');
        final script = File('${tempRoot.path}/interleave.sh');
        // Deliberately interleaves stdout and stderr writes, each flushed
        // immediately, to simulate a script that (unlike
        // `06_delete_duplicates.sh` today) writes to stderr on its success
        // path in between "Keep:"/"Would trash:" stdout announcements —
        // the exact scenario issue #54 warns could theoretically mispair a
        // stale "Keep:" with an unrelated "Would trash:" if a parser ever
        // read the merged stream.
        await script.writeAsString('''
#!/usr/bin/env bash
set -euo pipefail
echo "Keep: /staging/groupA/keep.jpg"
echo "stderr noise A" >&2
echo "Would trash: /staging/groupA/trash.jpg"
echo "stderr noise B" >&2
echo ""
echo "Keep: /staging/groupB/keep.jpg"
echo "stderr noise C" >&2
echo "Would trash: /staging/groupB/trash.jpg"
''');

        final runner = PipelineRunner(workingDirectory: tempRoot.path);
        final step = PipelineStep(
          id: 'interleave',
          title: 'interleave',
          description: 'interleave',
          risk: PipelineRisk.safe,
          command: PipelineCommand('bash', [script.path]),
        );

        final result = await runner.run(
          step,
          const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
        );

        expect(result.succeeded, isTrue);

        // The safety-relevant stdout-only capture never contains any
        // stderr content.
        expect(result.stdoutOutput, isNot(contains('stderr noise')));
        expect(
          result.stdoutOutput,
          contains('Keep: /staging/groupA/keep.jpg'),
        );
        expect(
          result.stdoutOutput,
          contains('Would trash: /staging/groupA/trash.jpg'),
        );
        expect(
          result.stdoutOutput,
          contains('Keep: /staging/groupB/keep.jpg'),
        );
        expect(
          result.stdoutOutput,
          contains('Would trash: /staging/groupB/trash.jpg'),
        );

        // The combined buffer (still used for the live step-log UI) keeps
        // showing everything — stderr output is never silently dropped
        // from what a human watching the step sees.
        expect(result.output, contains('stderr noise A'));
        expect(result.output, contains('stderr noise B'));
        expect(result.output, contains('stderr noise C'));
        expect(result.output, contains('Keep: /staging/groupA/keep.jpg'));
      },
    );

    test(
      'onLog still receives every stdout and stderr chunk for the live '
      'log view, unchanged from before the stdout/stderr split',
      () async {
        final tempRoot = await makeTempRoot('pipeline-runner-onlog-');
        final script = File('${tempRoot.path}/both_streams.sh');
        await script.writeAsString('''
#!/usr/bin/env bash
set -euo pipefail
echo "out line"
echo "err line" >&2
''');

        final runner = PipelineRunner(workingDirectory: tempRoot.path);
        final step = PipelineStep(
          id: 'both-streams',
          title: 'both streams',
          description: 'both streams',
          risk: PipelineRisk.safe,
          command: PipelineCommand('bash', [script.path]),
        );

        final loggedChunks = <String>[];
        await runner.run(
          step,
          const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
          onLog: loggedChunks.add,
        );

        final loggedText = loggedChunks.join();
        expect(loggedText, contains('out line'));
        expect(loggedText, contains('err line'));
      },
    );
  });

  group('GuidedRunController', () {
    late Directory tempRoot;
    late PipelineRunner runner;
    late GuidedRunController controller;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('guided-run-');
      runner = PipelineRunner(workingDirectory: tempRoot.path);
      controller = GuidedRunController(runner: runner);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    PipelineStep safeStep(String id, {int exitCode = 0}) {
      return PipelineStep(
        id: id,
        title: id,
        description: id,
        risk: PipelineRisk.safe,
        command: PipelineCommand('bash', ['-c', 'exit $exitCode']),
      );
    }

    test('runs the full guided chain resolved from pipeline_models', () async {
      final guidedSteps = buildGuidedRunSteps().map((step) {
        // Real scripts require the real repo layout; substitute a fast
        // successful stand-in command while keeping id/risk/order identical
        // to what the app would actually resolve and pass in.
        return PipelineStep(
          id: step.id,
          title: step.title,
          description: step.description,
          risk: step.risk,
          command: const PipelineCommand('bash', ['-c', 'exit 0']),
          requiresDryRunStepId: step.requiresDryRunStepId,
          linuxOnly: step.linuxOnly,
        );
      }).toList();

      final startedIds = <String>[];
      final completedIds = <String>[];

      final result = await controller.run(
        steps: guidedSteps,
        settings: const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
        onStepStart: (step) => startedIds.add(step.id),
        onStepComplete: (step, stepResult) => completedIds.add(step.id),
      );

      expect(result.outcome, GuidedRunOutcome.completed);
      expect(result.completedStepIds, guidedRunStepIds);
      expect(startedIds, guidedRunStepIds);
      expect(completedIds, guidedRunStepIds);
    });

    test('stops immediately when a step fails, without running later steps', () async {
      final steps = [
        safeStep('one'),
        safeStep('two', exitCode: 7),
        safeStep('three'),
      ];
      final started = <String>[];

      final result = await controller.run(
        steps: steps,
        settings: const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
        onStepStart: (step) => started.add(step.id),
      );

      expect(result.outcome, GuidedRunOutcome.stepFailed);
      expect(result.failedStepId, 'two');
      expect(result.failedExitCode, 7);
      expect(result.completedStepIds, ['one']);
      expect(started, ['one', 'two']);
    });

    test(
      'refuses to run a confirm-gated step, never spawning its process',
      () async {
        final steps = [
          safeStep('dry-run'),
          PipelineStep(
            id: 'confirm',
            title: 'confirm',
            description: 'confirm',
            risk: PipelineRisk.confirmRequired,
            command: const PipelineCommand('bash', [
              '-c',
              'exit 0',
            ]),
            requiresDryRunStepId: 'dry-run',
          ),
        ];
        final started = <String>[];

        expect(
          () => controller.run(
            steps: steps,
            settings: const PipelineSettings(
              hdPath: '/tmp',
              reportDir: '/tmp',
            ),
            onStepStart: (step) => started.add(step.id),
          ),
          throwsStateError,
        );

        // Give the microtask queue a beat, then confirm the confirm-gated
        // step's process was never even started.
        await Future<void>.delayed(Duration.zero);
        expect(started, ['dry-run']);
      },
    );

    test('never reaches delete-confirm/restore-confirm from a real guided '
        'run of the full app step list', () async {
      final guidedSteps = buildGuidedRunSteps();
      final touchedConfirmIds = <String>[];

      await controller.run(
        steps: guidedSteps
            .map(
              (step) => PipelineStep(
                id: step.id,
                title: step.title,
                description: step.description,
                risk: step.risk,
                command: const PipelineCommand('bash', ['-c', 'exit 0']),
                requiresDryRunStepId: step.requiresDryRunStepId,
                linuxOnly: step.linuxOnly,
              ),
            )
            .toList(),
        settings: const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
        onStepStart: (step) {
          if (step.id == 'delete-confirm' || step.id == 'restore-confirm') {
            touchedConfirmIds.add(step.id);
          }
        },
      );

      expect(touchedConfirmIds, isEmpty);
    });
  });

  group('PipelineStep.dartAction plumbing (issue #76)', () {
    // Synthetic Dart-native steps only — no real step is migrated by this
    // PR (`buildPipelineSteps()` is unchanged). This proves the new
    // execution path in isolation: `PipelineRunner.run()` must call a
    // `dartAction` directly (no subprocess spawned) and return a
    // `PipelineRunResult` indistinguishable in shape from a subprocess run,
    // and `GuidedRunController` must chain/log/short-circuit on it exactly
    // like it does for a `command`-backed step.

    test(
      'PipelineStep constructor rejects both command and dartAction set',
      () {
        expect(
          () => PipelineStep(
            id: 'both',
            title: 'both',
            description: 'both',
            risk: PipelineRisk.safe,
            command: const PipelineCommand('bash', ['-c', 'exit 0']),
            dartAction: (settings, onLog) async =>
                const PipelineRunResult(exitCode: 0, output: '', stdoutOutput: ''),
          ),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test(
      'PipelineStep constructor rejects neither command nor dartAction set',
      () {
        expect(
          () => PipelineStep(
            id: 'neither',
            title: 'neither',
            description: 'neither',
            risk: PipelineRisk.safe,
          ),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test(
      'runner calls a successful dartAction directly and returns its result '
      'unchanged, with no subprocess involved',
      () async {
        final runner = PipelineRunner(workingDirectory: Directory.systemTemp.path);
        var callCount = 0;
        final step = PipelineStep(
          id: 'dart-success',
          title: 'dart success',
          description: 'dart success',
          risk: PipelineRisk.safe,
          dartAction: (settings, onLog) async {
            callCount += 1;
            onLog?.call('dart action ran\n');
            return const PipelineRunResult(
              exitCode: 0,
              output: 'dart action ran\n',
              stdoutOutput: 'dart action ran\n',
            );
          },
        );

        final loggedChunks = <String>[];
        final result = await runner.run(
          step,
          const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
          onLog: loggedChunks.add,
        );

        expect(callCount, 1);
        expect(result.succeeded, isTrue);
        expect(result.exitCode, 0);
        expect(result.output, 'dart action ran\n');
        expect(result.stdoutOutput, 'dart action ran\n');
        expect(loggedChunks, ['dart action ran\n']);
      },
    );

    test(
      'runner surfaces a non-zero exit code from a failing dartAction, same '
      'shape a failed subprocess would return',
      () async {
        final runner = PipelineRunner(workingDirectory: Directory.systemTemp.path);
        final step = PipelineStep(
          id: 'dart-fail',
          title: 'dart fail',
          description: 'dart fail',
          risk: PipelineRisk.safe,
          dartAction: (settings, onLog) async {
            onLog?.call('about to fail\n');
            return const PipelineRunResult(
              exitCode: 3,
              output: 'about to fail\n',
              stdoutOutput: '',
            );
          },
        );

        final result = await runner.run(
          step,
          const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
        );

        expect(result.succeeded, isFalse);
        expect(result.exitCode, 3);
      },
    );

    test(
      'runner propagates an uncaught throw from a dartAction rather than '
      'swallowing it into a fake success/failure result',
      () async {
        final runner = PipelineRunner(workingDirectory: Directory.systemTemp.path);
        final step = PipelineStep(
          id: 'dart-throw',
          title: 'dart throw',
          description: 'dart throw',
          risk: PipelineRisk.safe,
          dartAction: (settings, onLog) async {
            throw StateError('synthetic dart action failure');
          },
        );

        expect(
          () => runner.run(
            step,
            const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'dartAction receives the same PipelineSettings the runner was called '
      'with',
      () async {
        final runner = PipelineRunner(workingDirectory: Directory.systemTemp.path);
        PipelineSettings? seenSettings;
        final step = PipelineStep(
          id: 'dart-settings',
          title: 'dart settings',
          description: 'dart settings',
          risk: PipelineRisk.safe,
          dartAction: (settings, onLog) async {
            seenSettings = settings;
            return const PipelineRunResult(exitCode: 0, output: '', stdoutOutput: '');
          },
        );

        const settings = PipelineSettings(hdPath: '/mnt/x', reportDir: '/tmp/reports');
        await runner.run(step, settings);

        expect(seenSettings, same(settings));
      },
    );

    group('GuidedRunController with a Dart-action step', () {
      late PipelineRunner runner;
      late GuidedRunController controller;

      setUp(() {
        runner = PipelineRunner(workingDirectory: Directory.systemTemp.path);
        controller = GuidedRunController(runner: runner);
      });

      PipelineStep dartStep(
        String id, {
        int exitCode = 0,
        String logChunk = 'ok\n',
      }) {
        return PipelineStep(
          id: id,
          title: id,
          description: id,
          risk: PipelineRisk.safe,
          dartAction: (settings, onLog) async {
            onLog?.call(logChunk);
            return PipelineRunResult(
              exitCode: exitCode,
              output: logChunk,
              stdoutOutput: logChunk,
            );
          },
        );
      }

      test(
        'chains a mix of command-backed and dartAction-backed steps '
        'identically',
        () async {
          final steps = [
            PipelineStep(
              id: 'cmd-one',
              title: 'cmd-one',
              description: 'cmd-one',
              risk: PipelineRisk.safe,
              command: const PipelineCommand('bash', ['-c', 'exit 0']),
            ),
            dartStep('dart-two'),
            PipelineStep(
              id: 'cmd-three',
              title: 'cmd-three',
              description: 'cmd-three',
              risk: PipelineRisk.safe,
              command: const PipelineCommand('bash', ['-c', 'exit 0']),
            ),
          ];
          final started = <String>[];
          final completed = <String>[];
          final loggedChunks = <String>[];

          final result = await controller.run(
            steps: steps,
            settings: const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
            onStepStart: (step) => started.add(step.id),
            onStepComplete: (step, stepResult) => completed.add(step.id),
            onLog: loggedChunks.add,
          );

          expect(result.outcome, GuidedRunOutcome.completed);
          expect(result.completedStepIds, ['cmd-one', 'dart-two', 'cmd-three']);
          expect(started, ['cmd-one', 'dart-two', 'cmd-three']);
          expect(completed, ['cmd-one', 'dart-two', 'cmd-three']);
          expect(loggedChunks, contains('ok\n'));
        },
      );

      test(
        'stops the chain when a dartAction step fails, never running the '
        'step after it',
        () async {
          final steps = [
            dartStep('dart-one'),
            dartStep('dart-fails', exitCode: 5, logChunk: 'boom\n'),
            dartStep('dart-never-runs'),
          ];
          final started = <String>[];

          final result = await controller.run(
            steps: steps,
            settings: const PipelineSettings(hdPath: '/tmp', reportDir: '/tmp'),
            onStepStart: (step) => started.add(step.id),
          );

          expect(result.outcome, GuidedRunOutcome.stepFailed);
          expect(result.failedStepId, 'dart-fails');
          expect(result.failedExitCode, 5);
          expect(result.completedStepIds, ['dart-one']);
          expect(started, ['dart-one', 'dart-fails']);
        },
      );
    });
  });
}

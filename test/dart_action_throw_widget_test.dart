import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/media_pipeline_app.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

/// Proves the stuck-UI-state fix (Cody's PR #99 review finding, fixed as
/// part of issue #76's real-`dartAction`-step migration PR): before this
/// fix, `media_pipeline_app.dart`'s `_runSelectedStep`/
/// `_runNextGuidedSegment` never wrapped `await runner.run(...)` in a
/// try/catch, so an uncaught throw from a `dartAction`-backed step (which
/// `PipelineRunner.run()` deliberately propagates rather than swallowing —
/// see `pipeline_runner_test.dart`) left `_runningStepId` permanently
/// non-null, disabling that step's controls until an app restart.
///
/// Uses a fake `PipelineRunner` (same pattern as
/// `guided_run_persistence_and_retry_widget_test.dart`'s
/// `_AlwaysSucceedsRunner`/`_CountingFakeRunner`) that throws for a chosen
/// step id, so no real pipeline scripts run and the throw is deterministic
/// — a synthetic reproduction of the exact failure mode a real
/// `dartAction` (e.g. `restore-dry-run`'s `TrashRootNotFoundException`, or
/// a `ToolsContainer` start failure) can genuinely produce.
void main() {
  testWidgets(
    'a single-step run recovers from a dartAction-equivalent throw instead '
    'of leaving the step stuck "Running"',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MediaPipelineApp(runner: _ThrowingRunner(failingStepId: 'delete-dry-run')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      // The button must be re-enabled and back to "Run Step" — not stuck
      // showing "Running" with a disabled/no-op button, which is exactly
      // the bug this fix closes.
      expect(find.text('Running'), findsNothing);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Step'),
      );
      expect(
        button.onPressed,
        isNotNull,
        reason:
            'the step must be runnable again after a dartAction throw, not '
            'permanently disabled',
      );

      // The failure must also be visible, not silent — mirroring how a
      // non-zero subprocess exit is surfaced.
      expect(
        find.textContaining('threw: '),
        findsOneWidget,
        reason: 'the thrown error must be surfaced in the step log',
      );
    },
  );

  testWidgets(
    'a guided-run segment recovers from a dartAction-equivalent throw '
    'instead of leaving the run stuck',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 'stitch-metadata' is the second step in the guided run's first
      // segment (after 'check-system'), so this exercises the
      // mid-segment-throw path through `GuidedRunController.run`.
      await tester.pumpWidget(
        MediaPipelineApp(
          runner: _ThrowingRunner(failingStepId: 'stitch-metadata'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Run Guided Pipeline'), findsOneWidget);
      await tester.tap(find.text('Run Guided Pipeline'));
      await tester.pumpAndSettle();

      // A mid-segment failure never advances `_guidedSegmentIndex` (that
      // only happens on `GuidedRunOutcome.completed` — see
      // `_runNextGuidedSegment`), so the button label stays "Run Guided
      // Pipeline"; the point of this assertion is that it's tappable
      // again, not stuck mid-flight with no way to retry.
      expect(find.text('Run Guided Pipeline'), findsOneWidget);
      final retryButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Guided Pipeline'),
      );
      expect(
        retryButton.onPressed,
        isNotNull,
        reason:
            'the guided run must be retryable again after a dartAction '
            'throw mid-segment, not permanently stuck',
      );

      // The failed step's own state must show the failure, not a
      // permanently "running" spinner — select it to view its log.
      await tester.tap(find.text('Stitch Metadata'));
      await tester.pumpAndSettle();
      expect(find.textContaining('threw: '), findsOneWidget);
    },
  );
}

/// Fake runner: throws for [failingStepId], otherwise reports a plain
/// success — same construction pattern as
/// `guided_run_persistence_and_retry_widget_test.dart`'s fake runners.
class _ThrowingRunner extends PipelineRunner {
  _ThrowingRunner({required this.failingStepId}) : super(workingDirectory: '.');

  final String failingStepId;

  @override
  Future<PipelineRunResult> run(
    PipelineStep step,
    PipelineSettings settings, {
    LogSink? onLog,
  }) async {
    if (step.id == failingStepId) {
      throw StateError('synthetic dartAction failure for "${step.id}"');
    }
    onLog?.call('${step.id} ok\n');
    return PipelineRunResult(
      exitCode: 0,
      output: '${step.id} ok\n',
      stdoutOutput: '${step.id} ok\n',
    );
  }
}

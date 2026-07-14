import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/guided_run_checkpoint_store.dart';
import 'package:media_pipeline_app/src/immich_phone_checklist_store.dart';
import 'package:media_pipeline_app/src/media_pipeline_app.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

/// Proves the two behaviors added for issue #51 through the real widget
/// tree with a fake PipelineRunner, so no real pipeline scripts run:
///
/// 1. Guided-run checkpoint state (which segment is next) survives an app
///    restart instead of silently resetting to segment 0.
/// 2. Retrying a failed guided-run segment resumes from the failed step,
///    not the start of the segment — and the confirm-gate safety invariant
///    (never auto-running delete-confirm/restore-confirm) still holds.
///
/// Uses an in-memory fake GuidedRunCheckpointStore (same pattern as
/// widget_test.dart's `_FakeChecklistStore`) rather than a real
/// temp-directory-backed store: real `dart:io` file operations awaited
/// directly inside `testWidgets` hang in flutter_test's fake-async zone
/// unless wrapped in `tester.runAsync`, so an in-memory fake is both
/// simpler and the established pattern here.
void main() {
  group('guided run checkpoint persistence (#51 item 1)', () {
    testWidgets(
      'restores _guidedSegmentIndex after a simulated app restart',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Same fake store instance used across both "sessions" below, so
        // its in-memory state plays the role of the on-disk file a real
        // restart would re-read.
        final store = _FakeGuidedRunCheckpointStore();

        // First "session": run the guided pipeline's first segment
        // (check-system, stitch-metadata, scan-duplicates, delete-dry-run)
        // to completion, reaching the delete-dry-run checkpoint.
        await tester.pumpWidget(
          MediaPipelineApp(
            runner: _AlwaysSucceedsRunner(),
            checklistStore: _FakeChecklistStore(),
            guidedRunCheckpointStore: store,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Run Guided Pipeline'), findsOneWidget);

        await tester.tap(find.text('Run Guided Pipeline'));
        await tester.pumpAndSettle();

        expect(find.text('Continue Guided Run'), findsOneWidget);
        expect(store.checkpoint?.segmentIndex, 1);

        // Second "session": a brand-new widget tree (simulating an app
        // restart) pointed at the same checkpoint store. It must restore
        // straight to "Continue Guided Run" instead of resetting to "Run
        // Guided Pipeline".
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MediaPipelineApp(
            runner: _AlwaysSucceedsRunner(),
            checklistStore: _FakeChecklistStore(),
            guidedRunCheckpointStore: store,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Continue Guided Run'), findsOneWidget);
        expect(find.text('Run Guided Pipeline'), findsNothing);
      },
    );

    testWidgets(
      'ignores a stale persisted checkpoint and starts from segment 0',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final home =
            Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.';
        final store = _FakeGuidedRunCheckpointStore()
          ..checkpoint = GuidedRunCheckpoint(
            segmentIndex: 1,
            hdPath: '/mnt/target_drive',
            reportDir: '$home/czkawka_reports',
            updatedAt: DateTime.now().subtract(
              guidedRunCheckpointMaxAge + const Duration(days: 1),
            ),
          );

        await tester.pumpWidget(
          MediaPipelineApp(
            runner: _AlwaysSucceedsRunner(),
            checklistStore: _FakeChecklistStore(),
            guidedRunCheckpointStore: store,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Run Guided Pipeline'), findsOneWidget);
        expect(find.text('Continue Guided Run'), findsNothing);
      },
    );
  });

  group('guided run retry granularity (#51 item 2)', () {
    testWidgets(
      'retrying after a step failure resumes from the failed step, not '
      'the segment start',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final runner = _CountingFakeRunner(
          failingStepIds: {'scan-duplicates'},
        );

        await tester.pumpWidget(
          MediaPipelineApp(
            runner: runner,
            checklistStore: _FakeChecklistStore(),
            guidedRunCheckpointStore: _FakeGuidedRunCheckpointStore(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Run Guided Pipeline'));
        await tester.pumpAndSettle();

        expect(
          runner.callCounts['check-system'],
          1,
          reason: 'first attempt should run every step up to the failure',
        );
        expect(runner.callCounts['stitch-metadata'], 1);
        expect(runner.callCounts['scan-duplicates'], 1);
        expect(
          runner.callCounts.containsKey('delete-dry-run'),
          isFalse,
          reason: 'a step after the failure must never have run',
        );
        expect(
          find.textContaining('"scan-duplicates" failed'),
          findsOneWidget,
        );

        // "Fix the issue" and retry: the same button is still labeled "Run
        // Guided Pipeline" because the segment index never advanced.
        runner.failingStepIds.clear();
        await tester.tap(find.text('Run Guided Pipeline'));
        await tester.pumpAndSettle();

        expect(
          runner.callCounts['check-system'],
          1,
          reason:
              'retry must resume from the failed step, not re-run steps '
              'that already succeeded in this segment',
        );
        expect(runner.callCounts['stitch-metadata'], 1);
        expect(
          runner.callCounts['scan-duplicates'],
          2,
          reason: 'the failed step itself is retried',
        );
        expect(runner.callCounts['delete-dry-run'], 1);

        // The checkpoint reached after recovering is the dedup dry-run
        // checkpoint, so the guided run is now paused waiting on the human
        // action, and the segment index has advanced.
        expect(find.text('Continue Guided Run'), findsOneWidget);
      },
    );

    testWidgets(
      'editing the HD path before retrying restarts the segment from its '
      'first step instead of trusting stale progress',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final runner = _CountingFakeRunner(
          failingStepIds: {'scan-duplicates'},
        );

        await tester.pumpWidget(
          MediaPipelineApp(
            runner: runner,
            checklistStore: _FakeChecklistStore(),
            guidedRunCheckpointStore: _FakeGuidedRunCheckpointStore(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Run Guided Pipeline'));
        await tester.pumpAndSettle();

        expect(runner.callCounts['check-system'], 1);

        // The HD_PATH field sits in the always-visible settings panel;
        // change it before retrying.
        await tester.enterText(
          find.widgetWithText(TextField, '/mnt/target_drive'),
          '/mnt/other_drive',
        );
        await tester.pumpAndSettle();

        runner.failingStepIds.clear();
        await tester.tap(find.text('Run Guided Pipeline'));
        await tester.pumpAndSettle();

        expect(
          runner.callCounts['check-system'],
          2,
          reason:
              'a changed hdPath invalidates earlier successes in this '
              'segment, so the full segment re-runs from its first step',
        );
        expect(runner.callCounts['stitch-metadata'], 2);
        expect(runner.callCounts['scan-duplicates'], 2);
        expect(runner.callCounts['delete-dry-run'], 1);
      },
    );

    testWidgets(
      'confirm-gated steps are never reached via retry-from-failed-step',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final runner = _CountingFakeRunner(failingStepIds: {'sync-immich'});

        await tester.pumpWidget(
          MediaPipelineApp(
            runner: runner,
            checklistStore: _FakeChecklistStore(),
            guidedRunCheckpointStore: _FakeGuidedRunCheckpointStore(),
          ),
        );
        await tester.pumpAndSettle();

        // Run and complete the first segment (ends at the dedup dry-run
        // checkpoint), then continue into the second segment, where
        // sync-immich fails.
        await tester.tap(find.text('Run Guided Pipeline'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue Guided Run'));
        await tester.pumpAndSettle();

        expect(runner.callCounts['verify-cleanup'], 1);
        expect(runner.callCounts['sync-immich'], 1);
        expect(runner.callCounts.containsKey('delete-confirm'), isFalse);
        expect(runner.callCounts.containsKey('restore-confirm'), isFalse);

        runner.failingStepIds.clear();
        await tester.tap(find.text('Continue Guided Run'));
        await tester.pumpAndSettle();

        expect(
          runner.callCounts['verify-cleanup'],
          1,
          reason: 'resume must skip the already-succeeded step',
        );
        expect(runner.callCounts['sync-immich'], 2);
        expect(
          runner.callCounts.containsKey('delete-confirm'),
          isFalse,
          reason:
              'retry-from-failed-step must never make a confirm-gated '
              'step reachable from the automatic guided chain',
        );
        expect(runner.callCounts.containsKey('restore-confirm'), isFalse);
      },
    );
  });
}

class _AlwaysSucceedsRunner extends PipelineRunner {
  _AlwaysSucceedsRunner() : super(workingDirectory: '.');

  @override
  Future<PipelineRunResult> run(
    PipelineStep step,
    PipelineSettings settings, {
    LogSink? onLog,
  }) async {
    return const PipelineRunResult(exitCode: 0, output: '');
  }
}

/// Fake runner for the retry-granularity tests: tracks how many times each
/// step id was actually run (so a test can prove an already-succeeded step
/// was *not* re-run), and fails any step id currently listed in
/// [failingStepIds] (mutable, so a test can "fix the issue" between
/// attempts by clearing it).
class _CountingFakeRunner extends PipelineRunner {
  _CountingFakeRunner({Set<String>? failingStepIds})
    : failingStepIds = failingStepIds ?? {},
      super(workingDirectory: '.');

  final Set<String> failingStepIds;
  final Map<String, int> callCounts = {};

  @override
  Future<PipelineRunResult> run(
    PipelineStep step,
    PipelineSettings settings, {
    LogSink? onLog,
  }) async {
    callCounts[step.id] = (callCounts[step.id] ?? 0) + 1;
    final failed = failingStepIds.contains(step.id);
    final output = failed ? '${step.id} failed\n' : '${step.id} ok\n';
    onLog?.call(output);
    return PipelineRunResult(exitCode: failed ? 1 : 0, output: output);
  }
}

/// In-memory fake, avoiding real file I/O in widget tests — see the
/// file-level doc comment for why. Mirrors widget_test.dart's
/// `_FakeChecklistStore` pattern.
class _FakeGuidedRunCheckpointStore extends GuidedRunCheckpointStore {
  _FakeGuidedRunCheckpointStore() : super(baseDirectory: Directory('.'));

  GuidedRunCheckpoint? checkpoint;

  @override
  Future<GuidedRunCheckpoint?> load() async => checkpoint;

  @override
  Future<void> save(GuidedRunCheckpoint checkpoint) async {
    this.checkpoint = checkpoint;
  }

  @override
  Future<void> clear() async {
    checkpoint = null;
  }
}

class _FakeChecklistStore extends ImmichChecklistStore {
  _FakeChecklistStore() : super(baseDirectory: Directory('.'));

  @override
  Future<List<ImmichPhoneBackupChecklist>> load() async => const [];

  @override
  Future<void> save(List<ImmichPhoneBackupChecklist> checklists) async {}
}

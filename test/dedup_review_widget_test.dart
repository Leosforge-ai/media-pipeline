import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/media_pipeline_app.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

/// Proves the thumbnail-diff duplicate review gate (#49) end-to-end
/// through the real widget tree, using a fake PipelineRunner so no real
/// pipeline scripts are spawned. This is the acceptance-criteria test that
/// "Move Duplicates To Trash" (delete-confirm) stays unreachable until the
/// review screen has been shown at least once for the current dry-run
/// output, even though the dry-run step itself already succeeded.
void main() {
  testWidgets(
    'confirm step is unreachable until the dry-run succeeds AND the '
    'thumbnail review has been opened; opening it unlocks confirm',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeRunner = _FakePipelineRunner(
        outputs: {
          'delete-dry-run': 'DRY RUN MODE: no files will be moved\n'
              '\n'
              '==> Processing duplicate report: /tmp/reports/duplicate_files.txt\n'
              'Keep: /tmp/media-pipeline-test/keep.mp4\n'
              'Would trash: /tmp/media-pipeline-test/trash.mp4\n'
              '\n'
              'Done.\n',
          'delete-confirm':
              'CONFIRM MODE: files WILL be moved to /tmp/media_trash\n'
              'Trashed: /tmp/media-pipeline-test/trash.mp4\n',
        },
      );

      await tester.pumpWidget(MediaPipelineApp(runner: fakeRunner));

      // Select and run the dry-run step first — this alone must not be
      // enough to unlock the confirm step.
      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      // Select the confirm step. Even though the dry-run just succeeded,
      // the confirm button must still be disabled because the thumbnail
      // review has not been shown yet for this dry-run output.
      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();

      final lockedConfirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Confirm'),
      );
      expect(lockedConfirmButton.onPressed, isNull);
      expect(
        find.text(
          'This confirm step is locked until you review the duplicate-thumbnail '
          'comparison below at least once.',
        ),
        findsOneWidget,
      );
      expect(find.text('Duplicate thumbnail review required'), findsOneWidget);
      expect(find.text('Review Duplicate Thumbnails'), findsOneWidget);

      // Open the review screen.
      await tester.tap(find.text('Review Duplicate Thumbnails'));
      await tester.pumpAndSettle();

      expect(find.text('Review Duplicate Move Plan'), findsWidgets);
      expect(find.text('Showing all 1 pair.'), findsOneWidget);
      expect(find.text('keep.mp4'), findsWidgets);
      expect(find.text('trash.mp4'), findsWidgets);
      // .mp4 is not a displayable still-image format, so the pair renders
      // as an icon + filename fallback rather than Image.file.
      expect(find.byIcon(Icons.insert_drive_file), findsNWidgets(2));

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Now that the review has been opened for this dry-run output, the
      // confirm button unlocks.
      final unlockedConfirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Confirm'),
      );
      expect(unlockedConfirmButton.onPressed, isNotNull);
      expect(find.text('Duplicate thumbnail review: reviewed'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Run Confirm'));
      await tester.pumpAndSettle();

      expect(find.textContaining('CONFIRM MODE'), findsOneWidget);
    },
  );

  testWidgets(
    're-running the dry-run step invalidates a prior thumbnail review '
    'acknowledgment',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeRunner = _FakePipelineRunner(
        outputs: {
          'delete-dry-run':
              'Keep: /tmp/media-pipeline-test/keep.mp4\n'
              'Would trash: /tmp/media-pipeline-test/trash.mp4\n',
        },
      );

      await tester.pumpWidget(MediaPipelineApp(runner: fakeRunner));

      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review Duplicate Thumbnails'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Run Confirm'),
            )
            .onPressed,
        isNotNull,
      );

      // Re-run the dry-run step (e.g. the duplicate set may have changed).
      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Run Confirm'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Duplicate thumbnail review required'), findsOneWidget);
    },
  );

  testWidgets(
    'a large duplicate set (#53): sample coverage is surfaced right next '
    'to the confirm button, and "Review Another Sample" grows cumulative '
    'coverage without ever re-showing an already-reviewed pair',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 25 pairs: over the default 20-pair sample size, so the initial
      // dialog open only covers a sample, not the full set.
      final buffer = StringBuffer();
      for (var i = 0; i < 25; i++) {
        buffer
          ..writeln('Keep: /tmp/media-pipeline-test/keep$i.jpg')
          ..writeln('Would trash: /tmp/media-pipeline-test/trash$i.jpg')
          ..writeln();
      }

      final fakeRunner = _FakePipelineRunner(
        outputs: {'delete-dry-run': buffer.toString()},
      );

      await tester.pumpWidget(MediaPipelineApp(runner: fakeRunner));

      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review Duplicate Thumbnails'));
      await tester.pumpAndSettle();

      // Initial batch: 20 of 25 pairs shown, honestly labeled, with a
      // "Review Another Sample" option since 5 pairs remain unreviewed.
      expect(
        find.text('Showing 20 of 25 pairs (batch 1) — full list in the dry-run report.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cumulative: reviewed 20 of 25 pairs'),
        findsOneWidget,
      );
      final reviewAnotherButton = find.widgetWithText(
        OutlinedButton,
        'Review Another Sample (5 pairs not yet reviewed)',
      );
      expect(reviewAnotherButton, findsOneWidget);

      // Request the next batch: it covers the remaining 5 pairs, so
      // cumulative coverage reaches 100% and the button disappears.
      await tester.tap(reviewAnotherButton);
      await tester.pumpAndSettle();

      expect(find.text('Showing all 5 pairs.'), findsOneWidget);
      expect(
        find.textContaining('Cumulative: reviewed 25 of 25 pairs (100%)'),
        findsOneWidget,
      );
      expect(find.textContaining('Review Another Sample'), findsNothing);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Back on the step detail panel: the coverage banner right next to
      // "Run Confirm" states the full reviewed-vs-total percentage, not
      // just the count from the last dialog open.
      expect(
        find.text(
          'You reviewed 25 of 25 pairs (100%) before confirming.',
        ),
        findsOneWidget,
      );

      final unlockedConfirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Confirm'),
      );
      expect(unlockedConfirmButton.onPressed, isNotNull);
    },
  );

  testWidgets(
    'opening the review dialog once still unlocks confirm even without '
    'requesting additional sample batches (#53 is additive, not a '
    'stricter gate)',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final buffer = StringBuffer();
      for (var i = 0; i < 25; i++) {
        buffer
          ..writeln('Keep: /tmp/media-pipeline-test/keep$i.jpg')
          ..writeln('Would trash: /tmp/media-pipeline-test/trash$i.jpg')
          ..writeln();
      }

      final fakeRunner = _FakePipelineRunner(
        outputs: {'delete-dry-run': buffer.toString()},
      );

      await tester.pumpWidget(MediaPipelineApp(runner: fakeRunner));

      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review Duplicate Thumbnails'));
      await tester.pumpAndSettle();

      // Close immediately, without requesting another batch.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // The gate is unchanged by #53: opening the dialog once is still
      // enough, even though coverage is only a partial ~80% sample.
      final unlockedConfirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Confirm'),
      );
      expect(unlockedConfirmButton.onPressed, isNotNull);
      expect(
        find.text('You reviewed 20 of 25 pairs (80%) before confirming.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'issue #70: a large duplicate set (250 pairs) shows an extra '
    "small-fraction warning when only one 20-pair sample batch has been "
    'reviewed, and the warning clears once coverage climbs past the '
    'threshold',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 250 pairs is well over the #70 "large set" threshold (200), and a
      // single 20-pair batch is only 8% — this mirrors the real-world
      // 5,000+ pair runs from the issue where a couple of sample batches
      // barely move the percentage.
      final buffer = StringBuffer();
      for (var i = 0; i < 250; i++) {
        buffer
          ..writeln('Keep: /tmp/media-pipeline-test/keep$i.jpg')
          ..writeln('Would trash: /tmp/media-pipeline-test/trash$i.jpg')
          ..writeln();
      }

      final fakeRunner = _FakePipelineRunner(
        outputs: {'delete-dry-run': buffer.toString()},
      );

      await tester.pumpWidget(MediaPipelineApp(runner: fakeRunner));

      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review Duplicate Thumbnails'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Only 20 of 250 reviewed (8%) — the coverage banner is accurate,
      // and the extra small-fraction warning is now shown alongside it.
      expect(
        find.text('You reviewed 20 of 250 pairs (8%) before confirming.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('This is a large duplicate set (250 pairs)'),
        findsOneWidget,
      );

      // Reopening the dialog alone draws a fresh, non-overlapping batch of
      // 20 (see _DuplicateThumbnailReviewDialogState.initState), taking
      // cumulative coverage to 40 of 250 — past the #70 small-fraction
      // threshold (>10%).
      await tester.tap(find.text('Review Duplicate Thumbnails Again'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // 40 of 250 is 16% — above the small-fraction threshold, so the
      // extra warning no longer shows even though the set is still large.
      expect(
        find.text('You reviewed 40 of 250 pairs (16%) before confirming.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('This is a large duplicate set'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'issue #54: a stderr line landing physically BETWEEN a real "Keep:" and '
    'its matching "Would trash:" in the merged log must never overwrite the '
    'pending keep and mispair the real trash target — the review dialog '
    'must read stdout-only, not the merged log',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Real stdout: one clean, unambiguous pair.
      const cleanStdout =
          'Keep: /tmp/media-pipeline-test/keep.mp4\n'
          'Would trash: /tmp/media-pipeline-test/trash.mp4\n';

      // What the *merged* stdout+stderr log would look like if a stderr
      // write landed between the real "Keep:" line and its matching
      // "Would trash:" line, and that stderr text happened to itself match
      // the "Keep: <path>" line pattern (e.g. a diagnostic tool echoing a
      // path it's inspecting). `parseDuplicateDryRunOutput` has no concept
      // of which stream a line came from — a second "Keep:" line always
      // overwrites the pending keep, by design, so it can track a report's
      // real group boundaries. If the review dialog ever parsed this
      // merged buffer instead of stdout-only, the real "Would trash:" line
      // would silently pair with the stderr line's path instead of the
      // real keep — a genuine mispair, not just a harmless dangling
      // orphan (this is the scenario issue #54 actually warns about).
      const corruptedMerged =
          'Keep: /tmp/media-pipeline-test/keep.mp4\n'
          'Keep: /tmp/media-pipeline-test/stderr-injected-keep.mp4\n'
          'Would trash: /tmp/media-pipeline-test/trash.mp4\n';

      final fakeRunner = _StreamSeparatedFakePipelineRunner(
        stdoutOutputs: {'delete-dry-run': cleanStdout},
        mergedOutputs: {'delete-dry-run': corruptedMerged},
      );

      await tester.pumpWidget(MediaPipelineApp(runner: fakeRunner));

      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Step'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move Duplicates To Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review Duplicate Thumbnails'));
      await tester.pumpAndSettle();

      // Exactly one pair is shown, and it pairs the *real* keep with the
      // *real* trash target — not the stderr-injected path that would win
      // if the merged buffer were parsed instead of stdout-only.
      expect(find.text('Showing all 1 pair.'), findsOneWidget);
      expect(find.text('keep.mp4'), findsWidgets);
      expect(find.text('trash.mp4'), findsWidgets);
      expect(
        find.textContaining('stderr-injected-keep'),
        findsNothing,
        reason:
            'the stderr-injected "Keep:" line must never win the pairing '
            'over the real keep target',
      );

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // The merged log is still visible in full on the dry-run step's own
      // detail panel (the live step-log view), so the extra content is
      // never silently hidden from the human operator — only kept out of
      // the safety-relevant parse above.
      await tester.tap(find.text('Review Duplicate Move Plan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stderr-injected-keep'), findsOneWidget);
    },
  );
}

/// Fake runner that can return a *different* merged (stdout+stderr) log
/// than its stdout-only capture, so tests can simulate the interleaved
/// stderr scenario from issue #54 without spawning real processes.
class _StreamSeparatedFakePipelineRunner extends PipelineRunner {
  _StreamSeparatedFakePipelineRunner({
    required this.stdoutOutputs,
    required this.mergedOutputs,
  }) : super(workingDirectory: '.');

  /// Step id -> canned stdout-only capture (what safety parsers must read).
  final Map<String, String> stdoutOutputs;

  /// Step id -> canned merged stdout+stderr capture (what the live step-log
  /// UI displays).
  final Map<String, String> mergedOutputs;

  @override
  Future<PipelineRunResult> run(
    PipelineStep step,
    PipelineSettings settings, {
    LogSink? onLog,
  }) async {
    final merged = mergedOutputs[step.id] ?? '';
    final stdoutOnly = stdoutOutputs[step.id] ?? '';
    onLog?.call(merged);
    return PipelineRunResult(
      exitCode: 0,
      output: merged,
      stdoutOutput: stdoutOnly,
    );
  }
}

class _FakePipelineRunner extends PipelineRunner {
  _FakePipelineRunner({required this.outputs})
    : super(workingDirectory: '.');

  /// Step id -> canned stdout to "produce" for that step, always exiting 0.
  final Map<String, String> outputs;

  @override
  Future<PipelineRunResult> run(
    PipelineStep step,
    PipelineSettings settings, {
    LogSink? onLog,
  }) async {
    final output = outputs[step.id] ?? '';
    onLog?.call(output);
    return PipelineRunResult(exitCode: 0, output: output, stdoutOutput: output);
  }
}

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
    return PipelineRunResult(exitCode: 0, output: output);
  }
}

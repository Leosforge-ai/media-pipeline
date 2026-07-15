import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

void main() {
  test(
    'delete-confirm is Dart-native (issue #76) and never a --confirm '
    'command',
    () {
      final step = buildPipelineSteps().singleWhere(
        (step) => step.id == 'delete-confirm',
      );

      // Migrated from `command` to `dartAction` (issue #76) — see
      // `pipeline_models.dart`'s `runDeleteConfirmStep`. There is no
      // `PipelineCommand` at all any more, so there is no argument list
      // that could ever carry `--confirm` — a stronger guarantee than the
      // old "the arguments list contains --confirm" check.
      expect(step.command, isNull);
      expect(step.dartAction, isNotNull);
      expect(step.requiresDryRunStepId, 'delete-dry-run');
      expect(step.risk, PipelineRisk.confirmRequired);
    },
  );

  test(
    'dry-run cleanup is Dart-native (issue #76) and never a --confirm '
    'command',
    () {
      final step = buildPipelineSteps().singleWhere(
        (step) => step.id == 'delete-dry-run',
      );

      // Migrated from `command` to `dartAction` (issue #76) — see
      // `pipeline_models.dart`'s `runDeleteDryRunStep`. There is no
      // `PipelineCommand` at all any more, so there is no argument list
      // that could ever carry `--confirm` — a stronger guarantee than the
      // old "the arguments list doesn't contain --confirm" check.
      expect(step.command, isNull);
      expect(step.dartAction, isNotNull);
      expect(step.risk, PipelineRisk.safe);
    },
  );

  test('confirm step is blocked until dry-run succeeds', () {
    final confirm = buildPipelineSteps().singleWhere(
      (step) => step.id == 'delete-confirm',
    );
    final states = {
      'delete-dry-run': const StepRunState(status: PipelineStepStatus.idle),
    };

    expect(
      canRunStep(
        step: confirm,
        states: states,
        duplicateThumbnailReviewAcknowledged: true,
      ),
      isFalse,
    );

    states['delete-dry-run'] = const StepRunState(
      status: PipelineStepStatus.succeeded,
    );

    expect(
      canRunStep(
        step: confirm,
        states: states,
        duplicateThumbnailReviewAcknowledged: true,
      ),
      isTrue,
    );
  });

  group('delete-confirm duplicate thumbnail review gate (#49)', () {
    late PipelineStep confirm;
    late Map<String, StepRunState> succeededDryRunStates;

    setUp(() {
      confirm = buildPipelineSteps().singleWhere(
        (step) => step.id == 'delete-confirm',
      );
      succeededDryRunStates = {
        'delete-dry-run': const StepRunState(
          status: PipelineStepStatus.succeeded,
        ),
      };
    });

    test('delete-confirm opts into the review gate', () {
      expect(confirm.requiresDuplicateThumbnailReview, isTrue);
    });

    test('other confirm-gated steps do not require the review', () {
      final restoreConfirm = buildPipelineSteps().singleWhere(
        (step) => step.id == 'restore-confirm',
      );

      expect(restoreConfirm.requiresDuplicateThumbnailReview, isFalse);
    });

    test(
      'stays blocked when the dry-run succeeded but the review has not '
      'been acknowledged — default fails closed',
      () {
        expect(
          canRunStep(step: confirm, states: succeededDryRunStates),
          isFalse,
        );
        expect(
          canRunStep(
            step: confirm,
            states: succeededDryRunStates,
            duplicateThumbnailReviewAcknowledged: false,
          ),
          isFalse,
        );
      },
    );

    test(
      'stays blocked when the review is acknowledged but the dry-run has '
      'not succeeded — the thumbnail-review gate never replaces the '
      'existing dry-run gate',
      () {
        final states = {
          'delete-dry-run': const StepRunState(
            status: PipelineStepStatus.idle,
          ),
        };

        expect(
          canRunStep(
            step: confirm,
            states: states,
            duplicateThumbnailReviewAcknowledged: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'only unlocks once both the dry-run succeeded AND the review was '
      'acknowledged',
      () {
        expect(
          canRunStep(
            step: confirm,
            states: succeededDryRunStates,
            duplicateThumbnailReviewAcknowledged: true,
          ),
          isTrue,
        );
      },
    );
  });

  test('settings are converted into process environment', () {
    const settings = PipelineSettings(
      hdPath: '/media/photos',
      reportDir: '/tmp/reports',
      extraEnvironment: {'RUN_BLUR_SCAN': '0'},
    );

    expect(settings.toEnvironment(), {
      'HD_PATH': '/media/photos',
      'REPORT_DIR': '/tmp/reports',
      'RUN_BLUR_SCAN': '0',
    });
  });

  test(
    'immich takeout duplicate dry-run is Dart-native (issue #76), safe, '
    'and linux only',
    () {
      final step = buildPipelineSteps().singleWhere(
        (step) => step.id == 'immich-takeout-duplicate-dry-run',
      );

      // Migrated from `command` to `dartAction` (issue #76) — see
      // `pipeline_models.dart`'s `runImmichTakeoutDuplicateDryRunStep`.
      // `sha256sum` now runs inside a `ToolsContainer` the step starts
      // itself, so the informational tool-requirement chip is `docker`
      // (Docker is what's actually needed on the host), not `sha256sum`.
      expect(step.command, isNull);
      expect(step.dartAction, isNotNull);
      expect(step.risk, PipelineRisk.safe);
      expect(step.linuxOnly, isTrue);
      expect(step.requiredTools, contains('docker'));
      expect(step.requiresDryRunStepId, isNull);
    },
  );

  group('guided run chain', () {
    test('never includes a confirm-gated step id', () {
      final confirmRequiredIds = buildPipelineSteps()
          .where((step) => step.risk == PipelineRisk.confirmRequired)
          .map((step) => step.id)
          .toSet();

      // Explicitly assert the two known confirm-gated steps are excluded,
      // not just "no overlap" — this is the safety invariant from #48.
      expect(guidedRunStepIds, isNot(contains('delete-confirm')));
      expect(guidedRunStepIds, isNot(contains('restore-confirm')));
      expect(
        guidedRunStepIds.toSet().intersection(confirmRequiredIds),
        isEmpty,
      );
    });

    test(
      'never includes interactive or privileged setup steps that would '
      'hang or fail unattended',
      () {
        // setup-dependencies (01) runs sudo calls; configure-rclone (02)
        // runs the interactive `rclone config` wizard on stdin/stdout, and
        // PipelineRunner.run() closes child stdin immediately when a step
        // has no stdinText — so either step would hang or error if it were
        // ever auto-chained. Both stay manual-only, like setup-immich /
        // verify-immich already are.
        expect(guidedRunStepIds, isNot(contains('setup-dependencies')));
        expect(guidedRunStepIds, isNot(contains('configure-rclone')));
        expect(guidedRunStepIds, isNot(contains('setup-immich')));
        expect(guidedRunStepIds, isNot(contains('verify-immich')));
      },
    );

    test('buildGuidedRunSteps resolves steps in the declared order and '
        'none are confirm-gated', () {
      final steps = buildGuidedRunSteps();

      expect(
        steps.map((step) => step.id).toList(),
        guidedRunStepIds,
      );
      expect(
        steps.every((step) => step.risk != PipelineRisk.confirmRequired),
        isTrue,
      );
    });

    test('checkpoint ids are the dedup dry-run and Immich sync steps', () {
      expect(guidedRunCheckpointStepIds, {'delete-dry-run', 'sync-immich'});
    });

    test('buildGuidedRunSegments stops each segment at a checkpoint step', () {
      final segments = buildGuidedRunSegments();

      // Flattening the segments back out reproduces the full chain, in
      // order, with nothing dropped or duplicated.
      expect(segments.expand((segment) => segment).toList(), guidedRunStepIds);

      // Every segment except possibly the last ends on a checkpoint step,
      // and the checkpoint id only ever appears as a segment's last step.
      for (final segment in segments) {
        final last = segment.last;
        final isCheckpointSegment = guidedRunCheckpointStepIds.contains(last);
        final isFinalSegment = segment == segments.last;
        expect(isCheckpointSegment || isFinalSegment, isTrue);
        expect(
          segment.sublist(0, segment.length - 1).any(
                guidedRunCheckpointStepIds.contains,
              ),
          isFalse,
        );
      }

      // The dedup dry-run checkpoint and the Immich sync checkpoint must
      // each end their own segment, so a human must act before the guided
      // run continues to delete-confirm or an Immich rescan.
      expect(
        segments.any((segment) => segment.last == 'delete-dry-run'),
        isTrue,
      );
      expect(
        segments.any((segment) => segment.last == 'sync-immich'),
        isTrue,
      );
    });
  });
}

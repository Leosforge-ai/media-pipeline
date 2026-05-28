import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

void main() {
  test('confirm cleanup keeps explicit confirm argument', () {
    final step = buildPipelineSteps().singleWhere(
      (step) => step.id == 'delete-confirm',
    );

    expect(step.command.arguments, contains('--confirm'));
    expect(step.requiresDryRunStepId, 'delete-dry-run');
    expect(step.risk, PipelineRisk.confirmRequired);
  });

  test('dry-run cleanup does not include confirm argument', () {
    final step = buildPipelineSteps().singleWhere(
      (step) => step.id == 'delete-dry-run',
    );

    expect(step.command.arguments, isNot(contains('--confirm')));
    expect(step.risk, PipelineRisk.safe);
  });

  test('confirm step is blocked until dry-run succeeds', () {
    final confirm = buildPipelineSteps().singleWhere(
      (step) => step.id == 'delete-confirm',
    );
    final states = {
      'delete-dry-run': const StepRunState(status: PipelineStepStatus.idle),
    };

    expect(canRunStep(step: confirm, states: states), isFalse);

    states['delete-dry-run'] = const StepRunState(
      status: PipelineStepStatus.succeeded,
    );

    expect(canRunStep(step: confirm, states: states), isTrue);
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
}

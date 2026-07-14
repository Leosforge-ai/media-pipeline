import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/duplicate_report.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

void main() {
  test('app runner drives duplicate cleanup and restore simulation', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'media-pipeline-app-sim-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final staging = Directory('${tempRoot.path}/cleaning_staging');
    final reports = Directory('${tempRoot.path}/reports');
    await staging.create(recursive: true);
    await reports.create(recursive: true);

    final keep = File('${staging.path}/a.jpg');
    final trash = File('${staging.path}/b.jpg');
    await keep.writeAsString('keep');
    await trash.writeAsString('trash');
    await File(
      '${reports.path}/duplicate_files.txt',
    ).writeAsString('"${keep.path}" - 10 KiB\n"${trash.path}" - 10 KiB\n\n');

    final steps = buildPipelineSteps();
    final dryRunStep = steps.singleWhere((step) => step.id == 'delete-dry-run');
    final confirmStep = steps.singleWhere(
      (step) => step.id == 'delete-confirm',
    );
    final restoreDryRunStep = steps.singleWhere(
      (step) => step.id == 'restore-dry-run',
    );
    final settings = PipelineSettings(
      hdPath: tempRoot.path,
      reportDir: reports.path,
    );
    final runner = PipelineRunner(workingDirectory: Directory.current.path);

    final dryRun = await runner.run(dryRunStep, settings);

    expect(dryRun.succeeded, isTrue);
    expect(dryRun.output, contains('DRY RUN MODE'));
    expect(dryRun.output, contains('Would trash: ${trash.path}'));
    expect(await keep.exists(), isTrue);
    expect(await trash.exists(), isTrue);

    final states = {
      'delete-dry-run': const StepRunState(
        status: PipelineStepStatus.succeeded,
      ),
    };

    // The dry-run succeeding alone is no longer enough (#49): the
    // thumbnail-diff review gate must also be explicitly acknowledged
    // before the confirm step is reachable.
    expect(canRunStep(step: confirmStep, states: states), isFalse);
    expect(
      canRunStep(
        step: confirmStep,
        states: states,
        duplicateThumbnailReviewAcknowledged: false,
      ),
      isFalse,
    );
    expect(
      canRunStep(
        step: confirmStep,
        states: states,
        duplicateThumbnailReviewAcknowledged: true,
      ),
      isTrue,
    );

    // The review UI parses this exact dry-run output; prove against the
    // real script's stdout (not a hand-written fixture) that it extracts
    // the same keep/trash pair the script itself will act on. Use
    // `stdoutOutput` (stdout-only), matching the app's own call sites
    // (`_openDedupReviewDialog`, the pair-count preview) — see issue #54.
    final parsed = parseDuplicateDryRunOutput(dryRun.stdoutOutput);
    expect(parsed.orphanTrashLineCount, 0);
    expect(parsed.pairs, [
      DuplicateReviewPair(keepPath: keep.path, trashPath: trash.path),
    ]);

    final confirm = await runner.run(confirmStep, settings);
    final trashed = File(
      '${tempRoot.path}/media_trash/${trash.path.replaceFirst('/', '')}',
    );

    expect(confirm.succeeded, isTrue);
    expect(confirm.output, contains('CONFIRM MODE'));
    expect(await keep.exists(), isTrue);
    expect(await trash.exists(), isFalse);
    expect(await trashed.exists(), isTrue);

    final restoreDryRun = await runner.run(restoreDryRunStep, settings);

    expect(restoreDryRun.succeeded, isTrue);
    expect(
      restoreDryRun.output,
      contains('Would restore: ${trashed.path} -> ${trash.path}'),
    );
    expect(await trashed.exists(), isTrue);
    expect(await trash.exists(), isFalse);
  });
}

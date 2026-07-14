import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pipeline_models.dart';

typedef LogSink = void Function(String chunk);

class PipelineRunner {
  const PipelineRunner({required this.workingDirectory});

  final String workingDirectory;

  Future<PipelineRunResult> run(
    PipelineStep step,
    PipelineSettings settings, {
    LogSink? onLog,
  }) async {
    // `output` is the combined, live-interleaved stdout+stderr buffer that
    // feeds the step-log UI (`StepRunState.log`) — its ordering/behavior is
    // unchanged from before issue #54: both streams are still captured via
    // independent listeners as they arrive, and `onLog` still fires for
    // every chunk from either stream so a human watching a running step
    // sees the exact same live interleaving as before.
    //
    // `stdoutOutput` is a second, dedicated accumulation that only ever
    // receives stdout chunks. It exists so safety-relevant parsers (e.g.
    // `duplicate_report.dart`'s "Keep:"/"Would trash:" parser, via
    // `StepRunState.stdoutLog`) can read pure stdout instead of implicitly
    // assuming `output` never contains interleaved stderr — see issue #54.
    final output = StringBuffer();
    final stdoutOutput = StringBuffer();
    final process = await Process.start(
      step.command.executable,
      step.command.arguments,
      workingDirectory: workingDirectory,
      environment: settings.toEnvironment(),
      runInShell: Platform.isWindows,
    );

    void captureStdout(String chunk) {
      stdoutOutput.write(chunk);
      output.write(chunk);
      onLog?.call(chunk);
    }

    void captureStderr(String chunk) {
      output.write(chunk);
      onLog?.call(chunk);
    }

    final subscriptions = [
      process.stdout.transform(utf8.decoder).listen(captureStdout),
      process.stderr.transform(utf8.decoder).listen(captureStderr),
    ];

    final stdinText = step.command.stdinText;
    if (stdinText != null) {
      process.stdin.write(stdinText);
      await process.stdin.flush();
    }
    await process.stdin.close();

    final exitCode = await process.exitCode;
    await Future.wait<void>([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);

    return PipelineRunResult(
      exitCode: exitCode,
      output: output.toString(),
      stdoutOutput: stdoutOutput.toString(),
    );
  }
}

bool isStepSupportedOnCurrentPlatform(PipelineStep step) {
  if (!step.linuxOnly) {
    return true;
  }
  return Platform.isLinux;
}

bool canRunStep({
  required PipelineStep step,
  required Map<String, StepRunState> states,
  // Fails closed: a step that opts into the thumbnail review gate
  // (`requiresDuplicateThumbnailReview`) stays locked unless the caller
  // explicitly asserts the review was shown. This is additive to the
  // existing dry-run gate below, never a replacement for it — see
  // `PipelineStep.requiresDuplicateThumbnailReview` (issue #49).
  bool duplicateThumbnailReviewAcknowledged = false,
}) {
  if (!isStepSupportedOnCurrentPlatform(step)) {
    return false;
  }
  final dryRunStepId = step.requiresDryRunStepId;
  if (dryRunStepId != null &&
      states[dryRunStepId]?.status != PipelineStepStatus.succeeded) {
    return false;
  }
  if (step.requiresDuplicateThumbnailReview &&
      !duplicateThumbnailReviewAcknowledged) {
    return false;
  }
  return true;
}

/// Why a [GuidedRunController.run] call ended.
enum GuidedRunOutcome {
  /// Every step in the requested segment finished successfully. If the
  /// segment ended on a checkpoint step, the caller must still wait for the
  /// separate human action before running the next segment.
  completed,

  /// A step exited non-zero. The guided run stops immediately; it never
  /// continues to a later step (including any checkpoint step) after a
  /// failure.
  stepFailed,

  /// The caller's `shouldAbort` callback returned true before a step ran.
  aborted,
}

class GuidedRunResult {
  const GuidedRunResult({
    required this.outcome,
    required this.completedStepIds,
    this.failedStepId,
    this.failedExitCode,
  });

  final GuidedRunOutcome outcome;
  final List<String> completedStepIds;
  final String? failedStepId;
  final int? failedExitCode;
}

/// Runs a pre-resolved, ordered list of guided-run steps back-to-back with a
/// single [PipelineRunner], with no human interaction between them.
///
/// Safety invariant: this must never be given (and will refuse to run) a
/// step with `PipelineRisk.confirmRequired`. Confirm-gated steps
/// (`06_delete_duplicates.sh --confirm`, `11_restore_from_trash.sh
/// --confirm`) always require an explicit, separate, human-triggered action
/// outside the guided chain — see `guidedRunStepIds` and
/// `guidedRunCheckpointStepIds` in `pipeline_models.dart`, which are the
/// intended source of the `steps` passed in here.
class GuidedRunController {
  const GuidedRunController({required this.runner});

  final PipelineRunner runner;

  Future<GuidedRunResult> run({
    required List<PipelineStep> steps,
    required PipelineSettings settings,
    void Function(PipelineStep step)? onStepStart,
    void Function(PipelineStep step, PipelineRunResult result)?
    onStepComplete,
    LogSink? onLog,
    bool Function()? shouldAbort,
  }) async {
    final completed = <String>[];
    for (final step in steps) {
      if (step.risk == PipelineRisk.confirmRequired) {
        throw StateError(
          'GuidedRunController refuses to auto-run confirm-gated step '
          '"${step.id}"; it requires an explicit separate human action.',
        );
      }
      if (shouldAbort?.call() ?? false) {
        return GuidedRunResult(
          outcome: GuidedRunOutcome.aborted,
          completedStepIds: completed,
        );
      }

      onStepStart?.call(step);
      final result = await runner.run(step, settings, onLog: onLog);
      onStepComplete?.call(step, result);

      if (!result.succeeded) {
        return GuidedRunResult(
          outcome: GuidedRunOutcome.stepFailed,
          completedStepIds: completed,
          failedStepId: step.id,
          failedExitCode: result.exitCode,
        );
      }
      completed.add(step.id);
    }

    return GuidedRunResult(
      outcome: GuidedRunOutcome.completed,
      completedStepIds: completed,
    );
  }
}

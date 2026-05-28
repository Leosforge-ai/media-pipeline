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
    final output = StringBuffer();
    final process = await Process.start(
      step.command.executable,
      step.command.arguments,
      workingDirectory: workingDirectory,
      environment: settings.toEnvironment(),
      runInShell: Platform.isWindows,
    );

    void capture(String chunk) {
      output.write(chunk);
      onLog?.call(chunk);
    }

    final subscriptions = [
      process.stdout.transform(utf8.decoder).listen(capture),
      process.stderr.transform(utf8.decoder).listen(capture),
    ];

    final exitCode = await process.exitCode;
    await Future.wait<void>([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);

    return PipelineRunResult(exitCode: exitCode, output: output.toString());
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
}) {
  if (!isStepSupportedOnCurrentPlatform(step)) {
    return false;
  }
  final dryRunStepId = step.requiresDryRunStepId;
  if (dryRunStepId == null) {
    return true;
  }
  return states[dryRunStepId]?.status == PipelineStepStatus.succeeded;
}

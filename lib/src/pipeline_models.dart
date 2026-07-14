import 'dart:io';

enum PipelineStepStatus { idle, running, succeeded, failed, blocked }

enum PipelineRisk { safe, reviewRequired, confirmRequired }

class PipelineSettings {
  const PipelineSettings({
    required this.hdPath,
    required this.reportDir,
    this.extraEnvironment = const {},
  });

  factory PipelineSettings.defaults() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return PipelineSettings(
      hdPath: '/mnt/target_drive',
      reportDir: '$home/czkawka_reports',
    );
  }

  final String hdPath;
  final String reportDir;
  final Map<String, String> extraEnvironment;

  Map<String, String> toEnvironment() {
    return {'HD_PATH': hdPath, 'REPORT_DIR': reportDir, ...extraEnvironment};
  }

  PipelineSettings copyWith({
    String? hdPath,
    String? reportDir,
    Map<String, String>? extraEnvironment,
  }) {
    return PipelineSettings(
      hdPath: hdPath ?? this.hdPath,
      reportDir: reportDir ?? this.reportDir,
      extraEnvironment: extraEnvironment ?? this.extraEnvironment,
    );
  }
}

class PipelineCommand {
  const PipelineCommand(this.executable, this.arguments, {this.stdinText});

  final String executable;
  final List<String> arguments;
  final String? stdinText;
}

class PipelineStep {
  const PipelineStep({
    required this.id,
    required this.title,
    required this.description,
    required this.risk,
    required this.command,
    this.requiredTools = const [],
    this.requiresDryRunStepId,
    this.linuxOnly = false,
    this.requiresDuplicateThumbnailReview = false,
  });

  final String id;
  final String title;
  final String description;
  final PipelineRisk risk;
  final PipelineCommand command;
  final List<String> requiredTools;
  final String? requiresDryRunStepId;
  final bool linuxOnly;

  /// Whether this step's gate (see [pipeline_runner.canRunStep]) also
  /// requires that a human has viewed the thumbnail-diff duplicate review
  /// screen (issue #49) for the current dry-run output, in addition to the
  /// dry-run step referenced by [requiresDryRunStepId] having succeeded.
  ///
  /// This is additive to the existing dry-run gate, never a replacement for
  /// it — see `canRunStep` in `pipeline_runner.dart`.
  final bool requiresDuplicateThumbnailReview;

  bool get requiresPriorDryRun => requiresDryRunStepId != null;
}

class PipelineRunResult {
  const PipelineRunResult({
    required this.exitCode,
    required this.output,
    required this.stdoutOutput,
  });

  /// Process exit code.
  final int exitCode;

  /// Combined stdout+stderr, delivered in the interleaved order the two
  /// streams actually arrived — this is what the live "step log" UI
  /// displays. Its ordering/interleaving behavior is unchanged from before
  /// issue #54.
  final String output;

  /// Stdout only, captured from a dedicated accumulation that never mixes
  /// in stderr. Safety-relevant parsers that read back a script's own
  /// stdout announcements (e.g. `duplicate_report.dart`'s "Keep:" / "Would
  /// trash:" parser) must read this field, not [output] — see issue #54.
  final String stdoutOutput;

  bool get succeeded => exitCode == 0;
}

class StepRunState {
  const StepRunState({
    this.status = PipelineStepStatus.idle,
    this.exitCode,
    this.log = '',
    this.stdoutLog = '',
  });

  final PipelineStepStatus status;
  final int? exitCode;

  /// Combined stdout+stderr for the live step-log display. Never use this
  /// for safety-relevant parsing — see [stdoutLog].
  final String log;

  /// Stdout-only capture of the step's process output (see
  /// [PipelineRunResult.stdoutOutput]). Safety-relevant parsers (e.g.
  /// `parseDuplicateDryRunOutput`) must read this field, not [log].
  final String stdoutLog;

  StepRunState copyWith({
    PipelineStepStatus? status,
    int? exitCode,
    String? log,
    String? stdoutLog,
  }) {
    return StepRunState(
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      log: log ?? this.log,
      stdoutLog: stdoutLog ?? this.stdoutLog,
    );
  }
}

List<PipelineStep> buildPipelineSteps() {
  return const [
    PipelineStep(
      id: 'check-system',
      title: 'System Check',
      description:
          'Print configured paths and detect required command-line tools.',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', ['scripts/00_check_system.sh']),
    ),
    PipelineStep(
      id: 'setup-dependencies',
      title: 'Install Dependencies',
      description:
          'Install Linux packages, Czkawka CLI, Docker, and pipeline folders.',
      risk: PipelineRisk.reviewRequired,
      command: PipelineCommand('bash', ['scripts/01_setup_dependencies.sh']),
      linuxOnly: true,
    ),
    PipelineStep(
      id: 'configure-rclone',
      title: 'Configure Rclone',
      description: 'Start rclone configuration for Google Drive access.',
      risk: PipelineRisk.reviewRequired,
      command: PipelineCommand('bash', ['scripts/02_configure_rclone.sh']),
      requiredTools: ['rclone'],
    ),
    PipelineStep(
      id: 'stitch-metadata',
      title: 'Stitch Metadata',
      description:
          'Extract Takeout archives, apply JSON sidecar metadata, and stage media.',
      risk: PipelineRisk.reviewRequired,
      command: PipelineCommand('python3', ['scripts/04_stitch_metadata.py']),
      requiredTools: ['python3', 'exiftool', 'rsync'],
    ),
    PipelineStep(
      id: 'scan-duplicates',
      title: 'Scan Duplicates',
      description: 'Run Czkawka duplicate and optional blur scans.',
      risk: PipelineRisk.reviewRequired,
      command: PipelineCommand('bash', ['scripts/05_cleanup_scan.sh']),
      requiredTools: ['czkawka_cli', 'ffmpeg', 'ffprobe', 'convert'],
    ),
    PipelineStep(
      id: 'delete-dry-run',
      title: 'Review Duplicate Move Plan',
      description: 'Dry-run duplicate cleanup. No files are moved.',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', ['scripts/06_delete_duplicates.sh']),
    ),
    PipelineStep(
      id: 'delete-confirm',
      title: 'Move Duplicates To Trash',
      description:
          'Confirm duplicate cleanup and move selected files to media_trash.',
      risk: PipelineRisk.confirmRequired,
      command: PipelineCommand('bash', [
        'scripts/06_delete_duplicates.sh',
        '--confirm',
      ]),
      requiresDryRunStepId: 'delete-dry-run',
      requiresDuplicateThumbnailReview: true,
    ),
    PipelineStep(
      id: 'sync-immich',
      title: 'Sync Immich Library',
      description:
          'Copy cleaned staging files into the Immich external library folder.',
      risk: PipelineRisk.reviewRequired,
      command: PipelineCommand('bash', [
        'scripts/08_sync_to_immich_library.sh',
      ]),
      requiredTools: ['rsync'],
    ),
    PipelineStep(
      id: 'immich-takeout-duplicate-dry-run',
      title: 'Review Immich Takeout Duplicates',
      description:
          'Dry-run the localized Takeout duplicate cleanup for Immich only.',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', [
        'scripts/12_clean_immich_takeout_duplicates.sh',
      ]),
      requiredTools: ['sha256sum'],
      linuxOnly: true,
    ),
    PipelineStep(
      id: 'setup-immich',
      title: 'Set Up Immich',
      description: 'Generate Immich configuration and start Docker Compose.',
      risk: PipelineRisk.reviewRequired,
      command: PipelineCommand('bash', ['scripts/09_setup_immich.sh']),
      requiredTools: ['docker'],
      linuxOnly: true,
    ),
    PipelineStep(
      id: 'verify-cleanup',
      title: 'Verify Cleanup',
      description: 'Check staged, trashed, and synced media counts.',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', ['scripts/07_verify_cleanup.sh']),
    ),
    PipelineStep(
      id: 'verify-immich',
      title: 'Verify Immich',
      description: 'Check Immich container and external-library visibility.',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', ['scripts/10_verify_immich.sh']),
      requiredTools: ['docker'],
      linuxOnly: true,
    ),
    PipelineStep(
      id: 'restore-dry-run',
      title: 'Review Restore Plan',
      description: 'Dry-run restore from media_trash. No files are moved.',
      risk: PipelineRisk.safe,
      command: PipelineCommand('bash', ['scripts/11_restore_from_trash.sh']),
    ),
    PipelineStep(
      id: 'restore-confirm',
      title: 'Restore From Trash',
      description:
          'Confirm restore from media_trash back to original locations.',
      risk: PipelineRisk.confirmRequired,
      command: PipelineCommand('bash', [
        'scripts/11_restore_from_trash.sh',
        '--confirm',
      ]),
      requiresDryRunStepId: 'restore-dry-run',
    ),
  ];
}

/// Step IDs chained automatically by the "guided run" consolidated mode, in
/// run order. This intentionally excludes every `PipelineRisk.confirmRequired`
/// step — those always require a separate, explicit, human-triggered action
/// and must never be reachable from the automatic chain.
///
/// It also excludes every step that is interactive or needs elevated
/// privileges and therefore cannot run unattended:
/// - `setup-dependencies` (`01_setup_dependencies.sh`) makes `sudo` calls.
/// - `configure-rclone` (`02_configure_rclone.sh`) runs the interactive
///   `rclone config` wizard on stdin/stdout. `PipelineRunner.run()` closes
///   child stdin immediately whenever a step has no `stdinText`, so this
///   step would simply hang (or error) if it were ever auto-chained.
/// - `setup-immich`/`verify-immich` (Docker-dependent, linux-only) and the
///   Immich takeout-duplicate dry-run are likewise left out of the
///   automatic chain, same as before.
///
/// These stay in the per-step manual list as one-time/occasional setup
/// actions a human runs directly, not as part of an unattended chain.
///
/// The guided run still pauses at two real decision points even though the
/// next guided step is not itself confirm-gated: see
/// [guidedRunCheckpointStepIds].
const List<String> guidedRunStepIds = [
  'check-system',
  'stitch-metadata',
  'scan-duplicates',
  'delete-dry-run',
  'verify-cleanup',
  'sync-immich',
];

/// Step IDs after which the guided run must stop and wait for an explicit
/// human action before continuing, even on success.
///
/// - `delete-dry-run`: pause here so a human can review the dedup dry-run
///   report before anyone runs `06_delete_duplicates.sh --confirm`.
/// - `sync-immich`: pause here so a human can review the synced library
///   before triggering an Immich rescan.
const Set<String> guidedRunCheckpointStepIds = {
  'delete-dry-run',
  'sync-immich',
};

/// Returns the ordered [PipelineStep]s that make up the guided run's
/// automatic chain, resolved from [buildPipelineSteps].
///
/// Throws a [StateError] if a referenced step is missing or if any resolved
/// step is `PipelineRisk.confirmRequired` — that would violate the
/// confirm-gate safety invariant, so this fails loudly instead of silently
/// auto-triggering a destructive confirm step.
List<PipelineStep> buildGuidedRunSteps() {
  final byId = {for (final step in buildPipelineSteps()) step.id: step};
  return [for (final id in guidedRunStepIds) _resolveGuidedStep(byId, id)];
}

PipelineStep _resolveGuidedStep(Map<String, PipelineStep> byId, String id) {
  final step = byId[id];
  if (step == null) {
    throw StateError('Guided run references unknown step id "$id".');
  }
  if (step.risk == PipelineRisk.confirmRequired) {
    throw StateError(
      'Guided run must never include confirm-gated step "$id".',
    );
  }
  return step;
}

/// Splits [guidedRunStepIds] into ordered segments, breaking after each ID in
/// [guidedRunCheckpointStepIds]. The guided run executes one segment at a
/// time and stops between segments for the human checkpoints described
/// there.
List<List<String>> buildGuidedRunSegments() {
  final segments = <List<String>>[];
  var current = <String>[];
  for (final id in guidedRunStepIds) {
    current.add(id);
    if (guidedRunCheckpointStepIds.contains(id)) {
      segments.add(List.unmodifiable(current));
      current = [];
    }
  }
  if (current.isNotEmpty) {
    segments.add(List.unmodifiable(current));
  }
  return List.unmodifiable(segments);
}

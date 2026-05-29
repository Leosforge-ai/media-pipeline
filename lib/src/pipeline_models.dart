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
  const PipelineCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
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
  });

  final String id;
  final String title;
  final String description;
  final PipelineRisk risk;
  final PipelineCommand command;
  final List<String> requiredTools;
  final String? requiresDryRunStepId;
  final bool linuxOnly;

  bool get requiresPriorDryRun => requiresDryRunStepId != null;
}

class PipelineRunResult {
  const PipelineRunResult({required this.exitCode, required this.output});

  final int exitCode;
  final String output;

  bool get succeeded => exitCode == 0;
}

class StepRunState {
  const StepRunState({
    this.status = PipelineStepStatus.idle,
    this.exitCode,
    this.log = '',
  });

  final PipelineStepStatus status;
  final int? exitCode;
  final String log;

  StepRunState copyWith({
    PipelineStepStatus? status,
    int? exitCode,
    String? log,
  }) {
    return StepRunState(
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      log: log ?? this.log,
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

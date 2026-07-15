import 'dart:io';

import 'clean_takeout_duplicates.dart';
import 'delete_duplicates.dart';
import 'restore_from_trash.dart';
import 'stitch_metadata.dart';
import 'tools_container.dart';

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

/// A chunk of live log output from a running step — fired for every piece
/// of output a step produces, whether it comes from a subprocess's
/// stdout/stderr (see [PipelineRunner.run]'s existing `Process.start` path)
/// or from a Dart-native [PipelineDartAction] calling it directly. Callers
/// (e.g. the step-log UI) see identical behavior either way.
typedef LogSink = void Function(String chunk);

/// A Dart-native, in-process step action: an alternative to
/// [PipelineStep.command] that runs without spawning a subprocess (e.g. by
/// calling into `ToolsContainer` directly) but must still honor the exact
/// same external contract [PipelineRunner.run] guarantees for a
/// subprocess-backed step — same [PipelineRunResult] shape, same live
/// `onLog` streaming semantics, no way to bypass the confirm-gate/dry-run
/// invariants that today only exist because a human supplies `--confirm`
/// as an explicit extra argument to a real subprocess.
///
/// See [PipelineStep.dartAction] and `PipelineRunner.run` in
/// `pipeline_runner.dart` for how this is invoked.
typedef PipelineDartAction =
    Future<PipelineRunResult> Function(PipelineSettings settings, LogSink? onLog);

class PipelineStep {
  const PipelineStep({
    required this.id,
    required this.title,
    required this.description,
    required this.risk,
    this.command,
    this.dartAction,
    this.requiredTools = const [],
    this.requiresDryRunStepId,
    this.linuxOnly = false,
    this.requiresDuplicateThumbnailReview = false,
  }) : assert(
         (command == null) != (dartAction == null),
         'PipelineStep must set exactly one of `command` or `dartAction`, never both/neither.',
       );

  final String id;
  final String title;
  final String description;
  final PipelineRisk risk;

  /// The subprocess this step runs, via `Process.start` — see
  /// `PipelineRunner.run`. Mutually exclusive with [dartAction]: a step has
  /// exactly one execution mechanism, enforced by this class's constructor
  /// assert. Every step in [buildPipelineSteps] currently uses this field;
  /// no step uses [dartAction] yet (see issue #76's roadmap — this is
  /// plumbing-only, real step migrations are later PRs).
  final PipelineCommand? command;

  /// A Dart-native, in-process alternative to [command] — see
  /// [PipelineDartAction]'s doc comment. Mutually exclusive with [command].
  final PipelineDartAction? dartAction;
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
      dartAction: runStitchMetadataStep,
      // `exiftool`/`unzip`/`tar` now run inside the `ToolsContainer` this
      // step starts itself (Docker required), not on the host directly;
      // `rsync` (raw Google Drive merge) still shells out on the host —
      // see `runStitchMetadataStep`'s doc comment. Deliberately not marked
      // `linuxOnly` (unlike `immich-takeout-duplicate-dry-run` below): this
      // step is part of the automatic guided-run chain
      // (`guidedRunStepIds`) and was never OS-restricted before this PR
      // (the whole app already assumes POSIX-style paths —
      // `PipelineSettings.defaults()`'s hardcoded `/mnt/target_drive` — so
      // this migration doesn't newly narrow anything); a `ToolsContainer`
      // failure (e.g. Docker not running) now surfaces as a visible failed
      // step via the stuck-UI-state fix, rather than a new hard OS gate.
      requiredTools: ['docker', 'rsync'],
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
      dartAction: runDeleteDryRunStep,
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
      dartAction: runImmichTakeoutDuplicateDryRunStep,
      // `sha256sum` now runs inside the `ToolsContainer` this step starts
      // itself, not on the host directly.
      requiredTools: ['docker'],
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
      dartAction: runRestoreDryRunStep,
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

// ---------------------------------------------------------------------------
// Dart-native step actions (issue #76): wiring the already-ported,
// already-container-routed Dart modules (`delete_duplicates.dart`,
// `restore_from_trash.dart`, `clean_takeout_duplicates.dart`,
// `stitch_metadata.dart`) into real [PipelineStep]s via
// [PipelineStep.dartAction], for the four SAFE/dry-run-or-non-destructive
// steps in scope for this migration. `delete-confirm`/`restore-confirm`
// (`PipelineRisk.confirmRequired`) are deliberately left on `command` —
// out of scope, deferred to a dedicated future PR with extra review.
// `scan-duplicates` (`05_cleanup_scan.sh`) has no Dart port at all (only
// `06`'s report-parsing/dry-run logic was ported, not `05`'s own Czkawka
// scan invocation) and is likewise left on `command`.
//
// ## Design note: none of these catch a thrown exception from the
// underlying ported module
//
// [PipelineRunner.run] deliberately propagates a `dartAction`'s uncaught
// throw rather than swallowing it into a fake result (see
// `pipeline_runner.dart`'s own doc comment and
// `pipeline_runner_test.dart`'s "runner propagates an uncaught throw..."
// test) — `media_pipeline_app.dart`'s two step-run call sites are the
// layer responsible for catching it and resetting the running-step UI
// state, matching how a subprocess step's non-zero exit is already
// surfaced (see that file's `_runSelectedStep`/`_runNextGuidedSegment`
// comments on the stuck-UI-state fix). Catching here too would just
// duplicate that handling inconsistently per step. The one exception is
// [runRestoreDryRunStep]'s narrow catch of [TrashRootNotFoundException] —
// a well-known, always-possible condition (nothing has ever been trashed
// yet) that the real Bash script also reports via a plain non-zero exit
// rather than a crash, so converting it to a clean failed
// [PipelineRunResult] here is parity with that behavior, not an attempt to
// hide a real bug.
//
// ## Design note: `ToolsContainer` lifecycle — one session per step run
//
// [runImmichTakeoutDuplicateDryRunStep] and [runStitchMetadataStep] each
// open and close their own [ToolsContainer] session (via
// [ToolsContainer.withSession]) for the duration of that one step run,
// rather than sharing one long-lived container across steps. These are
// independent pipeline steps a human runs one at a time from the app's
// step list or the guided run chain — never concurrently — so there is no
// real overlap window where a shared session would save a meaningful
// amount of container start/stop overhead, and a per-step session keeps
// each step's container lifecycle trivially easy to reason about (no risk
// of one step's failure leaving a container another step unexpectedly
// inherits, and cleanup is guaranteed by `withSession`'s own
// `try`/`finally`).

/// Joins [basePath] and [child] with a single `/`, tolerating a trailing
/// slash on [basePath] — the same convention `config/pipeline_config.sh` /
/// `config/pipeline_config.py` use for every `$HD_PATH`-derived path
/// (`cleaning_staging`, `media_trash`, `immich_library`, ...).
String _pipelineChildPath(String basePath, String child) {
  final trimmed = basePath.endsWith('/') && basePath.length > 1
      ? basePath.substring(0, basePath.length - 1)
      : basePath;
  return '$trimmed/$child';
}

/// Dart-native replacement for `bash scripts/06_delete_duplicates.sh` run
/// without `--confirm` — the `delete-dry-run` step. Wraps
/// [DuplicateDeleter], reading the same three Czkawka reports the Bash
/// script reads (`$REPORT_DIR/duplicate_{images,videos,files}.txt`) and
/// rendering its structured decisions via [renderDryRunKeepTrashLines] into
/// the exact `Keep: `/`Would trash: ` line format
/// `duplicate_report.dart`'s `parseDuplicateDryRunOutput` already parses for
/// the thumbnail-diff review dialog (issue #49) — proven equivalent by
/// `test/delete_duplicates_test.dart`'s format-compatibility test, and
/// re-verified end-to-end against this exact wiring by
/// `test/pipeline_models_test.dart`. `confirm` is always `false`: this
/// step never touches the filesystem beyond reading the three report
/// files. No external tools/`ToolsContainer` involved — `DuplicateDeleter`
/// makes zero external-tool calls (Phase 2 of issue #76 already confirmed
/// this via `grep`).
Future<PipelineRunResult> runDeleteDryRunStep(
  PipelineSettings settings,
  LogSink? onLog,
) async {
  // `buffer` accumulates every line this step "prints", exactly mirroring
  // what a subprocess step's captured combined stdout+stderr (`output`)
  // would contain — `emit` is defined before any output is produced (and
  // used for every single line, including the very first one) so that the
  // final `PipelineRunResult.output`/`stdoutOutput` (which *replaces*, not
  // appends to, the live-streamed `onLog` transcript — see
  // `media_pipeline_app.dart`'s `_runSelectedStep`) never silently drops a
  // line that only ever went out live via `onLog`.
  final buffer = StringBuffer();
  void emit(String line) {
    buffer.writeln(line);
    onLog?.call('$line\n');
  }

  final stagingRoot = _pipelineChildPath(settings.hdPath, 'cleaning_staging');
  final trashRoot = _pipelineChildPath(settings.hdPath, 'media_trash');
  final reportPaths = [
    _pipelineChildPath(settings.reportDir, 'duplicate_images.txt'),
    _pipelineChildPath(settings.reportDir, 'duplicate_videos.txt'),
    _pipelineChildPath(settings.reportDir, 'duplicate_files.txt'),
  ];

  emit('DRY RUN MODE: no files will be moved');

  final deleter = DuplicateDeleter(
    stagingRoot: stagingRoot,
    trashRoot: trashRoot,
  );
  final reportOutcomes = await deleter.run(
    reportPaths: reportPaths,
    confirm: false,
  );

  for (final outcome in reportOutcomes) {
    if (!outcome.found) {
      continue;
    }
    emit('==> Processing duplicate report: ${outcome.reportPath}');
    final rendered = renderDryRunKeepTrashLines(outcome.groups);
    buffer.write(rendered);
    onLog?.call(rendered);
  }

  emit('Done.');
  emit('Dry-run complete. Review the output. Do NOT blindly run --confirm.');

  final text = buffer.toString();
  return PipelineRunResult(exitCode: 0, output: text, stdoutOutput: text);
}

/// Dart-native replacement for `bash scripts/11_restore_from_trash.sh` run
/// without `--confirm` — the `restore-dry-run` step. Wraps
/// [TrashRestorer], never touching the filesystem beyond listing
/// `$HD_PATH/media_trash` (`confirm` is always `false`). No external
/// tools/`ToolsContainer` involved — `TrashRestorer` makes zero
/// external-tool calls.
///
/// If the trash root doesn't exist yet (nothing has ever been moved to
/// it), reports that as a failed run (non-zero exit) — mirroring the Bash
/// script's own `set -e` hard failure on `find` against a missing
/// directory (see [TrashRootNotFoundException]'s doc comment); this is
/// expected, parity-preserving behavior, not a bug in this port.
Future<PipelineRunResult> runRestoreDryRunStep(
  PipelineSettings settings,
  LogSink? onLog,
) async {
  // See `runDeleteDryRunStep`'s doc comment on why `emit` (not a
  // live-only `onLog` call) is used for every line, from the very first.
  final buffer = StringBuffer();
  void emit(String line) {
    buffer.writeln(line);
    onLog?.call('$line\n');
  }

  final trashRoot = _pipelineChildPath(settings.hdPath, 'media_trash');
  emit('DRY RUN MODE: no files will be moved');

  const restorer = TrashRestorer();
  final List<RestoreOutcome> outcomes;
  try {
    outcomes = await restorer.run(trashRoot: trashRoot, confirm: false);
  } on TrashRootNotFoundException catch (error) {
    emit('Trash root does not exist: $trashRoot ($error)');
    final text = buffer.toString();
    return PipelineRunResult(exitCode: 1, output: text, stdoutOutput: text);
  }

  for (final outcome in outcomes) {
    emit('Would restore: ${outcome.trashPath} -> ${outcome.destinationPath}');
  }
  emit('Dry-run only. Re-run with --confirm to restore.');

  final text = buffer.toString();
  return PipelineRunResult(exitCode: 0, output: text, stdoutOutput: text);
}

/// Dart-native replacement for
/// `bash scripts/12_clean_immich_takeout_duplicates.sh` run with no CLI
/// argument (dry-run mode) — the `immich-takeout-duplicate-dry-run` step.
/// Wraps [TakeoutDuplicateCleaner], routing its one external tool
/// (`sha256sum`) through a fresh [ToolsContainer] session started and torn
/// down for the duration of this single step run (see this file's
/// "ToolsContainer lifecycle" design note above). `confirm` is always
/// `false`: nothing is ever moved by this step.
Future<PipelineRunResult> runImmichTakeoutDuplicateDryRunStep(
  PipelineSettings settings,
  LogSink? onLog,
) async {
  // See `runDeleteDryRunStep`'s doc comment on why `emit` (not a
  // live-only `onLog` call) is used for every line, from the very first.
  final buffer = StringBuffer();
  void emit(String line) {
    buffer.writeln(line);
    onLog?.call('$line\n');
  }

  final trashRoot = _pipelineChildPath(settings.hdPath, 'media_trash');
  final immichLibrary = _pipelineChildPath(settings.hdPath, 'immich_library');
  final googleFotosDir = '$immichLibrary/Takeout/Google Fotos';

  emit('DRY RUN MODE: no files will be moved.');

  final summary = await ToolsContainer.withSession(
    hostMountRoot: settings.hdPath,
    body: (container) {
      final cleaner = TakeoutDuplicateCleaner(
        trashRoot: trashRoot,
        hasher: containerFileHasher(container: container),
      );
      return cleaner.run(googleFotosDir: googleFotosDir, confirm: false);
    },
  );

  if (summary.yearFolders.isEmpty) {
    emit('Google Fotos folder not found: $googleFotosDir');
    emit('Nothing to do.');
  } else {
    for (final yearFolder in summary.yearFolders) {
      if (!yearFolder.canonicalDirFound) {
        emit(
          'Missing canonical year folder for Fotos de ${yearFolder.year}: '
          '${yearFolder.canonicalDir}',
        );
        continue;
      }
      for (final candidate in yearFolder.candidates) {
        switch (candidate.action) {
          case TakeoutDuplicateAction.wouldMove:
            emit(
              'Would move duplicate: ${candidate.duplicatePath} -> '
              '${candidate.destinationPath}',
            );
            emit('Kept canonical: ${candidate.canonicalPath}');
          case TakeoutDuplicateAction.missingCanonical:
            emit(
              'Missing canonical for ${yearFolder.year}: '
              '${candidate.duplicatePath}',
            );
          case TakeoutDuplicateAction.sizeMismatch:
            emit('Size mismatch, skipping: ${candidate.duplicatePath}');
          case TakeoutDuplicateAction.hashMismatch:
            emit('Hash mismatch, skipping: ${candidate.duplicatePath}');
          case TakeoutDuplicateAction.refusedOutsideLocalized:
            emit(
              'Refusing outside localized folder: '
              '${candidate.duplicatePath}',
            );
          case TakeoutDuplicateAction.moved:
          case TakeoutDuplicateAction.movedWithSuffix:
            // Unreachable in dry-run mode (confirm is always false above).
            break;
        }
      }
    }
  }

  emit('');
  emit('Summary');
  emit('-------');
  emit('Candidates inspected: ${summary.inspected}');
  emit('Verified duplicates:  ${summary.verified}');
  emit('Moved to trash:       0');
  emit('Missing canonical:    ${summary.skippedMissingCanonicalFile}');
  emit('Size mismatches:      ${summary.skippedSize}');
  emit('Hash mismatches:      ${summary.skippedHash}');
  emit('');
  emit('Dry-run complete. Inspect the output before running --confirm.');

  final text = buffer.toString();
  return PipelineRunResult(exitCode: 0, output: text, stdoutOutput: text);
}

/// Dart-native replacement for `python3 scripts/04_stitch_metadata.py` —
/// the `stitch-metadata` step (`PipelineRisk.reviewRequired`: it extracts
/// archives and writes files, but has no confirm-gate/dry-run split in the
/// existing model). Wraps [MetadataStitcher], routing its three external
/// tools (`unzip`/`tar`/`exiftool`) through a fresh [ToolsContainer]
/// session for the duration of this step run (see this file's
/// "ToolsContainer lifecycle" design note above, which applies identically
/// here).
///
/// [MetadataStitcher.run]'s own `print` callback is wired straight to
/// [onLog] so a human watching this (potentially long-running, real-archive
/// extraction) step sees the same live `==> ...` progress lines the Python
/// script prints, not just a result dumped at the end. Its `warnOverride`
/// parameter is also wired so per-file warnings (which, by default, only go
/// to the warning log file and the real OS stderr — invisible to this
/// in-process caller) are *also* forwarded to [onLog], matching what a
/// subprocess step's captured stderr would have shown a human watching the
/// log live (Cody's PR #99 review finding on `dartAction` log visibility).
///
/// Per this port's own hard safety rule (mirrored from the Python
/// original — see `stitch_metadata.dart`'s module doc comment): an
/// archive-level failure is deliberately allowed to propagate uncaught
/// from this function (the failing archive stays in `raw_takeout_zips` for
/// a retry, per that module's own `run()` implementation) — see this
/// file's "none of these catch a thrown exception" design note above for
/// why that's intentional, not a gap. A per-media-file failure never
/// aborts anything and is only ever logged as a warning by
/// [MetadataStitcher] itself.
Future<PipelineRunResult> runStitchMetadataStep(
  PipelineSettings settings,
  LogSink? onLog,
) async {
  final buffer = StringBuffer();
  void emit(String line) {
    buffer.writeln(line);
    onLog?.call('$line\n');
  }

  final summary = await ToolsContainer.withSession(
    hostMountRoot: settings.hdPath,
    body: (container) {
      final stitcher = MetadataStitcher(
        exiftool: containerExiftoolRunner(container: container),
        archiveExtractor: containerTakeoutArchiveExtractor(
          container: container,
        ),
      );
      return stitcher.run(
        settings.hdPath,
        print: emit,
        warnOverride: (message) async {
          final defaultWarn = fileWarningLogger(settings.hdPath);
          await defaultWarn(message);
          emit('WARNING: $message');
        },
      );
    },
  );

  emit(
    'Metadata stitching finished. Archives processed: '
    '${summary.archivesProcessed}; media moved: ${summary.mediaMoved}; '
    'warnings: ${summary.warnings}.',
  );

  final text = buffer.toString();
  return PipelineRunResult(exitCode: 0, output: text, stdoutOutput: text);
}

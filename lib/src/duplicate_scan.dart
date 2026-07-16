/// Dart port of `scripts/05_cleanup_scan.sh`'s Czkawka-scan invocation —
/// the last remaining gap in issue #76 Phase 2 (issue #103): every other
/// pipeline step with a Dart port already runs it in production, but
/// `scan-duplicates` still shelled out to Bash because no Dart port of the
/// actual `czkawka_cli` scan invocation existed (only `06`'s report-parsing
/// logic was ported, in `delete_duplicates.dart` — that module reads the
/// report files *this* module produces, it doesn't produce them).
///
/// Mirrors the Bash script's functional core:
/// - The stale-report cleanup (`rm -f duplicate_images.txt ...`) ->
///   [DuplicateScanRunner.run]'s first step.
/// - The 3-scan sequence (`image`/`video`/`dup` subcommands) and, most
///   importantly, `run_czkawka_scan()`'s hard-won exit-code classification
///   (issue #81/PR #83, refined in the Phase 16 review-fix pass) ->
///   [isCzkawkaScanExitFatal] and [runSingleCzkawkaScan]. **This
///   classification is preserved exactly, not re-derived**: only exit `0`
///   (nothing found) and `11` (czkawka's fixed "found duplicates/similar
///   items" sentinel — a constant, confirmed against
///   `czkawka_cli/src/main.rs` upstream, not a variable found-count) are
///   treated as non-fatal. Every other exit code — `101` (uncaught Rust
///   panic), `126`/`127` (exec errors), `128+N` signal deaths including
///   `137` (OOM-kill, materially likelier now that `czkawka_cli` runs inside
///   a container) and `139` (SIGSEGV), and anything else — aborts, matching
///   this repo's fail-closed, data-loss-prevention-first posture: silently
///   trusting a truncated/corrupt report from a real crash is worse than an
///   occasional false-positive abort.
/// - `czkawka_cli` execution routed through [ToolsContainer] (already
///   bundled in the `media-pipeline-tools` image, Phase 1), following the
///   same per-step-session `ToolsContainer.withSession` pattern PR #100
///   established for the other consumer migrations.
///
/// ## Design decision: no `tee`/`PIPESTATUS` fight in the Dart port
///
/// The Bash script's `run_czkawka_scan()` needs `PIPESTATUS[0]` specifically
/// because it pipes `czkawka_cli` through `tee` under `set -euo pipefail` —
/// without that, `pipefail` would propagate `tee`'s (always-zero, since
/// writing to a log file rarely fails) exit code instead of `czkawka_cli`'s
/// real one. [ToolsContainer.exec] (`docker exec`, no shell pipe involved)
/// returns `czkawka_cli`'s real exit code directly as
/// [ProcessResult.exitCode] — there is no pipe to lose information through,
/// so there is no Dart equivalent of the `PIPESTATUS` fight to reproduce.
/// The *classification* of that exit code ([isCzkawkaScanExitFatal]) is
/// still ported exactly, since that is the actual safety-relevant logic —
/// only the bash-specific plumbing needed to reliably observe it is
/// structurally unnecessary here.
///
/// ## Design decision: report files are staged under `$HD_PATH`, then copied
/// to the real report directory
///
/// [ToolsContainer] bind-mounts exactly one host directory
/// (`hostMountRoot`, `settings.hdPath` at the real call site in
/// `pipeline_models.dart`) into the container. `$CLEANING_STAGING` is
/// always under `$HD_PATH`, so it translates cleanly via
/// [ToolsContainer.hostToContainerPath] — but `$REPORT_DIR` defaults to
/// `$HOME/czkawka_reports` (see `pipeline_models.dart`'s
/// `PipelineSettings.defaults()`), which is **not** under `$HD_PATH` in the
/// common case, so `czkawka_cli -f` (given a path under `REPORT_DIR`) run inside the
/// container has no way to reach it directly (the container's filesystem
/// view is limited to what's bind-mounted). Rather than widen
/// [ToolsContainer] to support multiple bind mounts (a real option, but a
/// structural change to shared infrastructure only this one consumer would
/// need), [DuplicateScanRunner.run] has `czkawka_cli` write its `-f` report
/// into a small, hidden, host-visible staging directory it creates under
/// `$HD_PATH` itself ([kDuplicateScanTempDirName]) — since that directory
/// is inside the one mount [ToolsContainer] already has, no new mount is
/// needed. Because a bind mount is the *same* filesystem viewed from two
/// places, not a copy, the file the container writes there is immediately
/// readable from the host side with plain `dart:io` —
/// [DuplicateScanRunner.run] reads it directly (no `docker exec cat`
/// round-trip needed) and copies its content to the real
/// `reportDir` location before deleting the temp directory in a `finally`
/// block. This does introduce one small, deliberate behavior difference
/// from the Bash script: a transient, hidden directory briefly exists under
/// `$HD_PATH` during a scan (cleaned up unconditionally afterward, success
/// or failure) that the Bash script never created — flagged here
/// explicitly, not silently.
///
/// ## `czkawka_cli` needs a writable `$HOME` — now fixed at the
/// `ToolsContainer` level (issue #105)
///
/// Manually exercising the real `czkawka_cli` binary from the
/// `media-pipeline-tools` image (the same one [ToolsContainer] runs)
/// against a container started with `--user <host-uid>:<host-gid>` — the
/// exact override [ToolsContainer.start] applies (Phase 3, #76) — surfaced
/// a real bug this port had to route around: with no `$HOME` set (the
/// arbitrary host uid has no matching `/etc/passwd` entry inside the
/// container, so the shell's default `$HOME` is `/`, which that uid cannot
/// write to), `czkawka_cli` panics writing its cache database and exits
/// `101` — the exact "genuine crash" code this module's own exit-code
/// classification is designed to catch and abort on. This was originally
/// fixed here with a per-invocation `env HOME=...` ahead of every
/// `czkawka_cli` call; per issue #105, that fix now lives in
/// [ToolsContainer.start] itself (`-e HOME=/tmp` on `docker run`, applied
/// whenever the `--user` override is active), so this module no longer
/// needs to know about it at all — every `docker exec` into the container
/// already has a writable `$HOME`. Verified empirically against the real
/// image (`test/duplicate_scan_test.dart`'s Docker-gated parity test): the
/// same `dup` scan against real duplicate files, run with no per-call
/// `HOME` override, succeeds normally (exit 11, real report written) now
/// that the container itself sets `$HOME`.
///
/// ## Design decision: blur-scan (ImageMagick `convert`) is NOT ported —
/// see issue #103's task brief, option (b)
///
/// `docker/tools/Dockerfile` does not bundle ImageMagick. Adding it (option
/// (a) in issue #103) was considered and rejected for this PR: it would
/// expand the tools image's scope for a feature (`RUN_BLUR_SCAN`) that
/// nothing downstream in this app actually consumes yet (no report parser,
/// no UI, no pipeline step reads `blurry_images.txt` today — it's
/// operator-facing output only), and this port's own brief is specifically
/// the duplicate-detection scans `delete_duplicates.dart` depends on, not
/// growing the tools image. Blur-scan capability is **not silently
/// dropped**: it still exists, unchanged, in `scripts/05_cleanup_scan.sh`
/// (`RUN_BLUR_SCAN=1` by default) — an operator who wants it runs that
/// script directly. [DuplicateScanRunner.run] does not touch
/// `blurry_images.txt`/`blur_scan_run.log` at all (neither writes nor
/// deletes them), so a blur report from a prior manual Bash run is never
/// silently discarded by a Dart-native scan.
///
/// ## Design decision: run logs are still written, for parity with the
/// stale-report cleanup behavior
///
/// The Bash script's stale-file cleanup deletes both the 3 report files
/// and their 3 `_run.log` companions before every run, and writes a fresh
/// log for each scan via `tee`. [DuplicateScanRunner.run] mirrors both
/// halves: it deletes the same 6 file paths (report + log, per scan kind;
/// never the blur-scan files — see above) at the start of every run, and
/// writes each scan's combined stdout+stderr to its `_run.log` companion
/// after the scan completes, even though nothing in this Dart-native path
/// currently re-reads those log files (parity/operator-debugging value,
/// not a functional dependency).
library;

import 'dart:io';

import 'tools_container.dart';

/// The filename `czkawka_cli image -f ...` writes to, matching the Bash
/// script exactly.
const String kDuplicateImagesReportFile = 'duplicate_images.txt';

/// The filename `czkawka_cli video -f ...` writes to, matching the Bash
/// script exactly.
const String kDuplicateVideosReportFile = 'duplicate_videos.txt';

/// The filename `czkawka_cli dup -f ...` writes to, matching the Bash
/// script exactly.
const String kDuplicateFilesReportFile = 'duplicate_files.txt';

/// Run-log companion for [kDuplicateImagesReportFile]'s scan.
const String kImageScanRunLogFile = 'image_scan_run.log';

/// Run-log companion for [kDuplicateVideosReportFile]'s scan.
const String kVideoScanRunLogFile = 'video_scan_run.log';

/// Run-log companion for [kDuplicateFilesReportFile]'s scan.
const String kDuplicateFilesScanRunLogFile = 'duplicate_files_run.log';

/// The hidden staging directory [DuplicateScanRunner.run] creates directly
/// under the scanned host mount root (`$HD_PATH` at the real call site) —
/// see this file's top-level "report files are staged under `$HD_PATH`"
/// design decision. Removed again (best-effort) at the end of every
/// [DuplicateScanRunner.run] call, success or failure.
const String kDuplicateScanTempDirName = '.duplicate_scan_tmp';

/// `czkawka_cli`'s fixed exit code for "scan ran, found duplicates/similar
/// items" — a constant, not a variable found-count (confirmed against
/// `czkawka_cli/src/main.rs` upstream; see this file's top-level doc
/// comment and issue #81/PR #83's original investigation).
const int kCzkawkaFoundSentinelExitCode = 11;

/// Port of `run_czkawka_scan()`'s exit-code classification: `true` for
/// every exit code that is a genuine tool failure and must abort the scan,
/// `false` for the two known-safe codes (`0` = nothing found,
/// [kCzkawkaFoundSentinelExitCode] = found something). A denylist of
/// known-safe codes, not an allowlist of known-fatal ones — this is
/// deliberately fail-closed: it automatically covers `101` (Rust panic),
/// `126`/`127` (exec errors), every `128+N` signal-death code (`137`
/// OOM-kill, `139` SIGSEGV, ...), and any other code this module's authors
/// never thought to enumerate, exactly matching the real Bash script's
/// `05_cleanup_scan.sh` (post Phase 16 review-fix) semantics.
bool isCzkawkaScanExitFatal(int exitCode) =>
    exitCode != 0 && exitCode != kCzkawkaFoundSentinelExitCode;

/// Which `czkawka_cli` subcommand a scan runs, and the report/log filenames
/// it corresponds to — the three scans `05_cleanup_scan.sh` always runs, in
/// the same order.
enum CzkawkaScanKind {
  image(
    subcommand: 'image',
    description: 'similar image scan',
    reportFile: kDuplicateImagesReportFile,
    logFile: kImageScanRunLogFile,
  ),
  video(
    subcommand: 'video',
    description: 'similar video scan',
    reportFile: kDuplicateVideosReportFile,
    logFile: kVideoScanRunLogFile,
  ),
  dup(
    subcommand: 'dup',
    description: 'exact duplicate file scan',
    reportFile: kDuplicateFilesReportFile,
    logFile: kDuplicateFilesScanRunLogFile,
  );

  const CzkawkaScanKind({
    required this.subcommand,
    required this.description,
    required this.reportFile,
    required this.logFile,
  });

  /// The `czkawka_cli` subcommand (`image`/`video`/`dup`).
  final String subcommand;

  /// Human-readable description, matching the Bash script's own
  /// `run_czkawka_scan` call-site strings exactly (e.g. `"similar image
  /// scan"`), so log lines read identically to what an operator watching
  /// the real Bash script's live output would see.
  final String description;

  final String reportFile;
  final String logFile;
}

/// Thrown by [runSingleCzkawkaScan] when `czkawka_cli` exits with a code
/// [isCzkawkaScanExitFatal] classifies as a genuine failure. Mirrors the
/// real Bash script's `exit 1` in that branch of `run_czkawka_scan()` —
/// deliberately left to propagate uncaught from [DuplicateScanRunner.run]
/// (see `pipeline_models.dart`'s "none of these catch a thrown exception"
/// design note): a real `czkawka_cli` crash is not a well-known, expected
/// condition the way a missing `$MEDIA_TRASH` is for
/// `runRestoreDryRunStep`, so it is surfaced the same way any other
/// unanticipated `dartAction` failure is — as a failed step via the
/// stuck-UI-state handling in `media_pipeline_app.dart`, not silently
/// converted into a clean result.
class CzkawkaScanFailedException implements Exception {
  CzkawkaScanFailedException({
    required this.kind,
    required this.exitCode,
    required this.combinedOutput,
  });

  final CzkawkaScanKind kind;
  final int exitCode;

  /// Combined stdout+stderr from the failed invocation, for diagnostics.
  final String combinedOutput;

  @override
  String toString() =>
      'CzkawkaScanFailedException(${kind.description}, exit $exitCode): '
      'this looks like a real tool failure (crash/signal/exec error), not '
      'the found-duplicates sentinel ($kCzkawkaFoundSentinelExitCode).';
}

/// Thrown when [DuplicateScanRunner.run] is called against a
/// `$CLEANING_STAGING` directory that doesn't exist — mirrors the real Bash
/// script's `[[ -d "$CLEANING_STAGING" ]] || exit 1` check. Like
/// `restore_from_trash.dart`'s `TrashRootNotFoundException`, this is a
/// well-known, always-possible condition (nothing has been staged yet —
/// e.g. `stitch-metadata` hasn't run), so `pipeline_models.dart`'s wiring
/// function catches this specifically and converts it to a clean failed
/// [PipelineRunResult] rather than letting it surface as an uncaught throw.
class CleaningStagingNotFoundException implements Exception {
  CleaningStagingNotFoundException(this.path);

  final String path;

  @override
  String toString() => 'CleaningStagingNotFoundException: $path';
}

/// Runs one `czkawka_cli` scan inside [container] and classifies its exit
/// code, exactly mirroring `run_czkawka_scan()`'s core logic (the
/// `tee`/`PIPESTATUS` plumbing itself is not needed here — see this file's
/// top-level doc comment). No per-call `$HOME` override is needed —
/// [ToolsContainer.start] itself gives the container a writable `$HOME`
/// (issue #105; see this file's top-level "czkawka_cli needs a writable
/// $HOME" doc section).
///
/// Emits progress via [onLog] before running (`"==> Running Czkawka
/// $description"`) and a result line after (no-duplicates vs
/// found-duplicates), matching the Bash script's own live output exactly.
///
/// Throws [CzkawkaScanFailedException] if [isCzkawkaScanExitFatal] the exit
/// code — never silently treats a real failure as "found duplicates."
Future<ProcessResult> runSingleCzkawkaScan({
  required ToolsContainer container,
  required CzkawkaScanKind kind,
  required String stagingContainerPath,
  required String reportContainerPath,
  void Function(String line)? onLog,
}) async {
  onLog?.call('==> Running Czkawka ${kind.description}');

  final result = await container.exec([
    'czkawka_cli',
    kind.subcommand,
    '-d',
    stagingContainerPath,
    '-f',
    reportContainerPath,
  ]);

  final exitCode = result.exitCode;
  if (isCzkawkaScanExitFatal(exitCode)) {
    final combined = '${result.stdout}${result.stderr}';
    throw CzkawkaScanFailedException(
      kind: kind,
      exitCode: exitCode,
      combinedOutput: combined,
    );
  }

  onLog?.call(
    exitCode == 0
        ? '==> Czkawka ${kind.description}: no duplicates found.'
        : '==> Czkawka ${kind.description}: completed, duplicates found '
              '(exit $kCzkawkaFoundSentinelExitCode; see report).',
  );

  return result;
}

/// One completed scan run's result counts, parsed from its report files
/// exactly the way the Bash script's summary section does
/// (`grep -c '^Found .*<kind>' report_file`).
class DuplicateScanSummary {
  const DuplicateScanSummary({
    required this.imageReportPath,
    required this.videoReportPath,
    required this.duplicateFilesReportPath,
    required this.imageGroups,
    required this.videoGroups,
    required this.duplicateFileGroups,
  });

  final String imageReportPath;
  final String videoReportPath;
  final String duplicateFilesReportPath;

  /// Count of lines matching `^Found .*images` in [imageReportPath]'s
  /// content, mirroring `grep -c '^Found .*images' duplicate_images.txt`.
  final int imageGroups;

  /// Count of lines matching `^Found .*videos` in [videoReportPath]'s
  /// content, mirroring `grep -c '^Found .*videos' duplicate_videos.txt`.
  final int videoGroups;

  /// Count of lines matching `^Found .*files` in
  /// [duplicateFilesReportPath]'s content, mirroring `grep -c '^Found
  /// .*files' duplicate_files.txt`.
  final int duplicateFileGroups;
}

final RegExp _imageGroupsPattern = RegExp(r'^Found .*images', multiLine: true);
final RegExp _videoGroupsPattern = RegExp(r'^Found .*videos', multiLine: true);
final RegExp _duplicateFileGroupsPattern = RegExp(
  r'^Found .*files',
  multiLine: true,
);

int _countMatches(String content, RegExp pattern) =>
    pattern.allMatches(content).length;

/// Runs the 3-scan Czkawka sequence `05_cleanup_scan.sh` runs, via an
/// already-started [ToolsContainer] whose `hostMountRoot` covers
/// [stagingDir] (real callers: `settings.hdPath`, with `stagingDir` =
/// `$HD_PATH/cleaning_staging`) — see this file's top-level doc comment for
/// the full set of design decisions this class embodies (temp report
/// staging under the mount root, the `$HOME` fix, blur-scan exclusion, exit
/// -code classification).
class DuplicateScanRunner {
  const DuplicateScanRunner();

  /// Runs all three scans and writes their reports/logs into [reportDir]
  /// (a real, arbitrary host path — need not be under the container's
  /// mounted root; see this file's top-level "report files are staged
  /// under `$HD_PATH`" design decision for how that constraint is worked
  /// around).
  ///
  /// Throws [CleaningStagingNotFoundException] if [stagingDir] doesn't
  /// exist (mirrors the Bash script's own check) — callers should treat
  /// this the same way `runRestoreDryRunStep` treats
  /// `TrashRootNotFoundException` (see that function's doc comment).
  /// Throws [CzkawkaScanFailedException] (propagated, not caught here) if
  /// any scan's exit code is fatal per [isCzkawkaScanExitFatal].
  Future<DuplicateScanSummary> run({
    required String stagingDir,
    required String reportDir,
    required ToolsContainer container,
    void Function(String line)? onLog,
  }) async {
    final stagingDirEntity = Directory(stagingDir);
    if (!await stagingDirEntity.exists()) {
      throw CleaningStagingNotFoundException(stagingDir);
    }

    await Directory(reportDir).create(recursive: true);

    // Stale-report cleanup, mirroring the Bash script's `rm -f` list
    // exactly — the 3 report files + their 3 run logs, never the
    // blur-scan files (`blurry_images.txt`/`blur_scan_run.log`), which
    // this Dart-native path never writes and must never silently discard
    // (see this file's "blur-scan is NOT ported" design decision).
    for (final kind in CzkawkaScanKind.values) {
      await _deleteIfExists('$reportDir/${kind.reportFile}');
      await _deleteIfExists('$reportDir/${kind.logFile}');
    }

    // `stagingDir`'s parent (`$HD_PATH`) is where the temp staging
    // directory lives — see this file's top-level design decision.
    // Computed via `Directory(stagingDir).parent`, not string
    // concatenation, so this works regardless of a trailing slash on
    // `stagingDir`.
    final hdPathHost = stagingDirEntity.parent.path;
    final tempDirHostPath = '$hdPathHost/$kDuplicateScanTempDirName';

    if (await Directory(tempDirHostPath).exists()) {
      await Directory(tempDirHostPath).delete(recursive: true);
    }
    await Directory(tempDirHostPath).create(recursive: true);

    try {
      final stagingContainerPath = container.hostToContainerPath(stagingDir);
      final tempContainerPath = container.hostToContainerPath(
        tempDirHostPath,
      );

      final reportContent = <CzkawkaScanKind, String>{};

      for (final kind in CzkawkaScanKind.values) {
        final reportContainerPath = '$tempContainerPath/${kind.reportFile}';
        final result = await runSingleCzkawkaScan(
          container: container,
          kind: kind,
          stagingContainerPath: stagingContainerPath,
          reportContainerPath: reportContainerPath,
          onLog: onLog,
        );

        final tempReportFile = File('$tempDirHostPath/${kind.reportFile}');
        final content = await tempReportFile.exists()
            ? await tempReportFile.readAsString()
            : '';
        await File('$reportDir/${kind.reportFile}').writeAsString(content);
        reportContent[kind] = content;

        final combinedLog = '${result.stdout}${result.stderr}';
        await File('$reportDir/${kind.logFile}').writeAsString(combinedLog);
      }

      return DuplicateScanSummary(
        imageReportPath: '$reportDir/${CzkawkaScanKind.image.reportFile}',
        videoReportPath: '$reportDir/${CzkawkaScanKind.video.reportFile}',
        duplicateFilesReportPath:
            '$reportDir/${CzkawkaScanKind.dup.reportFile}',
        imageGroups: _countMatches(
          reportContent[CzkawkaScanKind.image] ?? '',
          _imageGroupsPattern,
        ),
        videoGroups: _countMatches(
          reportContent[CzkawkaScanKind.video] ?? '',
          _videoGroupsPattern,
        ),
        duplicateFileGroups: _countMatches(
          reportContent[CzkawkaScanKind.dup] ?? '',
          _duplicateFileGroupsPattern,
        ),
      );
    } finally {
      if (await Directory(tempDirHostPath).exists()) {
        await Directory(tempDirHostPath).delete(recursive: true);
      }
    }
  }
}

Future<void> _deleteIfExists(String path) async {
  final file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}

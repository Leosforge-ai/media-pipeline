import 'dart:io';

import 'filesystem_ops.dart';

/// Dart port of `scripts/06_delete_duplicates.sh` (Phase 0b of issue
/// #76/#77's shared roadmap). This is the highest-stakes port in the
/// series: it is the script that actually decides which file in a Czkawka
/// duplicate group survives and which get moved to `$MEDIA_TRASH`, and the
/// thumbnail-diff review dialog (issue #49, PR #52/#69) exists specifically
/// to let a human double-check this decision before it happens for real.
///
/// Mirrors the Bash script's three functional pieces:
/// - `score_keep_path` -> [scoreKeepPath], a pure function with zero
///   filesystem/subprocess dependency.
/// - `process_czkawka_report`'s report parsing + grouping ->
///   [decideCzkawkaReportGroups], also pure: it only ever treats a line as a
///   path when it starts with a `"..."`-quoted string AND that path is
///   under [DuplicateDeleter.stagingRoot]/the `stagingRoot` argument. Report
///   headers ("Found N files which are duplicates..."), `"..."`-less
///   diagnostic lines, and any quoted string that isn't actually a staging
///   path are never added to a group — matching
///   `.company/forbidden-actions.md`'s explicit rule for this script.
/// - The dry-run/confirm `trash_file` loop -> [DuplicateDeleter.run], the
///   thin async layer that actually touches the filesystem, delegating the
///   real move to the shared [SafeFileMover] primitive in
///   `filesystem_ops.dart` (the same primitive `restore_from_trash.dart`
///   uses), per that file's own doc comment identifying 06/12/13 as its
///   next callers.
///
/// ## Design decision: `duplicate_report.dart` integration (see PR body /
/// `docs/HISTORY.md` for the full writeup)
///
/// This port does **not** change what `PipelineStep`s in
/// `pipeline_models.dart` actually execute: `delete-dry-run` and
/// `delete-confirm` still shell out to the real
/// `scripts/06_delete_duplicates.sh` (matching how Phase 0b's earlier port,
/// `restore_from_trash.dart`, also left `scripts/11_restore_from_trash.sh`
/// wired as the executed script — wiring the container/Dart-native
/// execution path is Phase 2 of issue #76, not this slice). Because of
/// that, `duplicate_report.dart`'s `parseDuplicateDryRunOutput` still reads
/// the real Bash script's real stdout today, completely unchanged by this
/// PR — there is no risk to the existing thumbnail-review dialog from this
/// port landing.
///
/// For when Phase 2 wiring *does* happen, this module deliberately follows
/// `restore_from_trash.dart`'s precedent rather than `06`'s own stdout
/// format: [DuplicateDeleter.run] returns structured [DuplicateReportOutcome]
/// objects (keep path + per-file trash outcomes), not printed text. A
/// helper, [renderDryRunKeepTrashLines], can render those structured
/// outcomes into the exact `Keep: `/`Would trash: ` line format
/// `duplicate_report.dart` parses today — proven equivalent by
/// `test/delete_duplicates_test.dart`'s format-compatibility test — so
/// Phase 2 can choose either to keep `duplicate_report.dart` as a thin
/// compatibility parser over that rendered text, or to have the review UI
/// consume [DuplicateReportOutcome] directly and retire the text parser.
/// That choice is intentionally deferred to Phase 2, when the wiring PR can
/// also update the review dialog's tests end-to-end; making it here would
/// require touching `duplicate_report.dart`/`media_pipeline_app.dart`
/// without the accompanying container/process wiring that would actually
/// exercise the new path, which is exactly the "half-migrated" outcome this
/// task was warned against.
///
/// ## Design decision: trash-move collision handling
///
/// The Bash script's own `trash_file()` resolves a destination collision by
/// appending a numbered suffix (`_1`, `_2`, ...) and always moving — see
/// `unique_destination`-equivalent logic inline in `trash_file()`. This port
/// now matches that exactly via [SafeFileMover.moveRenamingOnCollision]
/// (Leo's #76/#77 review decision, superseding an earlier revision of this
/// port that used [SafeFileMover.moveNoClobber] and skipped on collision —
/// see `filesystem_ops.dart`'s top-level doc comment for the full
/// rationale). The move never leaves a trash candidate un-moved on
/// collision; [DuplicateFileOutcome.destinationPath] reflects the actual
/// path used, which may carry a numbered suffix. This does not affect the
/// keep/trash *decision* logic that the Bash-vs-Dart parity test in
/// `test/delete_duplicates_test.dart` verifies.

// ---------------------------------------------------------------------------
// Pure logic: keep-scoring heuristic
// ---------------------------------------------------------------------------

final RegExp _canonicalYearFolderPattern = RegExp(
  '/Takeout/Google Fotos/[0-9]{4}/',
);
final RegExp _localizedYearFolderPattern = RegExp(
  '/Takeout/Google Fotos/Fotos de [0-9]{4}/',
);

/// Port of `score_keep_path`. Lower score wins (is kept); ties keep the
/// first-encountered group member, matching the Bash script's strict `<`
/// comparison in its `flush_group` loop.
///
/// Order matters and mirrors the Bash `if`/`elif` chain exactly:
/// 1. A clean Google Photos year folder (`.../Takeout/Google Fotos/YYYY/`)
///    scores 0 — the most-preferred, canonical location.
/// 2. A localized-folder-name year copy (`.../Fotos de YYYY/`) scores 10.
/// 3. Any other path under `.../Takeout/Google Fotos/` scores 12.
/// 4. A path under `.../cleaning_staging/Fotos/` scores 20.
/// 5. Anything else scores 5.
int scoreKeepPath(String path) {
  if (_canonicalYearFolderPattern.hasMatch(path)) return 0;
  if (_localizedYearFolderPattern.hasMatch(path)) return 10;
  if (path.contains('/Takeout/Google Fotos/')) return 12;
  if (path.contains('/cleaning_staging/Fotos/')) return 20;
  return 5;
}

// ---------------------------------------------------------------------------
// Pure logic: Czkawka report parsing + grouping
// ---------------------------------------------------------------------------

/// One duplicate group's keep/trash decision, mirroring `flush_group`'s
/// output (`Keep: ...` plus a `trash_file` call for every other member).
class DuplicateGroupDecision {
  const DuplicateGroupDecision({
    required this.keepPath,
    required this.trashPaths,
  });

  /// The lowest-`scoreKeepPath` path in the group (first-encountered on a
  /// tie).
  final String keepPath;

  /// Every other path in the group, in the order they appeared in the
  /// report.
  final List<String> trashPaths;

  @override
  bool operator ==(Object other) =>
      other is DuplicateGroupDecision &&
      other.keepPath == keepPath &&
      _listEquals(other.trashPaths, trashPaths);

  @override
  int get hashCode => Object.hash(keepPath, Object.hashAll(trashPaths));

  @override
  String toString() =>
      'DuplicateGroupDecision(keep: $keepPath, trash: $trashPaths)';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// Only a line that STARTS with a `"..."`-quoted string is ever considered a
// candidate path — matching the Bash script's
// `[[ "$line" =~ ^\"([^\"]+)\" ]]` exactly. A Czkawka report's header line
// ("Found N files which are duplicates"), dimension lines (e.g. a bare
// `1920x1080` with no leading quote), and size annotations (`- 10 KiB`
// trailing text after the quoted path) never match this pattern at the
// *start* of the line, so they are never misread as paths — see
// `.company/forbidden-actions.md`.
final RegExp _quotedLeadingPathPattern = RegExp(r'^"([^"]+)"');
final RegExp _foundHeaderPattern = RegExp(r'^Found ');

/// Port of `process_czkawka_report` + `score_keep_path` + the keep/trash
/// half of `flush_group`. Pure string processing — no filesystem access —
/// so it is directly unit-testable against synthetic report fixtures, and
/// directly comparable against the real Bash script's decisions for a
/// parity test.
///
/// [stagingRoot] mirrors `$CLEANING_STAGING`: only quoted paths that fall
/// under it are ever added to a group, exactly like the Bash script's
/// `[[ "$path" == "$CLEANING_STAGING"/* ]]` filter. A blank line or a
/// `Found ` report-header line ends the current group (`flush_group`),
/// mirroring the Bash script's `while read` loop. Groups of fewer than two
/// members produce no decision (nothing to deduplicate), matching
/// `flush_group`'s `[[ "$n" -lt 2 ]]` early return.
List<DuplicateGroupDecision> decideCzkawkaReportGroups(
  String reportContent, {
  required String stagingRoot,
}) {
  final normalizedRoot = stagingRoot.endsWith('/') && stagingRoot.length > 1
      ? stagingRoot.substring(0, stagingRoot.length - 1)
      : stagingRoot;
  final prefix = '$normalizedRoot/';

  final decisions = <DuplicateGroupDecision>[];
  var group = <String>[];

  void flush() {
    if (group.length < 2) {
      group = <String>[];
      return;
    }
    var bestScore = 999999;
    var keepIndex = 0;
    for (var i = 0; i < group.length; i++) {
      final score = scoreKeepPath(group[i]);
      if (score < bestScore) {
        bestScore = score;
        keepIndex = i;
      }
    }
    final trashPaths = <String>[
      for (var i = 0; i < group.length; i++)
        if (i != keepIndex) group[i],
    ];
    decisions.add(
      DuplicateGroupDecision(
        keepPath: group[keepIndex],
        trashPaths: trashPaths,
      ),
    );
    group = <String>[];
  }

  // Mirrors `while IFS= read -r line || [[ -n "$line" ]]`: process every
  // line, including a final line with no trailing newline. `split('\n')`
  // on content that *does* end with a trailing newline yields one extra
  // empty trailing element, which harmlessly triggers a no-op flush (the
  // group is already flushed, or empty) — equivalent behavior either way.
  for (final line in reportContent.split('\n')) {
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (_foundHeaderPattern.hasMatch(line)) {
      flush();
      continue;
    }
    final match = _quotedLeadingPathPattern.firstMatch(line);
    if (match != null) {
      final path = match.group(1)!;
      if (path.startsWith(prefix)) {
        group.add(path);
      }
    }
    // Any other line (a dimension/size annotation without a leading quote,
    // a quoted path outside staging, a diagnostic line) is silently
    // skipped, exactly like the Bash script's loop, which only ever acts on
    // the two patterns checked above.
  }
  flush();

  return decisions;
}

// ---------------------------------------------------------------------------
// Async orchestration: reads report files and moves trash candidates,
// mirroring `trash_file` and the dry-run/confirm gate.
// ---------------------------------------------------------------------------

/// What happened (or would happen) to one file in a duplicate group other
/// than the kept one.
enum DuplicateFileAction {
  /// Dry-run mode: printed what *would* happen; nothing touched on disk.
  wouldTrash,

  /// Confirm mode: the file was actually moved to `$MEDIA_TRASH`.
  trashed,

  /// Confirm mode: the desired destination already existed, so — matching
  /// [SafeFileMover.moveRenamingOnCollision]'s numbered-suffix semantics —
  /// the file was moved to a suffixed alternative instead. See
  /// [DuplicateFileOutcome.destinationPath] for the actual path used.
  trashedWithSuffix,

  /// The path no longer exists on disk (already moved/deleted out of band
  /// since the report was generated). Mirrors the Bash script's
  /// `[[ ! -f "$src" ]]` -> "Missing, skipping" branch.
  missing,

  /// Defense-in-depth: the path is not actually under
  /// [DuplicateDeleter.stagingRoot]. [decideCzkawkaReportGroups] already
  /// guarantees every group member is under `stagingRoot`, so this should
  /// be unreachable in practice; kept to mirror the Bash script's own
  /// belt-and-suspenders check in `trash_file`.
  refusedOutsideStaging,
}

/// The outcome of processing one trash-candidate file.
class DuplicateFileOutcome {
  const DuplicateFileOutcome({
    required this.path,
    required this.action,
    this.destinationPath,
  });

  final String path;
  final DuplicateFileAction action;

  /// The (would-be) destination under `$MEDIA_TRASH`. Null only for
  /// [DuplicateFileAction.refusedOutsideStaging], which never computes one.
  final String? destinationPath;

  @override
  String toString() =>
      'DuplicateFileOutcome($action, $path -> $destinationPath)';
}

/// One duplicate group's full outcome: the path kept, plus every other
/// member's [DuplicateFileOutcome].
class DuplicateGroupOutcome {
  const DuplicateGroupOutcome({
    required this.keepPath,
    required this.trashOutcomes,
  });

  final String keepPath;
  final List<DuplicateFileOutcome> trashOutcomes;
}

/// The outcome of processing one Czkawka report file (one of
/// `duplicate_images.txt` / `duplicate_videos.txt` / `duplicate_files.txt`).
class DuplicateReportOutcome {
  const DuplicateReportOutcome({
    required this.reportPath,
    required this.found,
    required this.groups,
  });

  final String reportPath;

  /// Whether the report file existed. Mirrors `[[ -f "$report" ]] || return
  /// 0` — a missing report is not an error, just nothing to process.
  final bool found;
  final List<DuplicateGroupOutcome> groups;
}

/// Computes the destination path under `$MEDIA_TRASH` for [originalPath],
/// mirroring `trash_file`'s `rel="${src#/}"; dst="$MEDIA_TRASH/$rel"` — the
/// same full-original-absolute-path-minus-leading-slash convention
/// `11_restore_from_trash.sh`'s path reconstruction (and scripts 12/13)
/// depend on.
String trashDestinationPath({
  required String trashRoot,
  required String originalPath,
}) {
  final normalizedRoot = trashRoot.endsWith('/') && trashRoot.length > 1
      ? trashRoot.substring(0, trashRoot.length - 1)
      : trashRoot;
  final rel = originalPath.startsWith('/')
      ? originalPath.substring(1)
      : originalPath;
  return '$normalizedRoot/$rel';
}

/// Dart port of `06_delete_duplicates.sh`'s `process_czkawka_report` +
/// `trash_file` orchestration: reads each Czkawka report, decides keep/trash
/// per group via [decideCzkawkaReportGroups], and — in confirm mode — moves
/// every non-kept file to `$MEDIA_TRASH` via the shared [SafeFileMover].
///
/// Dry-run is the default (`confirm: false`), matching the Bash script and
/// every other confirm-gated script in this pipeline. Nothing is ever
/// deleted: every action is either a no-op (dry-run or missing file) or a
/// move from the original path to [trashDestinationPath] (possibly suffixed
/// — see [DuplicateFileAction.trashedWithSuffix]).
class DuplicateDeleter {
  const DuplicateDeleter({
    required this.stagingRoot,
    required this.trashRoot,
    this.copier = defaultFileCopier,
  });

  /// Mirrors `$CLEANING_STAGING`.
  final String stagingRoot;

  /// Mirrors `$MEDIA_TRASH`.
  final String trashRoot;

  /// Only ever overridden by tests (see [FileCopier]'s doc comment on
  /// `filesystem_ops.dart`); real callers always get the default
  /// `File.copy` implementation.
  final FileCopier copier;

  /// Processes every report in [reportPaths] in order (mirroring the Bash
  /// script's fixed call sequence of `duplicate_images.txt`,
  /// `duplicate_videos.txt`, `duplicate_files.txt`), returning one
  /// [DuplicateReportOutcome] per report path, in the same order.
  ///
  /// [confirm] defaults to `false` (dry-run): every trash candidate is
  /// reported as [DuplicateFileAction.wouldTrash] and nothing on disk is
  /// touched. When `true`, each trash candidate is moved via
  /// [SafeFileMover.moveRenamingOnCollision].
  Future<List<DuplicateReportOutcome>> run({
    required List<String> reportPaths,
    bool confirm = false,
  }) async {
    final mover = SafeFileMover(copier: copier);
    final results = <DuplicateReportOutcome>[];

    for (final reportPath in reportPaths) {
      final reportFile = File(reportPath);
      if (!await reportFile.exists()) {
        results.add(
          DuplicateReportOutcome(
            reportPath: reportPath,
            found: false,
            groups: const [],
          ),
        );
        continue;
      }

      final content = await reportFile.readAsString();
      final decisions = decideCzkawkaReportGroups(
        content,
        stagingRoot: stagingRoot,
      );

      final groupOutcomes = <DuplicateGroupOutcome>[];
      for (final decision in decisions) {
        final trashOutcomes = <DuplicateFileOutcome>[];
        for (final candidate in decision.trashPaths) {
          trashOutcomes.add(
            await _processTrashCandidate(candidate, mover, confirm),
          );
        }
        groupOutcomes.add(
          DuplicateGroupOutcome(
            keepPath: decision.keepPath,
            trashOutcomes: trashOutcomes,
          ),
        );
      }

      results.add(
        DuplicateReportOutcome(
          reportPath: reportPath,
          found: true,
          groups: groupOutcomes,
        ),
      );
    }

    return results;
  }

  Future<DuplicateFileOutcome> _processTrashCandidate(
    String src,
    SafeFileMover mover,
    bool confirm,
  ) async {
    final normalizedRoot = stagingRoot.endsWith('/') && stagingRoot.length > 1
        ? stagingRoot.substring(0, stagingRoot.length - 1)
        : stagingRoot;
    if (!src.startsWith('$normalizedRoot/')) {
      return DuplicateFileOutcome(
        path: src,
        action: DuplicateFileAction.refusedOutsideStaging,
      );
    }

    if (!await File(src).exists()) {
      return DuplicateFileOutcome(
        path: src,
        action: DuplicateFileAction.missing,
      );
    }

    final dst = trashDestinationPath(trashRoot: trashRoot, originalPath: src);

    if (!confirm) {
      return DuplicateFileOutcome(
        path: src,
        action: DuplicateFileAction.wouldTrash,
        destinationPath: dst,
      );
    }

    final outcome = await mover.moveRenamingOnCollision(src, dst);
    return DuplicateFileOutcome(
      path: src,
      action: outcome.result == MoveResult.moved
          ? DuplicateFileAction.trashed
          : DuplicateFileAction.trashedWithSuffix,
      destinationPath: outcome.destinationPath,
    );
  }
}

/// Renders [groups] using the exact `Keep: <path>` / `Would trash: <path>`
/// line format `06_delete_duplicates.sh` prints in dry-run mode (and that
/// `duplicate_report.dart`'s `parseDuplicateDryRunOutput` reads back).
///
/// Not used by any app wiring in this PR — see this file's top-level doc
/// comment for the integration decision. Exists so
/// `test/delete_duplicates_test.dart` can prove this port's decisions
/// render into a format `duplicate_report.dart` parses identically to the
/// real Bash script's own output, as a ready compatibility bridge for
/// whichever way Phase 2 wiring goes.
String renderDryRunKeepTrashLines(List<DuplicateGroupOutcome> groups) {
  final buffer = StringBuffer();
  for (final group in groups) {
    buffer.writeln('Keep: ${group.keepPath}');
    for (final outcome in group.trashOutcomes) {
      if (outcome.action == DuplicateFileAction.wouldTrash) {
        buffer.writeln('Would trash: ${outcome.path}');
      }
    }
    buffer.writeln();
  }
  return buffer.toString();
}

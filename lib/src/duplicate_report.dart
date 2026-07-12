/// Read-only parsing of the plain-text dry-run output that
/// `scripts/06_delete_duplicates.sh` prints to stdout, for the
/// thumbnail-diff review UI (issue #49).
///
/// SAFETY NOTE: this is a *display-only* parser. It never re-derives which
/// file would be kept vs. trashed — it only reads back the "Keep: " /
/// "Would trash: " announcement lines that `06_delete_duplicates.sh`'s own
/// `process_czkawka_report` / `score_keep_path` logic already produced. That
/// bash logic remains the sole safety-critical decision-maker for what
/// actually gets moved; this file must never be used to decide what to
/// move, only to render what the script already decided, so a human can
/// review it before pressing the confirm button.
///
/// Per `.company/forbidden-actions.md`, only real, absolute paths are ever
/// treated as file paths here. Report headers/notices/diagnostics
/// ("SAFETY NOTICE", "DRY RUN MODE...", "==> Processing duplicate report:
/// ...", "Missing, skipping: ...", "Refusing outside staging: ...",
/// "Done.", etc.) never match the line patterns below and are always
/// skipped, never mistaken for a path.
library;

import 'dart:math';

/// One proposed keep/trash pair extracted from a dry-run report.
class DuplicateReviewPair {
  const DuplicateReviewPair({
    required this.keepPath,
    required this.trashPath,
  });

  /// Absolute path to the file `06_delete_duplicates.sh` decided to keep
  /// for this duplicate group.
  final String keepPath;

  /// Absolute path to a file that would be moved to `media_trash` if the
  /// same dry run were re-run with `--confirm`.
  final String trashPath;

  @override
  bool operator ==(Object other) =>
      other is DuplicateReviewPair &&
      other.keepPath == keepPath &&
      other.trashPath == trashPath;

  @override
  int get hashCode => Object.hash(keepPath, trashPath);

  @override
  String toString() => 'DuplicateReviewPair($keepPath -> $trashPath)';
}

/// Result of parsing a dry-run report/output for review.
class DuplicateReviewParseResult {
  const DuplicateReviewParseResult({
    required this.pairs,
    required this.orphanTrashLineCount,
  });

  /// Every keep/trash pair found, in the order they appeared in the report.
  final List<DuplicateReviewPair> pairs;

  /// Count of "Would trash:" lines that appeared with no associated "Keep:"
  /// line for their group (malformed/unexpected input). These are never
  /// surfaced as pairs, only counted, so a malformed report can never
  /// silently produce a phantom review pair.
  final int orphanTrashLineCount;
}

final RegExp _keepLinePattern = RegExp(r'^Keep: (/.+)$');
final RegExp _trashLinePattern = RegExp(r'^Would trash: (/.+)$');

/// Parses the dry-run stdout produced by `06_delete_duplicates.sh` (run
/// without `--confirm`) into keep/trash pairs for display.
///
/// Only lines that are exactly `Keep: <absolute path>` or
/// `Would trash: <absolute path>` are ever interpreted as paths. Every
/// other line — report headers, the SAFETY NOTICE banner, "==> Processing
/// duplicate report: ..." progress lines, "Missing, skipping: ...",
/// "Refusing outside staging: ...", blank lines, "Done." — is ignored and
/// never treated as a path.
DuplicateReviewParseResult parseDuplicateDryRunOutput(String dryRunOutput) {
  final pairs = <DuplicateReviewPair>[];
  var orphanTrashLineCount = 0;
  String? currentKeep;

  for (final rawLine in dryRunOutput.split('\n')) {
    final line = rawLine.trimRight();

    final keepMatch = _keepLinePattern.firstMatch(line);
    if (keepMatch != null) {
      currentKeep = keepMatch.group(1);
      continue;
    }

    final trashMatch = _trashLinePattern.firstMatch(line);
    if (trashMatch != null) {
      final keep = currentKeep;
      if (keep == null) {
        orphanTrashLineCount += 1;
      } else {
        pairs.add(
          DuplicateReviewPair(
            keepPath: keep,
            trashPath: trashMatch.group(1)!,
          ),
        );
      }
      continue;
    }

    // A blank line (the script prints one after every group) or a new
    // "==> Processing duplicate report:" banner ends the current group in
    // the script's own output. Drop the pending keep so a later, unrelated
    // "Would trash:" line can never be paired with a stale keep left over
    // from an earlier group.
    if (line.isEmpty || line.startsWith('==> Processing duplicate report:')) {
      currentKeep = null;
    }
  }

  return DuplicateReviewParseResult(
    pairs: pairs,
    orphanTrashLineCount: orphanTrashLineCount,
  );
}

/// A possibly-sampled subset of [DuplicateReviewPair]s to render in the
/// review UI, plus enough bookkeeping to show an honest "N of M" count —
/// nothing is ever silently truncated.
class DuplicateReviewSample {
  const DuplicateReviewSample({
    required this.shown,
    required this.totalPairs,
  });

  final List<DuplicateReviewPair> shown;
  final int totalPairs;

  bool get isSampled => shown.length < totalPairs;
}

/// Samples at most [maxPairs] pairs from [pairs] for display.
///
/// Uses a fixed [seed] so the same input list always produces the same
/// sample (reproducible across app restarts / repeated reviews of the same
/// dry-run output), then sorts the sampled indices back into original
/// report order for a stable, readable display.
DuplicateReviewSample sampleDuplicateReviewPairs(
  List<DuplicateReviewPair> pairs, {
  int maxPairs = 20,
  int seed = 42,
}) {
  if (pairs.length <= maxPairs) {
    return DuplicateReviewSample(shown: pairs, totalPairs: pairs.length);
  }

  final indices = List<int>.generate(pairs.length, (i) => i)
    ..shuffle(Random(seed));
  final sampledIndices = indices.take(maxPairs).toList()..sort();

  return DuplicateReviewSample(
    shown: [for (final i in sampledIndices) pairs[i]],
    totalPairs: pairs.length,
  );
}

const List<String> _displayableImageExtensions = [
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
];

/// Whether [path] looks like a still-image format `Image.file` can render
/// directly. Anything else (video, RAW, unrecognized) should show a file
/// icon + filename instead, per the issue's design constraints — no video
/// thumbnail generation dependency is added for this feature.
bool isDisplayableImagePath(String path) {
  final lower = path.toLowerCase();
  return _displayableImageExtensions.any(lower.endsWith);
}

/// The filename portion of an absolute path, for label display.
String duplicateReviewFileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/');
  for (var i = segments.length - 1; i >= 0; i--) {
    if (segments[i].isNotEmpty) {
      return segments[i];
    }
  }
  return path;
}

import 'dart:convert';
import 'dart:io';

import 'filesystem_ops.dart';
import 'tools_container.dart';

/// Dart port of `scripts/13_dedupe_live_photos.sh` (Phase 0b of issue
/// #76/#77's shared roadmap; fourth and FINAL confirm-gated destructive
/// script in that phase, after `11_restore_from_trash.sh` (PR #82),
/// `06_delete_duplicates.sh` (PR #86), and
/// `12_clean_immich_takeout_duplicates.sh` (PR #87)).
///
/// This script finds Apple Live Photo still+video pairs that Google Takeout
/// split apart (same directory, same basename, different extensions) and
/// moves each *verified* redundant video to `$MEDIA_TRASH`, keeping the
/// still as a plain photo. "Verified" mirrors the Bash script's
/// `evaluate_pair` exactly, in strict priority order:
///
/// 1. `ffprobe` reports a numeric duration for the video. This is the
///    PRIMARY signal. If that duration is `<= 5s`, the pair is verified. If
///    it is `> 5s` (a real standalone video that happens to share a
///    basename), the pair is rejected — and this rejection is final: a
///    known-too-long duration must NEVER fall through to the timestamp
///    fallback below. This was an explicit design decision reviewed on the
///    original Bash script (issue #60 / PR #61) and is preserved exactly;
///    see [evaluateLivePhotoPair]'s doc comment and its "duration known too
///    long wins even when timestamps are close" test in
///    `test/dedupe_live_photos_test.dart` for the regression guard.
/// 2. Only when `ffprobe` cannot report a numeric duration at all (corrupt
///    file, missing metadata) does file-mtime proximity (`<= 5s` apart)
///    serve as a secondary signal.
/// 3. Otherwise the pair is left alone as an ambiguous match.
///
/// Mirrors the Bash script's functional pieces:
/// - The still/video extension classification + same-directory/same-basename
///   pairing walk -> [pairStillsAndVideos], a pure function operating on an
///   already-sorted list of file paths within one directory, with zero
///   filesystem dependency.
/// - `video_duration_seconds`'s numeric-duration check ->
///   [evaluateVideoDuration], a pure function over the raw `ffprobe` stdout
///   string (or `null`, standing in for `2>/dev/null || true`'s "produced
///   nothing" case).
/// - `evaluate_pair`'s duration-then-timestamp-fallback priority order ->
///   [evaluateLivePhotoPair], a pure function combining the two signals
///   with zero filesystem/subprocess dependency, directly unit-testable
///   against synthetic duration/mtime fixtures.
/// - The directory walk + dry-run/confirm `move_or_report_video` loop ->
///   [LivePhotoDedupeCleaner.run], the thin async layer that shells out to
///   `ffprobe` (via the injectable, overridable [VideoDurationReader] —
///   mirroring the Bash script's own `$FFPROBE_BIN` override for testing —
///   and reads file mtimes), and delegates the actual move to the shared
///   [SafeFileMover] primitive in `filesystem_ops.dart` (the same primitive
///   `restore_from_trash.dart`/`delete_duplicates.dart`/
///   `clean_takeout_duplicates.dart` use).
///
/// ## Design decision: not wired into `pipeline_models.dart` /
/// `media_pipeline_app.dart`
///
/// Same "port the logic, defer the wiring" pattern as the three prior ports
/// in this series: the actual executed pipeline step still shells out to
/// the real `scripts/13_dedupe_live_photos.sh`. Wiring the
/// container/Dart-native execution path is Phase 2 of issue #76, not this
/// slice.
///
/// ## Design decision: the typed confirmation phrase
///
/// Like `12_clean_immich_takeout_duplicates.sh`, this script requires the
/// operator to type an exact phrase (`"MOVE LIVE PHOTO VIDEOS"`) at an
/// interactive prompt before anything moves, in addition to the `--confirm`
/// flag. Since this port isn't wired into the app yet, the actual
/// interactive prompt still lives entirely in the real Bash script (nothing
/// in this file ever reads stdin or constructs a confirm command).
/// [kLivePhotoDedupeConfirmPhrase] and
/// [isLivePhotoDedupeConfirmationPhraseValid] exist so that phrase is
/// already ported, named, and unit-tested ahead of Phase 2 wiring —
/// [LivePhotoDedupeCleaner.run] itself still takes a plain `confirm` bool
/// (mirroring `TrashRestorer.run`/`DuplicateDeleter.run`/
/// `TakeoutDuplicateCleaner.run`'s precedent exactly), on the assumption
/// that whatever calls it has already gated on a typed phrase matching
/// [kLivePhotoDedupeConfirmPhrase] the same way the real Bash script's CLI
/// entry point does today.
///
/// ## Design decision: trash-move collision handling
///
/// The Bash script's own `unique_destination` resolves a destination
/// collision by appending a numbered suffix (`_1`, `_2`, ...) and always
/// moving. This port now matches that exactly via
/// [SafeFileMover.moveRenamingOnCollision] (Leo's #76/#77 review decision,
/// superseding an earlier revision of this port that used
/// [SafeFileMover.moveNoClobber] and skipped on collision — see
/// `filesystem_ops.dart`'s top-level doc comment for the full rationale).
/// The move never leaves a verified redundant video un-moved on collision;
/// [LivePhotoPairOutcome.destinationPath] reflects the actual path used,
/// which may carry a numbered suffix. This does not affect the verify/skip
/// *decision* logic that the Bash-vs-Dart parity test in
/// `test/dedupe_live_photos_test.dart` verifies.
///
/// ## Design decision: `ffprobe` execution routes through [ToolsContainer]
/// (Phase 2 of issue #76)
///
/// This is the first real consumer migration of #76 Phase 2 (container
/// wiring), following the container-orchestration plumbing PR (#93,
/// `tools_container.dart`). [containerFfprobeDurationReader] is now the
/// sanctioned production [VideoDurationReader] — it execs the real,
/// pinned `ffprobe` from the `media-pipeline-tools` image via a caller-owned,
/// already-[ToolsContainer.start]ed [ToolsContainer], translating the host
/// video path to its container-mounted equivalent via
/// [ToolsContainer.hostToContainerPath] before every exec.
///
/// **Hard cutover, not a fallback pair.** [LivePhotoDedupeCleaner]'s
/// [LivePhotoDedupeCleaner.durationReader] is a *required* constructor
/// parameter — there is no longer an implicit default that silently shells
/// out to a host-installed `ffprobe`. This repo's target users already run
/// Docker (it's a hard requirement for Immich itself), so there is no real
/// deployment scenario where the container path is unavailable but a
/// Dart-native pipeline run still needs to work; keeping a "just in case"
/// host fallback would only invite a caller to accidentally bypass the
/// container path (and its path-translation safety net) by omission. The
/// host-shelling [ffprobeDurationReader] function is kept — it is still the
/// most direct way to exercise this module's decision logic in a unit test
/// without standing up a container, and existing callers (all of them
/// tests, per `test/dedupe_live_photos_test.dart`) already pass their own
/// `durationReader` explicitly — but it is deliberately no longer wired in
/// as this class's default, so nothing reaches it by omission.
///
/// **Not yet wired into the app.** Same "port the mechanism, defer the
/// wiring" pattern as every other port in this series: no caller in
/// `pipeline_models.dart`/`media_pipeline_app.dart` constructs a
/// [ToolsContainer] or calls [LivePhotoDedupeCleaner] yet. That means this
/// PR does not change any live runtime behavior — it changes what the
/// *sanctioned* production seam is, ahead of the future PR that actually
/// wires `LivePhotoDedupeCleaner.run` into the app (at which point that
/// caller is expected to wrap the whole call in
/// [ToolsContainer.withSession] and pass
/// `containerFfprobeDurationReader(container: container)` in).
///
/// ## Explicit non-goal (matching the original script's own scope boundary)
///
/// This port never attempts to re-link the still+video pair as a single
/// Immich "Live Photo" asset via metadata (e.g.
/// `QuickTime:ContentIdentifier`). It only decides which video is redundant
/// and moves it; the still is always left exactly as-is, a plain photo.
/// That re-linking is explicit out-of-scope per #60.

// ---------------------------------------------------------------------------
// Typed confirmation phrase (see design decision above)
// ---------------------------------------------------------------------------

/// The exact phrase `scripts/13_dedupe_live_photos.sh` prompts for
/// (`CONFIRM_PHRASE="MOVE LIVE PHOTO VIDEOS"`) before moving anything in
/// `--confirm` mode.
const String kLivePhotoDedupeConfirmPhrase = 'MOVE LIVE PHOTO VIDEOS';

/// True only if [typed] is an exact match for
/// [kLivePhotoDedupeConfirmPhrase], mirroring the Bash script's
/// `[[ "$typed_confirmation" != "$CONFIRM_PHRASE" ]]` check (no trimming, no
/// case-insensitivity — an exact match is required).
bool isLivePhotoDedupeConfirmationPhraseValid(String typed) =>
    typed == kLivePhotoDedupeConfirmPhrase;

// ---------------------------------------------------------------------------
// Thresholds (mirroring the Bash script's MAX_DURATION_SECONDS /
// TIMESTAMP_PROXIMITY_SECONDS constants exactly, including their rationale).
// ---------------------------------------------------------------------------

/// Mirrors `MAX_DURATION_SECONDS=5`: reject any paired video longer than
/// this many seconds. Apple Live Photos capture roughly 1.5s before and
/// after the still (about 3s total); this gives a comfortable margin above
/// that range while still rejecting a real standalone video that happens to
/// share a basename.
const double kMaxLivePhotoDurationSeconds = 5;

/// Mirrors `TIMESTAMP_PROXIMITY_SECONDS=5`: the secondary signal's
/// threshold, only ever consulted when `ffprobe` cannot report a numeric
/// duration at all.
const int kLivePhotoTimestampProximitySeconds = 5;

// ---------------------------------------------------------------------------
// Pure logic: still/video pairing within one directory
// ---------------------------------------------------------------------------

const Set<String> _kStillExtensions = {'heic', 'heif', 'jpg', 'jpeg'};
const Set<String> _kVideoExtensions = {'mov', 'mp4'};

/// The result of pairing stills and videos within a single directory's file
/// list, mirroring `process_directory`'s `stills`/`videos`/`video_order`
/// associative-array bookkeeping.
class DirectoryPairing {
  const DirectoryPairing({
    required this.videoOrder,
    required this.stillPathByBase,
    required this.videoPathByBase,
  });

  /// Basenames (extension-stripped), in the order their first video
  /// occurrence was seen in [sortedFilePaths] — mirrors Bash's
  /// `video_order` array, which only appends a key the first time a video
  /// with that base is seen (even though the map entry itself is later
  /// overwritten by a subsequent video sharing the same base).
  final List<String> videoOrder;

  /// Basename -> still file path (last one wins if more than one still
  /// shares a basename+directory, matching Bash's associative-array
  /// overwrite semantics).
  final Map<String, String> stillPathByBase;

  /// Basename -> video file path (last one wins, matching Bash's
  /// associative-array overwrite semantics).
  final Map<String, String> videoPathByBase;
}

/// Pairs stills (`.heic`/`.heif`/`.jpg`/`.jpeg`) and videos (`.mov`/`.mp4`)
/// within a single directory by basename (extension stripped, case-folded
/// only for the extension, exactly like Bash's
/// `ext_lower="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"`).
///
/// [sortedFilePaths] must contain only the direct file children of one
/// directory (no recursion), already sorted — mirroring the Bash script's
/// `find "$dir" -maxdepth 1 -type f -print0 | sort -z`. Never matches across
/// directories: this function only ever sees one directory's files at a
/// time, exactly like [LivePhotoDedupeCleaner.run]'s per-directory walk.
///
/// A filename with no `.` at all is skipped entirely, mirroring Bash's
/// `[[ "$name" == "$ext" ]] && continue` (there, `${name##*.}` on a
/// dot-less name returns the whole name unchanged, so the equality check is
/// true and the file is skipped).
DirectoryPairing pairStillsAndVideos(List<String> sortedFilePaths) {
  final stills = <String, String>{};
  final videos = <String, String>{};
  final videoOrder = <String>[];

  for (final path in sortedFilePaths) {
    final name = path.split('/').last;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1) continue;
    final base = name.substring(0, dotIndex);
    final ext = name.substring(dotIndex + 1);
    final extLower = ext.toLowerCase();

    if (_kStillExtensions.contains(extLower)) {
      stills[base] = path;
    } else if (_kVideoExtensions.contains(extLower)) {
      if (!videos.containsKey(base)) {
        videoOrder.add(base);
      }
      videos[base] = path;
    }
  }

  return DirectoryPairing(
    videoOrder: videoOrder,
    stillPathByBase: stills,
    videoPathByBase: videos,
  );
}

// ---------------------------------------------------------------------------
// Pure logic: duration verification (video_duration_seconds's numeric check)
// ---------------------------------------------------------------------------

/// Mirrors Bash's `[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]` — deliberately
/// not a general float parser: no sign, no exponent notation, no leading
/// `.`, matching the Bash regex exactly so this port never accepts a value
/// real `ffprobe`/the Bash script would have rejected as non-numeric.
final RegExp _kNumericDurationPattern = RegExp(r'^[0-9]+(\.[0-9]+)?$');

/// The outcome of checking a video's raw `ffprobe`-reported duration
/// against [kMaxLivePhotoDurationSeconds].
enum DurationVerification {
  /// A numeric duration was reported and is `<= maxDurationSeconds`.
  verified,

  /// A numeric duration was reported but exceeds `maxDurationSeconds`. This
  /// is a terminal, final rejection — see [evaluateLivePhotoPair]'s doc
  /// comment for why this must never fall through to the timestamp
  /// fallback.
  tooLong,

  /// `ffprobe` produced no usable numeric duration at all (process failure,
  /// empty output, or non-numeric output) — the only case where the
  /// timestamp-proximity fallback may be consulted.
  unknown,
}

/// Port of `video_duration_seconds` + the numeric-regex/`awk` comparison in
/// `evaluate_pair`. [rawDuration] is the raw `ffprobe` stdout (already
/// trimmed or not — this function trims it itself), or `null` standing in
/// for the Bash script's `2>/dev/null || true` "produced nothing" case
/// (e.g. `ffprobe` exited non-zero).
DurationVerification evaluateVideoDuration({
  required String? rawDuration,
  double maxDurationSeconds = kMaxLivePhotoDurationSeconds,
}) {
  final trimmed = rawDuration?.trim() ?? '';
  if (!_kNumericDurationPattern.hasMatch(trimmed)) {
    return DurationVerification.unknown;
  }
  final value = double.parse(trimmed);
  return value <= maxDurationSeconds
      ? DurationVerification.verified
      : DurationVerification.tooLong;
}

// ---------------------------------------------------------------------------
// Pure logic: the full evaluate_pair priority order (duration first,
// timestamp-proximity fallback only when duration is unknown)
// ---------------------------------------------------------------------------

/// The final verification outcome for one still+video pair, mirroring
/// `evaluate_pair`'s three possible dispositions (a verified pair is
/// verified either by duration or by the timestamp fallback; either way it
/// gets moved/reported the same way, just with a different `reason` string
/// — see [LivePhotoDedupeCleaner]).
enum PairVerification {
  /// `ffprobe` reported a numeric duration `<= kMaxLivePhotoDurationSeconds`.
  verifiedByDuration,

  /// `ffprobe` reported a numeric duration `> kMaxLivePhotoDurationSeconds`.
  /// Final: never reconsidered via the timestamp fallback.
  tooLong,

  /// `ffprobe` reported no numeric duration at all, but the still and video
  /// mtimes are within [kLivePhotoTimestampProximitySeconds] of each other.
  verifiedByTimestampProximity,

  /// `ffprobe` reported no numeric duration at all, and either an mtime
  /// could not be read or the two mtimes are too far apart. Mirrors
  /// `Duration unknown and timestamps not close enough, skipping`.
  ambiguousDurationUnknownAndTimestampsFar,
}

/// Port of `evaluate_pair`'s full decision logic, as a pure function over
/// already-fetched signals (no filesystem/subprocess access here — see
/// [LivePhotoDedupeCleaner._evaluate] for where [rawDuration] and the mtimes
/// actually get fetched).
///
/// Priority order, matching the Bash script exactly and preserved as a
/// hard invariant of this port: a numeric, known-too-long duration
/// ([DurationVerification.tooLong]) returns [PairVerification.tooLong]
/// immediately, without ever looking at [stillEpochSeconds] /
/// [videoEpochSeconds] — even if the two files' timestamps happen to be
/// close together. The timestamp-proximity fallback is reachable *only*
/// through the [DurationVerification.unknown] branch. This ordering is the
/// explicit design decision named in this port's task brief (verified in
/// the original Bash script's own PR review, #60/#61) and must never be
/// weakened.
PairVerification evaluateLivePhotoPair({
  required String? rawDuration,
  required int? stillEpochSeconds,
  required int? videoEpochSeconds,
  double maxDurationSeconds = kMaxLivePhotoDurationSeconds,
  int timestampProximitySeconds = kLivePhotoTimestampProximitySeconds,
}) {
  final durationVerification = evaluateVideoDuration(
    rawDuration: rawDuration,
    maxDurationSeconds: maxDurationSeconds,
  );

  switch (durationVerification) {
    case DurationVerification.verified:
      return PairVerification.verifiedByDuration;
    case DurationVerification.tooLong:
      // Terminal rejection — must never fall through to the timestamp
      // fallback below, regardless of how close stillEpochSeconds and
      // videoEpochSeconds are.
      return PairVerification.tooLong;
    case DurationVerification.unknown:
      if (stillEpochSeconds != null &&
          videoEpochSeconds != null &&
          (stillEpochSeconds - videoEpochSeconds).abs() <=
              timestampProximitySeconds) {
        return PairVerification.verifiedByTimestampProximity;
      }
      return PairVerification.ambiguousDurationUnknownAndTimestampsFar;
  }
}

// ---------------------------------------------------------------------------
// Pure logic: trash destination path convention
// ---------------------------------------------------------------------------

/// Computes the destination path under `$MEDIA_TRASH` for [originalPath],
/// mirroring `move_or_report_video`'s `rel="${video#/}"; dst="$MEDIA_TRASH/$rel"`
/// — the same full-original-absolute-path-minus-leading-slash convention
/// `06`/`11`/`12` already use, so `11_restore_from_trash.sh` can always
/// reconstruct the original location.
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

// ---------------------------------------------------------------------------
// Async orchestration: walks TARGET_DIR, evaluates each still+video pair,
// and (in confirm mode) moves verified redundant videos to $MEDIA_TRASH.
// ---------------------------------------------------------------------------

/// Reads a video's duration via `ffprobe` (or an injected stand-in),
/// returning the raw stdout string, or `null` if the process failed or
/// produced no output — mirroring `video_duration_seconds`'s
/// `2>/dev/null || true`. [LivePhotoDedupeCleaner] takes this as a
/// *required* constructor parameter (no implicit default — see this file's
/// top-level "Design decision: `ffprobe` execution routes through
/// [ToolsContainer]" doc comment); the sanctioned production implementation
/// is [containerFfprobeDurationReader]. [ffprobeDurationReader] (host
/// `Process.run`) remains available as a lower-ceremony way to exercise this
/// module's decision logic in a test without standing up a container,
/// mirroring the Bash test suite's own `FFPROBE_BIN` override.
typedef VideoDurationReader = Future<String?> Function(String videoPath);

/// Builds a host-`Process.run`-based [VideoDurationReader]: shells out to
/// [ffprobeBin] (defaulting to `ffprobe`, matching Bash's
/// `FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"` override), passing the same
/// arguments the Bash script's `video_duration_seconds` uses. Not the
/// production seam any more (see [containerFfprobeDurationReader]) — kept
/// as a direct, container-free way for a test to exercise this module's
/// decision logic against a stand-in `ffprobe` binary.
VideoDurationReader ffprobeDurationReader({String ffprobeBin = 'ffprobe'}) {
  return (String videoPath) async {
    final result = await Process.run(
      ffprobeBin,
      [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        videoPath,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  };
}

/// Builds the sanctioned production [VideoDurationReader]: execs the real
/// `ffprobe` binary bundled in the `media-pipeline-tools` image (Phase 1,
/// `docker/tools/Dockerfile`) inside an already-[ToolsContainer.start]ed
/// [container], via [ToolsContainer.exec].
///
/// [videoPath] (as always with [VideoDurationReader]) is a *host* absolute
/// path — this function translates it to the container-mounted equivalent
/// via [ToolsContainer.hostToContainerPath] before passing it to `ffprobe`,
/// since the container only ever sees its own bind-mounted view of the
/// filesystem. [ToolsContainer.hostToContainerPath] itself fails loudly
/// ([ArgumentError]) if [videoPath] falls outside [container]'s
/// `hostMountRoot` — this function does not add its own separate check, it
/// relies on that existing fail-loud contract.
///
/// [container] must already be started ([ToolsContainer.start] /
/// [ToolsContainer.withSession]) — this function only execs into it, it does
/// not manage the container's lifecycle. That is a deliberate choice: a
/// caller processing many candidate videos (as [LivePhotoDedupeCleaner.run]
/// does) should start one long-lived container for the whole run, not one
/// per file — see `tools_container.dart`'s own top-level doc comment on why
/// `docker exec` into a kept-alive container, rather than a fresh `docker
/// run` per call, is the point of [ToolsContainer] at all.
///
/// Same success/failure mapping as [ffprobeDurationReader]: a non-zero exit
/// or empty stdout both map to `null`, mirroring `video_duration_seconds`'s
/// `2>/dev/null || true` "produced nothing" case.
VideoDurationReader containerFfprobeDurationReader({
  required ToolsContainer container,
  String ffprobeBin = 'ffprobe',
}) {
  return (String videoPath) async {
    final containerPath = container.hostToContainerPath(videoPath);
    final result = await container.exec([
      ffprobeBin,
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      containerPath,
    ]);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  };
}

/// Reads a file's mtime as whole epoch seconds, mirroring Bash's
/// `stat -c %Y "$1" 2>/dev/null || echo ""` (returns `null` on any failure,
/// standing in for the empty-string case). The default
/// ([defaultFileMtimeReader]) reads the real filesystem mtime; tests can
/// inject a fake.
typedef FileMtimeReader = Future<int?> Function(String path);

/// Default [FileMtimeReader]: `File(path).stat()`, truncated to whole
/// seconds (matching `stat -c %Y`'s integer-seconds precision).
Future<int?> defaultFileMtimeReader(String path) async {
  try {
    final stat = await File(path).stat();
    return stat.modified.millisecondsSinceEpoch ~/ 1000;
  } on FileSystemException {
    return null;
  }
}

/// What happened (or would happen) to one candidate video.
enum LivePhotoPairAction {
  /// Dry-run mode (the default): printed what *would* happen; nothing
  /// touched on disk. Mirrors `Would move standalone Live Photo video ...`.
  wouldMove,

  /// Confirm mode: the video was actually moved to `$MEDIA_TRASH`.
  moved,

  /// Confirm mode: the desired destination already existed, so — matching
  /// [SafeFileMover.moveRenamingOnCollision]'s numbered-suffix semantics
  /// (see this file's "trash-move collision handling" design decision
  /// above) — the file was moved to a suffixed alternative instead. See
  /// [LivePhotoPairOutcome.destinationPath] for the actual path used.
  movedWithSuffix,

  /// No paired still exists for this video at all. Mirrors
  /// `No paired still for video, skipping: ...`.
  missingStill,

  /// A numeric duration was reported but exceeds
  /// [kMaxLivePhotoDurationSeconds]. Mirrors
  /// `Video too long (...), skipping: ...`.
  tooLong,

  /// Duration unknown, and timestamps were either unreadable or too far
  /// apart. Mirrors
  /// `Duration unknown and timestamps not close enough, skipping: ...`.
  ambiguous,
}

/// The outcome of processing one candidate video (and its paired still, if
/// any).
class LivePhotoPairOutcome {
  const LivePhotoPairOutcome({
    required this.videoPath,
    required this.stillPath,
    required this.action,
    this.reason,
    this.destinationPath,
  });

  final String videoPath;

  /// `null` only for [LivePhotoPairAction.missingStill].
  final String? stillPath;

  final LivePhotoPairAction action;

  /// Human-readable reason, mirroring the Bash script's own `$reason`
  /// argument to `move_or_report_video` (e.g. `"duration 2.000000s"` or
  /// `"duration unknown, timestamps 0s apart"`). `null` for
  /// [LivePhotoPairAction.missingStill]/[LivePhotoPairAction.tooLong]/
  /// [LivePhotoPairAction.ambiguous], which have their own dedicated log
  /// lines in the Bash script rather than a `reason`-carrying one.
  final String? reason;

  /// The (would-be) destination under `$MEDIA_TRASH`. Non-null only for
  /// [LivePhotoPairAction.wouldMove]/[LivePhotoPairAction.moved]/
  /// [LivePhotoPairAction.movedWithSuffix].
  final String? destinationPath;

  @override
  String toString() =>
      'LivePhotoPairOutcome($action, $videoPath -> $destinationPath'
      '${reason != null ? ", reason: $reason" : ""})';
}

/// The full outcome of one [LivePhotoDedupeCleaner.run] call, including the
/// same summary counters the Bash script prints
/// (`inspected`/`verified`/`skipped_missing`/`skipped_too_long`/
/// `skipped_duration_unknown`/`skipped_ambiguous`).
class LivePhotoDedupeSummary {
  const LivePhotoDedupeSummary({
    required this.outcomes,
    required this.inspected,
    required this.verified,
    required this.skippedMissing,
    required this.skippedTooLong,
    required this.skippedDurationUnknown,
    required this.skippedAmbiguous,
  });

  final List<LivePhotoPairOutcome> outcomes;

  /// Mirrors `$inspected`.
  final int inspected;

  /// Total pairs that passed verification (by duration or, when duration
  /// was unknown, by timestamp proximity). Mirrors `$verified`.
  final int verified;

  /// Mirrors `$skipped_missing`.
  final int skippedMissing;

  /// Mirrors `$skipped_too_long`.
  final int skippedTooLong;

  /// Total candidates whose duration was unknown, regardless of whether
  /// the timestamp fallback then verified or rejected them. Mirrors
  /// `$skipped_duration_unknown`.
  final int skippedDurationUnknown;

  /// Total candidates left ambiguous (duration unknown AND timestamps not
  /// close enough, or unreadable). Mirrors `$skipped_ambiguous`.
  final int skippedAmbiguous;
}

/// Dart port of `13_dedupe_live_photos.sh`'s directory walk +
/// `evaluate_pair` + `move_or_report_video` orchestration: for every
/// directory under [targetDir] (including [targetDir] itself), pairs
/// stills and videos sharing a basename, verifies each pair (duration
/// first, timestamp-proximity fallback only when duration is unknown), and
/// — in confirm mode — moves every verified redundant video to
/// `$MEDIA_TRASH` via the shared [SafeFileMover]. The paired still is never
/// touched.
///
/// Dry-run is the default (`confirm: false`), matching the Bash script and
/// every other confirm-gated script in this pipeline. Nothing is ever
/// deleted: every action is either a no-op (dry-run, missing-still,
/// too-long, or ambiguous) or a move from the video's original path to
/// [trashDestinationPath] (possibly suffixed — see
/// [LivePhotoPairAction.movedWithSuffix]).
class LivePhotoDedupeCleaner {
  LivePhotoDedupeCleaner({
    required this.trashRoot,
    required this.durationReader,
    this.mtimeReader = defaultFileMtimeReader,
    this.copier = defaultFileCopier,
    this.maxDurationSeconds = kMaxLivePhotoDurationSeconds,
    this.timestampProximitySeconds = kLivePhotoTimestampProximitySeconds,
  });

  /// Mirrors `$MEDIA_TRASH`.
  final String trashRoot;

  /// A *required* constructor parameter — deliberately no implicit default
  /// (see this file's top-level "Design decision: `ffprobe` execution
  /// routes through [ToolsContainer]" doc comment for why). Real callers
  /// should pass [containerFfprobeDurationReader]; tests pass a fake, or
  /// [ffprobeDurationReader] for a container-free decision-logic check.
  final VideoDurationReader durationReader;

  /// Only ever overridden by tests; real callers get the default
  /// `File.stat()`-based implementation.
  final FileMtimeReader mtimeReader;

  /// Only ever overridden by tests (see [FileCopier]'s doc comment on
  /// `filesystem_ops.dart`); real callers always get the default
  /// `File.copy` implementation.
  final FileCopier copier;

  /// Mirrors `MAX_DURATION_SECONDS`.
  final double maxDurationSeconds;

  /// Mirrors `TIMESTAMP_PROXIMITY_SECONDS`.
  final int timestampProximitySeconds;

  /// Walks [targetDir] (mirroring `$TARGET_DIR` =
  /// `${LIVE_PHOTO_SCAN_DIR:-$IMMICH_LIBRARY}`), evaluating every
  /// still+video pair found in every directory under it (including
  /// [targetDir] itself), and — in confirm mode — moving every verified
  /// redundant video to `$MEDIA_TRASH`.
  ///
  /// If [targetDir] doesn't exist, returns an all-zero summary and touches
  /// nothing, mirroring the Bash script's
  /// `[[ ! -d "$TARGET_DIR" ]] && ... exit 0` early return.
  Future<LivePhotoDedupeSummary> run({
    required String targetDir,
    bool confirm = false,
  }) async {
    final rootDir = Directory(targetDir);
    if (!await rootDir.exists()) {
      return const LivePhotoDedupeSummary(
        outcomes: [],
        inspected: 0,
        verified: 0,
        skippedMissing: 0,
        skippedTooLong: 0,
        skippedDurationUnknown: 0,
        skippedAmbiguous: 0,
      );
    }

    final mover = SafeFileMover(copier: copier);

    // Mirrors `find "$TARGET_DIR" -type d -print0 | sort -z`: every
    // directory under targetDir, INCLUDING targetDir itself, sorted.
    final allDirs = <String>{targetDir};
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) allDirs.add(entity.path);
    }
    final sortedDirs = allDirs.toList()..sort();

    var inspected = 0;
    var verified = 0;
    var skippedMissing = 0;
    var skippedTooLong = 0;
    var skippedDurationUnknown = 0;
    var skippedAmbiguous = 0;
    final outcomes = <LivePhotoPairOutcome>[];

    for (final dirPath in sortedDirs) {
      // Mirrors `find "$dir" -maxdepth 1 -type f -print0 | sort -z`: only
      // this directory's direct file children, not its subdirectories'
      // (those are walked separately, as their own entries in sortedDirs).
      final filePaths = <String>[
        await for (final entity in Directory(
          dirPath,
        ).list(followLinks: false))
          if (entity is File) entity.path,
      ]..sort();

      final pairing = pairStillsAndVideos(filePaths);

      for (final base in pairing.videoOrder) {
        final videoPath = pairing.videoPathByBase[base]!;
        final stillPath = pairing.stillPathByBase[base];

        if (stillPath == null) {
          inspected++;
          skippedMissing++;
          outcomes.add(
            LivePhotoPairOutcome(
              videoPath: videoPath,
              stillPath: null,
              action: LivePhotoPairAction.missingStill,
            ),
          );
          continue;
        }

        inspected++;
        final (outcome, verification) = await _evaluate(
          stillPath: stillPath,
          videoPath: videoPath,
          mover: mover,
          confirm: confirm,
        );
        outcomes.add(outcome);

        // Mirrors evaluate_pair's counter bookkeeping exactly: the
        // duration-unknown branch increments $skipped_duration_unknown
        // unconditionally the moment the numeric-duration regex fails,
        // BEFORE the timestamp fallback is even attempted — so that
        // counter covers both the verifiedByTimestampProximity and
        // ambiguousDurationUnknownAndTimestampsFar cases, while
        // $skipped_too_long is only ever reached via a *known* numeric
        // duration and never touches $skipped_duration_unknown at all.
        switch (verification) {
          case PairVerification.tooLong:
            skippedTooLong++;
          case PairVerification.verifiedByTimestampProximity:
            skippedDurationUnknown++;
            verified++;
          case PairVerification.ambiguousDurationUnknownAndTimestampsFar:
            skippedDurationUnknown++;
            skippedAmbiguous++;
          case PairVerification.verifiedByDuration:
            verified++;
        }
      }
    }

    return LivePhotoDedupeSummary(
      outcomes: outcomes,
      inspected: inspected,
      verified: verified,
      skippedMissing: skippedMissing,
      skippedTooLong: skippedTooLong,
      skippedDurationUnknown: skippedDurationUnknown,
      skippedAmbiguous: skippedAmbiguous,
    );
  }

  Future<(LivePhotoPairOutcome, PairVerification)> _evaluate({
    required String stillPath,
    required String videoPath,
    required SafeFileMover mover,
    required bool confirm,
  }) async {
    final rawDuration = await durationReader(videoPath);
    final stillEpochSeconds = await mtimeReader(stillPath);
    final videoEpochSeconds = await mtimeReader(videoPath);

    final verification = evaluateLivePhotoPair(
      rawDuration: rawDuration,
      stillEpochSeconds: stillEpochSeconds,
      videoEpochSeconds: videoEpochSeconds,
      maxDurationSeconds: maxDurationSeconds,
      timestampProximitySeconds: timestampProximitySeconds,
    );

    switch (verification) {
      case PairVerification.tooLong:
        return (
          LivePhotoPairOutcome(
            videoPath: videoPath,
            stillPath: stillPath,
            action: LivePhotoPairAction.tooLong,
          ),
          verification,
        );
      case PairVerification.ambiguousDurationUnknownAndTimestampsFar:
        return (
          LivePhotoPairOutcome(
            videoPath: videoPath,
            stillPath: stillPath,
            action: LivePhotoPairAction.ambiguous,
          ),
          verification,
        );
      case PairVerification.verifiedByDuration:
        final reason = 'duration ${rawDuration!.trim()}s';
        return (
          await _moveOrReport(
            stillPath: stillPath,
            videoPath: videoPath,
            reason: reason,
            mover: mover,
            confirm: confirm,
          ),
          verification,
        );
      case PairVerification.verifiedByTimestampProximity:
        final diff = (stillEpochSeconds! - videoEpochSeconds!).abs();
        final reason = 'duration unknown, timestamps ${diff}s apart';
        return (
          await _moveOrReport(
            stillPath: stillPath,
            videoPath: videoPath,
            reason: reason,
            mover: mover,
            confirm: confirm,
          ),
          verification,
        );
    }
  }

  Future<LivePhotoPairOutcome> _moveOrReport({
    required String stillPath,
    required String videoPath,
    required String reason,
    required SafeFileMover mover,
    required bool confirm,
  }) async {
    final dst = trashDestinationPath(
      trashRoot: trashRoot,
      originalPath: videoPath,
    );

    if (!confirm) {
      return LivePhotoPairOutcome(
        videoPath: videoPath,
        stillPath: stillPath,
        action: LivePhotoPairAction.wouldMove,
        reason: reason,
        destinationPath: dst,
      );
    }

    final outcome = await mover.moveRenamingOnCollision(videoPath, dst);
    return LivePhotoPairOutcome(
      videoPath: videoPath,
      stillPath: stillPath,
      action: outcome.result == MoveResult.moved
          ? LivePhotoPairAction.moved
          : LivePhotoPairAction.movedWithSuffix,
      reason: reason,
      destinationPath: outcome.destinationPath,
    );
  }
}

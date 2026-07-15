import 'dart:convert';
import 'dart:io';

import 'filesystem_ops.dart';

/// Dart port of `scripts/12_clean_immich_takeout_duplicates.sh` (Phase 0b of
/// issue #76/#77's shared roadmap; third of the four confirm-gated
/// destructive scripts in that phase, after `11_restore_from_trash.sh` (PR
/// #82) and `06_delete_duplicates.sh` (PR #86)).
///
/// This script finds Google Takeout's localized year-folder duplicates
/// (`Fotos de YYYY/*` next to the canonical `YYYY/*`) inside the Immich
/// external library and moves each *verified* duplicate to `$MEDIA_TRASH`.
/// "Verified" is the safety-critical part: a candidate is only ever trusted
/// as a duplicate if THREE independent checks all agree —
/// basename match (implicit: this is how the canonical counterpart is
/// looked up), file size match, and SHA-256 hash match — mirroring the Bash
/// script's `inspect_candidate` exactly. Any one of these failing skips the
/// candidate; none of the three is ever weakened or skipped.
///
/// Mirrors the Bash script's functional pieces:
/// - The `Fotos de YYYY` directory-name match -> [matchLocalizedYearFolderName],
///   a pure function with zero filesystem dependency.
/// - `inspect_candidate`'s three-way basename+size+hash verification ->
///   [verifyTakeoutDuplicateCandidate], async only because size/hash require
///   reading real file bytes, but with every filesystem access injectable
///   (see [FileSizer], [FileHasher], [PathExistsChecker]) so the decision
///   logic itself is directly unit-testable against synthetic fixtures with
///   no real files on disk.
/// - The dry-run/confirm `move_or_report_duplicate` loop ->
///   [TakeoutDuplicateCleaner.run], the thin async layer that walks the
///   `Fotos de YYYY` / `YYYY` directory pairs and delegates the actual move
///   to the shared [SafeFileMover] primitive in `filesystem_ops.dart` (the
///   same primitive `restore_from_trash.dart`/`delete_duplicates.dart` use).
///
/// ## Design decision: not wired into `pipeline_models.dart` /
/// `media_pipeline_app.dart`
///
/// Same "port the logic, defer the wiring" pattern as the two prior ports in
/// this series: the actual executed pipeline step still shells out to the
/// real `scripts/12_clean_immich_takeout_duplicates.sh`. Wiring the
/// container/Dart-native execution path is Phase 2 of issue #76, not this
/// slice.
///
/// ## Design decision: the typed confirmation phrase
///
/// Unlike `06_delete_duplicates.sh`/`11_restore_from_trash.sh` (which only
/// gate on a `--confirm` flag), this script also requires the operator to
/// type the exact phrase `"MOVE TAKEOUT DUPLICATES"` at an interactive
/// prompt before anything moves. Since this port isn't wired into the app
/// yet, the actual interactive prompt still lives entirely in the real Bash
/// script (nothing in this file ever reads stdin or constructs a confirm
/// command). [kTakeoutDuplicatesConfirmPhrase] and
/// [isTakeoutDuplicatesConfirmationPhraseValid] exist so that phrase is
/// already ported, named, and unit-tested ahead of Phase 2 wiring, rather
/// than left as something to invent later — [TakeoutDuplicateCleaner.run]
/// itself still takes a plain `confirm` bool (mirroring
/// `TrashRestorer.run`/`DuplicateDeleter.run`'s precedent exactly), on the
/// assumption that whatever calls it has already gated on a typed phrase
/// matching [kTakeoutDuplicatesConfirmPhrase] the same way the real Bash
/// script's CLI entry point does today.
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
/// The move never leaves a verified duplicate un-moved on collision;
/// [TakeoutDuplicateOutcome.destinationPath] reflects the actual path used,
/// which may carry a numbered suffix. This does not affect the verify/skip
/// *decision* logic that the Bash-vs-Dart parity test in
/// `test/clean_takeout_duplicates_test.dart` verifies.

// ---------------------------------------------------------------------------
// Typed confirmation phrase (see design decision above)
// ---------------------------------------------------------------------------

/// The exact phrase `scripts/12_clean_immich_takeout_duplicates.sh` prompts
/// for (`CONFIRM_PHRASE="MOVE TAKEOUT DUPLICATES"`) before moving anything
/// in `--confirm` mode.
const String kTakeoutDuplicatesConfirmPhrase = 'MOVE TAKEOUT DUPLICATES';

/// True only if [typed] is an exact match for
/// [kTakeoutDuplicatesConfirmPhrase], mirroring the Bash script's
/// `[[ "$typed_confirmation" != "$CONFIRM_PHRASE" ]]` check (no trimming,
/// no case-insensitivity — an exact match is required).
bool isTakeoutDuplicatesConfirmationPhraseValid(String typed) =>
    typed == kTakeoutDuplicatesConfirmPhrase;

// ---------------------------------------------------------------------------
// Pure logic: localized year-folder name matching
// ---------------------------------------------------------------------------

final RegExp _localizedYearFolderNamePattern = RegExp(
  r'^Fotos de ([0-9]{4})$',
);

/// Port of the Bash script's
/// `[[ "$localized_name" =~ ^Fotos\ de\ ([0-9]{4})$ ]]` check: returns the
/// 4-digit year if [directoryName] is exactly `Fotos de YYYY`, or `null`
/// otherwise (no match, e.g. a differently-named folder like `Albums`,
/// which the Bash script's `while` loop — driven by a `find -name
/// 'Fotos de [0-9][0-9][0-9][0-9]'` glob — never even visits).
String? matchLocalizedYearFolderName(String directoryName) {
  final match = _localizedYearFolderNamePattern.firstMatch(directoryName);
  return match?.group(1);
}

// ---------------------------------------------------------------------------
// Pure-ish logic: three-way verification (basename + size + hash)
// ---------------------------------------------------------------------------

/// Port of `inspect_candidate`'s verification outcome. `verified` is the
/// only outcome where all three checks (basename match — implicit in the
/// canonical-path lookup —, size match, hash match) agreed; every other
/// value corresponds 1:1 to one of the Bash script's early-return branches.
enum TakeoutDuplicateVerification {
  /// No file exists at the expected canonical path (same basename, under
  /// the paired `YYYY` directory). Mirrors `[[ ! -f "$canonical" ]]`.
  missingCanonical,

  /// A canonical file exists but its size differs from the candidate's.
  /// Mirrors `[[ "$duplicate_size" != "$canonical_size" ]]`. Checked before
  /// hashing, exactly like the Bash script (cheaper check first; a size
  /// mismatch never reaches the hash comparison).
  sizeMismatch,

  /// Sizes matched but the SHA-256 hashes differ. Mirrors
  /// `[[ "$duplicate_hash" != "$canonical_hash" ]]`.
  hashMismatch,

  /// Basename, size, and hash all agree — a real, verified duplicate.
  verified,
}

/// Reads a file's size in bytes. The default ([defaultFileSizer]) is a
/// plain `File.length()`; tests can inject a fake to exercise
/// [verifyTakeoutDuplicateCandidate]'s decision logic without real files on
/// disk.
typedef FileSizer = Future<int> Function(String path);

/// Computes a file's content hash (SHA-256, matching the Bash script's
/// `sha256sum`). The default ([defaultFileHasher]) shells out to the real
/// `sha256sum` binary — the same external-tool convention
/// `pipeline_models.dart` already declares for this pipeline step
/// (`requiredTools: ['sha256sum']`) — rather than adding a new Dart hashing
/// package dependency. Tests can inject a fake to exercise the decision
/// logic without real files or subprocesses.
typedef FileHasher = Future<String> Function(String path);

/// Checks whether a file exists at [path]. The default
/// ([defaultPathExists]) is a plain `File.exists()`; tests can inject a fake
/// to exercise [verifyTakeoutDuplicateCandidate] without real files on disk.
typedef PathExistsChecker = Future<bool> Function(String path);

/// Default [FileSizer]: `File(path).length()`.
Future<int> defaultFileSizer(String path) => File(path).length();

/// Default [PathExistsChecker]: `File(path).exists()`.
Future<bool> defaultPathExists(String path) => File(path).exists();

/// Default [FileHasher]: shells out to `sha256sum`, matching the Bash
/// script's `sha256sum "$1" | awk '{print $1}'` exactly (the first
/// whitespace-separated token of `sha256sum`'s output is the hex digest).
Future<String> defaultFileHasher(String path) async {
  final result = await Process.run(
    'sha256sum',
    [path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw FileSystemException(
      'sha256sum failed for "$path": ${result.stderr}',
      path,
    );
  }
  final stdout = result.stdout as String;
  final firstToken = stdout.trim().split(RegExp(r'\s+')).first;
  return firstToken;
}

/// Port of `inspect_candidate`'s three-way verification: does a file exist
/// at [canonicalPath], and — only if so — do [duplicatePath] and
/// [canonicalPath] agree on size, and — only if so — do they agree on
/// SHA-256 hash? All three must agree for [TakeoutDuplicateVerification.verified];
/// this never weakens to a size-only or basename-only check, matching
/// `.company/forbidden-actions.md` and `CLAUDE.md`'s safety rules exactly.
///
/// Every filesystem access is injectable ([sizer], [hasher], [exists]), so
/// this function's branching logic is directly unit-testable against
/// synthetic size/hash fixtures with no real files on disk — the same
/// injectable-primitive pattern [SafeFileMover] already uses for its
/// [FileCopier].
Future<TakeoutDuplicateVerification> verifyTakeoutDuplicateCandidate({
  required String duplicatePath,
  required String canonicalPath,
  FileSizer sizer = defaultFileSizer,
  FileHasher hasher = defaultFileHasher,
  PathExistsChecker exists = defaultPathExists,
}) async {
  if (!await exists(canonicalPath)) {
    return TakeoutDuplicateVerification.missingCanonical;
  }

  final duplicateSize = await sizer(duplicatePath);
  final canonicalSize = await sizer(canonicalPath);
  if (duplicateSize != canonicalSize) {
    return TakeoutDuplicateVerification.sizeMismatch;
  }

  final duplicateHash = await hasher(duplicatePath);
  final canonicalHash = await hasher(canonicalPath);
  if (duplicateHash != canonicalHash) {
    return TakeoutDuplicateVerification.hashMismatch;
  }

  return TakeoutDuplicateVerification.verified;
}

// ---------------------------------------------------------------------------
// Pure logic: trash destination path convention
// ---------------------------------------------------------------------------

/// Computes the destination path under `$MEDIA_TRASH` for [originalPath],
/// mirroring `move_or_report_duplicate`'s `rel="${duplicate#/}";
/// dst="$MEDIA_TRASH/$rel"` — the same full-original-absolute-path-minus-
/// leading-slash convention `06`/`11`/`13` (post-#62) already use, so
/// `11_restore_from_trash.sh` can always reconstruct the original location.
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
// Async orchestration: walks Fotos de YYYY / YYYY directory pairs and moves
// verified duplicates, mirroring the Bash script's directory walk +
// move_or_report_duplicate.
// ---------------------------------------------------------------------------

/// What happened (or would happen) to one candidate duplicate file.
enum TakeoutDuplicateAction {
  /// Dry-run mode (the default): printed what *would* happen; nothing
  /// touched on disk. Mirrors `Would move duplicate: ...`.
  wouldMove,

  /// Confirm mode: the file was actually moved to `$MEDIA_TRASH`.
  moved,

  /// Confirm mode: the desired destination already existed, so — matching
  /// [SafeFileMover.moveRenamingOnCollision]'s numbered-suffix semantics
  /// (see this file's "trash-move collision handling" design decision
  /// above) — the file was moved to a suffixed alternative instead. See
  /// [TakeoutDuplicateOutcome.destinationPath] for the actual path used.
  movedWithSuffix,

  /// No canonical counterpart exists at all. Mirrors
  /// `Missing canonical for $year: ...`.
  missingCanonical,

  /// A canonical counterpart exists but its size differs. Mirrors
  /// `Size mismatch, skipping: ...`.
  sizeMismatch,

  /// Sizes matched but the hashes differ. Mirrors
  /// `Hash mismatch, skipping: ...`.
  hashMismatch,

  /// Defense-in-depth: the candidate path is not actually under the
  /// localized directory it was supposedly listed from. Unreachable in
  /// practice — every candidate this class processes comes directly from
  /// listing that same directory — but kept to mirror the Bash script's own
  /// belt-and-suspenders `[[ "$duplicate" == "$localized_dir"/* ]]` check in
  /// `inspect_candidate`, the same defense-in-depth precedent
  /// `delete_duplicates.dart`'s `refusedOutsideStaging` already set.
  refusedOutsideLocalized,
}

/// The outcome of processing one candidate duplicate file.
class TakeoutDuplicateOutcome {
  const TakeoutDuplicateOutcome({
    required this.duplicatePath,
    required this.canonicalPath,
    required this.action,
    this.destinationPath,
  });

  final String duplicatePath;

  /// The canonical counterpart's path (same basename, under the paired
  /// `YYYY` directory). Empty only for
  /// [TakeoutDuplicateAction.refusedOutsideLocalized], which never computes
  /// one.
  final String canonicalPath;

  final TakeoutDuplicateAction action;

  /// The (would-be) destination under `$MEDIA_TRASH`. Null for any action
  /// that never verified as a real duplicate
  /// ([TakeoutDuplicateAction.missingCanonical],
  /// [TakeoutDuplicateAction.sizeMismatch],
  /// [TakeoutDuplicateAction.hashMismatch],
  /// [TakeoutDuplicateAction.refusedOutsideLocalized]).
  final String? destinationPath;

  @override
  String toString() =>
      'TakeoutDuplicateOutcome($action, $duplicatePath -> $destinationPath)';
}

/// One `Fotos de YYYY` / `YYYY` directory pair's outcome.
class TakeoutYearFolderOutcome {
  const TakeoutYearFolderOutcome({
    required this.year,
    required this.localizedDir,
    required this.canonicalDir,
    required this.canonicalDirFound,
    required this.candidates,
  });

  final String year;
  final String localizedDir;
  final String canonicalDir;

  /// False if [canonicalDir] didn't exist at all, mirroring
  /// `Missing canonical year folder for $localized_name: ...`. When false,
  /// [candidates] is always empty — the Bash script never even lists the
  /// localized directory's files in that case.
  final bool canonicalDirFound;

  /// Empty when [canonicalDirFound] is false.
  final List<TakeoutDuplicateOutcome> candidates;
}

/// The full outcome of one [TakeoutDuplicateCleaner.run] call, including the
/// same summary counters the Bash script prints
/// (`inspected`/`verified`/`skipped_missing`/`skipped_size`/`skipped_hash`).
class TakeoutCleanupSummary {
  const TakeoutCleanupSummary({
    required this.yearFolders,
    required this.inspected,
    required this.verified,
    required this.skippedMissingCanonicalFile,
    required this.skippedSize,
    required this.skippedHash,
    required this.missingCanonicalYearFolders,
  });

  final List<TakeoutYearFolderOutcome> yearFolders;

  /// Total candidates whose basename+canonical-path lookup was attempted.
  /// Mirrors `$inspected` — note this does NOT count a
  /// `Missing canonical year folder` case (the whole localized directory is
  /// skipped before any of its files are inspected), matching the Bash
  /// script's control flow exactly.
  final int inspected;

  /// Total candidates that passed all three checks. Mirrors `$verified`.
  final int verified;

  /// Total candidates with no canonical file at all. Mirrors
  /// `$skipped_missing`.
  final int skippedMissingCanonicalFile;

  /// Total candidates with a size mismatch. Mirrors `$skipped_size`.
  final int skippedSize;

  /// Total candidates with a hash mismatch (despite matching size). Mirrors
  /// `$skipped_hash`.
  final int skippedHash;

  /// Years whose localized folder had no matching canonical `YYYY` folder at
  /// all.
  final List<String> missingCanonicalYearFolders;
}

/// Dart port of `12_clean_immich_takeout_duplicates.sh`'s directory-pairing
/// walk + `inspect_candidate` + `move_or_report_duplicate` orchestration:
/// for each `Fotos de YYYY` directory under [googleFotosDir], finds the
/// matching canonical `YYYY` directory, three-way-verifies every file in
/// the localized directory against its same-named canonical counterpart,
/// and — in confirm mode — moves every verified duplicate to `$MEDIA_TRASH`
/// via the shared [SafeFileMover].
///
/// Dry-run is the default (`confirm: false`), matching the Bash script and
/// every other confirm-gated script in this pipeline. Nothing is ever
/// deleted: every action is either a no-op (dry-run or missing/mismatched
/// canonical) or a move from the duplicate's original path to
/// [trashDestinationPath] (possibly suffixed — see
/// [TakeoutDuplicateAction.movedWithSuffix]).
class TakeoutDuplicateCleaner {
  const TakeoutDuplicateCleaner({
    required this.trashRoot,
    this.sizer = defaultFileSizer,
    this.hasher = defaultFileHasher,
    this.copier = defaultFileCopier,
  });

  /// Mirrors `$MEDIA_TRASH`.
  final String trashRoot;

  /// Only ever overridden by tests; real callers always get the default
  /// `File.length()` implementation.
  final FileSizer sizer;

  /// Only ever overridden by tests; real callers always get the default
  /// `sha256sum` shell-out implementation.
  final FileHasher hasher;

  /// Only ever overridden by tests (see [FileCopier]'s doc comment on
  /// `filesystem_ops.dart`); real callers always get the default
  /// `File.copy` implementation.
  final FileCopier copier;

  /// Walks [googleFotosDir] (mirroring `$GOOGLE_FOTOS_DIR` =
  /// `$IMMICH_LIBRARY/Takeout/Google Fotos`), finds every immediate
  /// subdirectory named `Fotos de YYYY`, pairs it with the canonical `YYYY`
  /// subdirectory, and three-way-verifies + (in confirm mode) moves every
  /// file inside. Both directory levels are walked non-recursively
  /// (`-mindepth 1 -maxdepth 1`, matching the Bash script exactly) and in
  /// sorted order (for deterministic output — the Bash script's `find |
  /// sort -z` guarantees the same).
  ///
  /// If [googleFotosDir] doesn't exist, returns an all-zero summary and
  /// touches nothing, mirroring the Bash script's
  /// `[[ ! -d "$GOOGLE_FOTOS_DIR" ]] && ... exit 0` early return.
  Future<TakeoutCleanupSummary> run({
    required String googleFotosDir,
    bool confirm = false,
  }) async {
    final normalizedRoot =
        googleFotosDir.endsWith('/') && googleFotosDir.length > 1
        ? googleFotosDir.substring(0, googleFotosDir.length - 1)
        : googleFotosDir;

    final rootDir = Directory(normalizedRoot);
    if (!await rootDir.exists()) {
      return const TakeoutCleanupSummary(
        yearFolders: [],
        inspected: 0,
        verified: 0,
        skippedMissingCanonicalFile: 0,
        skippedSize: 0,
        skippedHash: 0,
        missingCanonicalYearFolders: [],
      );
    }

    final mover = SafeFileMover(copier: copier);

    final localizedDirPaths = <String>[
      await for (final entity in rootDir.list(followLinks: false))
        if (entity is Directory) entity.path,
    ]..sort();

    var inspected = 0;
    var verified = 0;
    var skippedMissingCanonicalFile = 0;
    var skippedSize = 0;
    var skippedHash = 0;
    final missingCanonicalYearFolders = <String>[];
    final yearFolderOutcomes = <TakeoutYearFolderOutcome>[];

    for (final localizedDirPath in localizedDirPaths) {
      final localizedName = localizedDirPath.split('/').last;
      final year = matchLocalizedYearFolderName(localizedName);
      if (year == null) {
        // Not a "Fotos de YYYY" directory at all — the Bash script's `find
        // -name 'Fotos de [0-9][0-9][0-9][0-9]'` glob never visits it
        // either.
        continue;
      }

      final canonicalDirPath = '$normalizedRoot/$year';
      if (!await Directory(canonicalDirPath).exists()) {
        missingCanonicalYearFolders.add(year);
        yearFolderOutcomes.add(
          TakeoutYearFolderOutcome(
            year: year,
            localizedDir: localizedDirPath,
            canonicalDir: canonicalDirPath,
            canonicalDirFound: false,
            candidates: const [],
          ),
        );
        continue;
      }

      final duplicatePaths = <String>[
        await for (final entity in Directory(
          localizedDirPath,
        ).list(followLinks: false))
          if (entity is File) entity.path,
      ]..sort();

      final candidateOutcomes = <TakeoutDuplicateOutcome>[];
      for (final duplicatePath in duplicatePaths) {
        final outcome = await _processCandidate(
          duplicatePath: duplicatePath,
          localizedDir: localizedDirPath,
          canonicalDir: canonicalDirPath,
          mover: mover,
          confirm: confirm,
        );
        candidateOutcomes.add(outcome);

        switch (outcome.action) {
          case TakeoutDuplicateAction.refusedOutsideLocalized:
            // Not counted as inspected, matching the Bash script's
            // `inspect_candidate` (the outside-localized-folder guard
            // returns before `inspected=$((inspected + 1))` runs).
            break;
          case TakeoutDuplicateAction.missingCanonical:
            inspected++;
            skippedMissingCanonicalFile++;
          case TakeoutDuplicateAction.sizeMismatch:
            inspected++;
            skippedSize++;
          case TakeoutDuplicateAction.hashMismatch:
            inspected++;
            skippedHash++;
          case TakeoutDuplicateAction.wouldMove:
          case TakeoutDuplicateAction.moved:
          case TakeoutDuplicateAction.movedWithSuffix:
            inspected++;
            verified++;
        }
      }

      yearFolderOutcomes.add(
        TakeoutYearFolderOutcome(
          year: year,
          localizedDir: localizedDirPath,
          canonicalDir: canonicalDirPath,
          canonicalDirFound: true,
          candidates: candidateOutcomes,
        ),
      );
    }

    return TakeoutCleanupSummary(
      yearFolders: yearFolderOutcomes,
      inspected: inspected,
      verified: verified,
      skippedMissingCanonicalFile: skippedMissingCanonicalFile,
      skippedSize: skippedSize,
      skippedHash: skippedHash,
      missingCanonicalYearFolders: missingCanonicalYearFolders,
    );
  }

  Future<TakeoutDuplicateOutcome> _processCandidate({
    required String duplicatePath,
    required String localizedDir,
    required String canonicalDir,
    required SafeFileMover mover,
    required bool confirm,
  }) async {
    if (!duplicatePath.startsWith('$localizedDir/')) {
      return TakeoutDuplicateOutcome(
        duplicatePath: duplicatePath,
        canonicalPath: '',
        action: TakeoutDuplicateAction.refusedOutsideLocalized,
      );
    }

    final basename = duplicatePath.split('/').last;
    final canonicalPath = '$canonicalDir/$basename';

    final verification = await verifyTakeoutDuplicateCandidate(
      duplicatePath: duplicatePath,
      canonicalPath: canonicalPath,
      sizer: sizer,
      hasher: hasher,
    );

    switch (verification) {
      case TakeoutDuplicateVerification.missingCanonical:
        return TakeoutDuplicateOutcome(
          duplicatePath: duplicatePath,
          canonicalPath: canonicalPath,
          action: TakeoutDuplicateAction.missingCanonical,
        );
      case TakeoutDuplicateVerification.sizeMismatch:
        return TakeoutDuplicateOutcome(
          duplicatePath: duplicatePath,
          canonicalPath: canonicalPath,
          action: TakeoutDuplicateAction.sizeMismatch,
        );
      case TakeoutDuplicateVerification.hashMismatch:
        return TakeoutDuplicateOutcome(
          duplicatePath: duplicatePath,
          canonicalPath: canonicalPath,
          action: TakeoutDuplicateAction.hashMismatch,
        );
      case TakeoutDuplicateVerification.verified:
        final dst = trashDestinationPath(
          trashRoot: trashRoot,
          originalPath: duplicatePath,
        );
        if (!confirm) {
          return TakeoutDuplicateOutcome(
            duplicatePath: duplicatePath,
            canonicalPath: canonicalPath,
            action: TakeoutDuplicateAction.wouldMove,
            destinationPath: dst,
          );
        }
        final outcome = await mover.moveRenamingOnCollision(
          duplicatePath,
          dst,
        );
        return TakeoutDuplicateOutcome(
          duplicatePath: duplicatePath,
          canonicalPath: canonicalPath,
          action: outcome.result == MoveResult.moved
              ? TakeoutDuplicateAction.moved
              : TakeoutDuplicateAction.movedWithSuffix,
          destinationPath: outcome.destinationPath,
        );
    }
  }
}

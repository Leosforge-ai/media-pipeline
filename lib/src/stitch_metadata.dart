import 'dart:convert';
import 'dart:io';

import 'filesystem_ops.dart';
import 'tools_container.dart';

/// Dart port of `scripts/04_stitch_metadata.py` — Phase 0c of issue
/// #76/#77's shared roadmap, the last piece of shared Phase 0 (drive
/// detection (0a) + the four confirm-gated destructive scripts (0b) were
/// already ported; see `drive_detection.dart`, `restore_from_trash.dart`,
/// `delete_duplicates.dart`, `clean_takeout_duplicates.dart`,
/// `dedupe_live_photos.dart`).
///
/// Unlike the four scripts in Phase 0b, `04_stitch_metadata.py` never moves
/// anything to `$MEDIA_TRASH` and has no confirm-gate/typed-phrase concept —
/// it extracts Google Takeout archives, matches each media file to its
/// Google Photos JSON metadata sidecar (if any), applies that metadata with
/// `exiftool`, and moves every media file (whether or not metadata could be
/// applied) into `$HD_PATH/cleaning_staging`. It is still safety-relevant
/// though: it's the step that decides what data and metadata actually end
/// up in `cleaning_staging` in the first place, and this repo's Python hard
/// rule for this exact script is "continue past individual corrupt media
/// files, log warnings clearly" — ported here as this file's own hard rule
/// (see [MetadataStitcher.run]'s per-archive try/catch and
/// [processExtractedTree]'s per-media-file handling).
///
/// ## Design decision: archive extraction shells out to `unzip`/`tar`
///
/// The Python script uses the stdlib `zipfile`/`tarfile` modules — no
/// external archive-handling *package* is a dependency of this repo's
/// `pubspec.yaml` (only `flutter`/`flutter_test`/`flutter_lints`). Adding a
/// pure-Dart archive package (e.g. `archive` from pub.dev) was considered,
/// but every other external-tool integration in this codebase (`exiftool`
/// itself, `ffprobe` in `dedupe_live_photos.dart`, `rclone`, `czkawka_cli`)
/// already follows the same pattern: shell out via `Process.run` with an
/// overridable binary path, never add a pub.dev dependency to replace a
/// system tool. `unzip`/`tar` are both already implicit dependencies of
/// this repo (`01_setup_dependencies.sh`'s target Linux environment ships
/// both; `docs/TROUBLESHOOTING.md` already documents `.zip`/`.tgz`/`.tar.gz`
/// as the three supported archive types). Shelling out keeps this port
/// consistent with that precedent instead of introducing the only pure-Dart
/// decoder dependency in the app. See [TakeoutArchiveExtractor] for the
/// list-then-validate-then-extract flow that reproduces
/// `safe_extract_zip`/`safe_extract_tar`'s path-traversal guard without
/// trusting `unzip -o`/`tar -x` alone to do it.
///
/// ## Design decision: `moveToStaging` does not use
/// `SafeFileMover.moveNoClobber`'s skip-on-collision semantics directly
///
/// Every Phase 0b port uses [SafeFileMover.moveNoClobber]'s "leave the
/// source in place if the destination already exists" behavior, because
/// those scripts have an explicit dry-run/confirm split and a human
/// reviewing a report first. `04_stitch_metadata.py`'s `move_to_staging`
/// has no such split — it *always* moves every media file it finds,
/// resolving a same-basename collision in `cleaning_staging` by appending a
/// numbered suffix (`photo_1.jpg`, `photo_2.jpg`, ...) rather than skipping.
/// [moveToStaging] preserves that exact numbered-suffix behavior (see
/// `tests/test_stitch_metadata.py::test_move_to_staging_renames_colliding_media`,
/// mirrored in `test/stitch_metadata_test.dart`), but still delegates the
/// actual byte-safe move mechanics to [SafeFileMover.moveNoClobber] once a
/// free destination name has been chosen — reusing the same cross-device
/// (`EXDEV`) fallback + copy-verify-then-delete safety net every other port
/// in this series relies on, instead of re-implementing `shutil.move`
/// semantics from scratch.
///
/// ## Design decision: `apply_metadata_with_exiftool`'s `len(args) == 3`
/// check is preserved exactly, including its apparent off-by-one quirk
///
/// The real Python function builds `args = ["exiftool", "-overwrite_original"]`
/// (length 2) and only appends `-Title=...`/`-Description=...`/date/GPS
/// flags when the corresponding metadata is present, then returns `False`
/// (skip exiftool entirely) `if len(args) == 3`. Read literally, this
/// means: if *exactly one* single-flag tag was added (e.g. only `title` is
/// present in the JSON sidecar, with no `photoTakenTime`/`creationTime`,
/// no `description`, and no `geoData`), the function treats that as "no
/// useful tags" and skips exiftool — even though a real, useful `-Title=`
/// flag was queued. This looks like an off-by-one bug (the "no tags at
/// all" case is actually `len(args) == 2`), but this port's brief is to
/// match the *exact* existing behavior for parity, not to silently fix
/// production logic during a port. [applyMetadataWithExiftool] preserves
/// this exact check (see its own doc comment). Flagged explicitly in this
/// PR's body for Cody/Astrid to weigh in on whether a follow-up fix issue
/// against the Python script is warranted — out of scope for this
/// port-for-parity PR either way.
///
/// ## Design decision: all three external tools (`unzip`/`tar`/`exiftool`)
/// route through [ToolsContainer] (Phase 2 of issue #76)
///
/// Following the `ffprobe` migration in `dedupe_live_photos.dart` (PR #94,
/// the first Phase 2 consumer migration), this port's three external-tool
/// call sites — [TakeoutArchiveExtractor]'s zip/tar listing+extraction and
/// [applyMetadataWithExiftool]'s `exiftool` invocation — now have
/// container-routed implementations: [containerZipLister],
/// [containerZipExtractor], [containerTarLister], [containerTarExtractor]
/// (bundled together for the common case by
/// [containerTakeoutArchiveExtractor]), and [containerExiftoolRunner]. Each
/// translates every host path it's given to its container-mounted
/// equivalent via [ToolsContainer.hostToContainerPath] before exec'ing,
/// exactly mirroring [containerFfprobeDurationReader]'s pattern.
///
/// **Hard cutover, matching PR #94's precedent.** [MetadataStitcher]'s
/// [MetadataStitcher.exiftool] and [MetadataStitcher.archiveExtractor] are
/// now *required* constructor parameters — there is no longer an implicit
/// default that silently shells out to a host-installed `unzip`/`tar`/
/// `exiftool`. Same rationale as PR #94: this repo's target users already
/// require Docker (for Immich itself), so a "just in case" host fallback
/// would only invite a caller to bypass the container path — and the
/// path-translation safety net that comes with it — by omission. The
/// host-shelling defaults ([exiftoolRunner], [TakeoutArchiveExtractor]'s own
/// no-argument constructor, which defaults to [defaultZipLister] /
/// [defaultZipExtractor] / [defaultTarLister] / [defaultTarExtractor]) are
/// kept — they remain the most direct way to unit-test this module's
/// decision logic without standing up a container.
///
/// **Where extraction happens, and why the host sees results immediately.**
/// [extractArchive] creates `destDir` on the *host* filesystem before
/// calling into [TakeoutArchiveExtractor.extract] (unchanged by this
/// migration). Since `destDir` lives under `$HD_PATH/takeout_extracted`,
/// and callers are expected to construct their [ToolsContainer] with
/// `hostMountRoot` set to (an ancestor of) `$HD_PATH` — exactly like PR
/// #94's `containerFfprobeDurationReader` expects for `$MEDIA_TRASH`/video
/// paths — `destDir` is always inside the bind mount. The container-routed
/// extractor translates `destDir` to its container path and runs `unzip -d`/
/// `tar -C` against it; because the bind mount is the *same* underlying
/// filesystem on both sides (not a copy), every file the container process
/// writes under that path is visible to the host the moment `docker exec`
/// returns — no explicit sync/copy step is needed, and this is verified for
/// real (not just asserted) by this PR's Docker-gated end-to-end test (see
/// `test/stitch_metadata_test.dart`'s "stitch metadata via a real
/// ToolsContainer" group).
///
/// **How the two path-safety mechanisms compose.**
/// [isPathTraversalSafe] validates archive *member* names against `destDir`
/// (a pure string check: could extracting a member named `../../etc/passwd`
/// land outside `destDir`?) — this check runs entirely in [extract], on
/// host-domain paths, *before* the container-routed lister/extractor
/// functions are ever invoked, and is completely unaware that a container is
/// involved at all. Separately, [ToolsContainer.hostToContainerPath]
/// validates that `destDir` *itself* (and the archive path) fall inside
/// [ToolsContainer.hostMountRoot] — a check about the boundary of the bind
/// mount, unrelated to what's inside the archive. These two checks operate
/// on different axes (member-relative-to-destDir vs.
/// destDir-relative-to-mount-root) and neither can substitute for or weaken
/// the other: an archive with a path-traversal member is blocked by
/// [isPathTraversalSafe] regardless of whether `destDir` is a legal
/// container path at all (the member-safety loop in [extract] runs and can
/// throw before any exec happens), and a `destDir` outside the mount root is
/// rejected by [ToolsContainer.hostToContainerPath] regardless of whether
/// every member inside the archive is perfectly safe (the container-routed
/// extractor's translation call throws before building the `unzip`/`tar`
/// argument list). Neither mechanism trusts the other to have already
/// caught a given class of problem. This composition is exercised directly
/// by `test/stitch_metadata_test.dart`'s "container path-safety
/// composition" group: one test proves an unsafe archive member is still
/// blocked pre-exec even when routed through the container lister/extractor
/// (no `docker exec` for extraction ever happens), and another proves a
/// `destDir` outside the container's mount root is rejected even when every
/// archive member is individually safe.

// ---------------------------------------------------------------------------
// Path helpers (mirroring `config/pipeline_config.py`'s HD_PATH-derived
// paths). These are pure string functions, not a new shared settings type —
// `lib/src/pipeline_models.dart` (which owns `PipelineSettings`) is
// explicitly out of scope for this port, matching every prior Phase 0b
// port's isolation from that file.
// ---------------------------------------------------------------------------

/// Joins [hdPath] and a child segment with a single `/`, mirroring
/// `pathlib.Path.__truediv__` closely enough for this script's needs
/// (trailing-slash-tolerant on [hdPath]).
String _joinPath(String hdPath, String child) {
  final trimmed = hdPath.endsWith('/') && hdPath.length > 1
      ? hdPath.substring(0, hdPath.length - 1)
      : hdPath;
  return '$trimmed/$child';
}

/// Mirrors `RAW_GDRIVE = HD_PATH / "raw_gdrive"`.
String rawGdrivePath(String hdPath) => _joinPath(hdPath, 'raw_gdrive');

/// Mirrors `RAW_TAKEOUT_ZIPS = HD_PATH / "raw_takeout_zips"`.
String rawTakeoutZipsPath(String hdPath) =>
    _joinPath(hdPath, 'raw_takeout_zips');

/// Mirrors `TAKEOUT_EXTRACTED = HD_PATH / "takeout_extracted"`.
String takeoutExtractedPath(String hdPath) =>
    _joinPath(hdPath, 'takeout_extracted');

/// Mirrors `CLEANING_STAGING = HD_PATH / "cleaning_staging"`.
String cleaningStagingPath(String hdPath) =>
    _joinPath(hdPath, 'cleaning_staging');

/// Mirrors `WARNING_LOG = HD_PATH / "stitch_metadata_warnings.md"` — see
/// `docs/TROUBLESHOOTING.md`'s existing "Metadata script stops on a broken
/// video" section, which already documents this exact path for operators.
String stitchWarningLogPath(String hdPath) =>
    _joinPath(hdPath, 'stitch_metadata_warnings.md');

// ---------------------------------------------------------------------------
// Media file / archive filename classification (pure, no IO).
// ---------------------------------------------------------------------------

/// Mirrors `MEDIA_EXTENSIONS` in `config/pipeline_config.py` exactly.
const Set<String> kStitchMediaExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif',
  '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.3gp', '.webm',
};

/// True if [path]'s extension (case-insensitively) is one of
/// [kStitchMediaExtensions]. This is the pure, filename-only half of
/// Python's `is_media_file`; the `path.is_file()` filesystem check is done
/// separately by the caller walking the directory tree (see
/// [processExtractedTree]), since a pure function can't check the
/// filesystem without an IO seam.
bool isMediaExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1) return false;
  final ext = path.substring(dot).toLowerCase();
  return kStitchMediaExtensions.contains(ext);
}

/// Mirrors `archive_stem`: strips a known archive suffix
/// (`.tar.gz`/`.tgz`/`.zip`, checked case-insensitively, longest-first so
/// `.tar.gz` is never partially matched as `.gz`) from [archiveFileName],
/// falling back to the filename with its single last extension stripped
/// (mirroring `Path.stem`) if none of the three known suffixes match.
String archiveStem(String archiveFileName) {
  final lower = archiveFileName.toLowerCase();
  for (final suffix in ['.tar.gz', '.tgz', '.zip']) {
    if (lower.endsWith(suffix)) {
      return archiveFileName.substring(
        0,
        archiveFileName.length - suffix.length,
      );
    }
  }
  final dot = archiveFileName.lastIndexOf('.');
  return dot <= 0 ? archiveFileName : archiveFileName.substring(0, dot);
}

/// The two archive formats this script supports, mirroring the branch in
/// Python's `extract_archive` (`.zip` -> `safe_extract_zip`,
/// `.tgz`/`.tar.gz` -> `safe_extract_tar`).
enum ArchiveKind { zip, tarGz }

/// Classifies [archiveFileName] by its (case-insensitive) suffix, or
/// returns `null` for an unsupported type — mirroring `extract_archive`'s
/// `else: raise RuntimeError(f"Unsupported archive type: {archive}")`
/// branch (callers should throw when this returns `null`).
ArchiveKind? archiveKindFor(String archiveFileName) {
  final lower = archiveFileName.toLowerCase();
  if (lower.endsWith('.zip')) return ArchiveKind.zip;
  if (lower.endsWith('.tgz') || lower.endsWith('.tar.gz')) {
    return ArchiveKind.tarGz;
  }
  return null;
}

/// True if [fileName] matches one of the three archive suffixes
/// `supported_archives`'s glob patterns look for (`*.zip`, `*.tgz`,
/// `*.tar.gz`). Matches Python's `Path.glob` case-sensitivity on a
/// case-sensitive (e.g. Linux ext4) filesystem: an exact, case-sensitive
/// suffix check, deliberately *not* lower-cased (unlike [isMediaExtension],
/// which mirrors `path.suffix.lower()`) — this is a faithfully-preserved
/// inconsistency between the two checks in the original script.
bool isSupportedArchiveFileName(String fileName) {
  return fileName.endsWith('.zip') ||
      fileName.endsWith('.tgz') ||
      fileName.endsWith('.tar.gz');
}

// ---------------------------------------------------------------------------
// JSON sidecar matching (candidate_jsons_for_media).
// ---------------------------------------------------------------------------

/// Splits [path] into `(parentDir, fileName)` on the last `/`. If there is
/// no `/`, the parent is `.` (mirroring `Path(name).parent` for a bare
/// filename).
(String, String) _splitParentAndName(String path) {
  final idx = path.lastIndexOf('/');
  if (idx == -1) return ('.', path);
  final parent = idx == 0 ? '/' : path.substring(0, idx);
  return (parent, path.substring(idx + 1));
}

/// Returns the filename with its single last extension stripped (mirroring
/// `Path.stem`), or the whole filename if it has no `.`.
String _stemOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}

/// Port of `candidate_jsons_for_media`: returns the likely Google Photos
/// JSON sidecar path(s) for [mediaPath], checked against the real
/// filesystem, in the same priority order Python builds its `candidates`
/// list:
///
/// 1. `<name>.json`
/// 2. `<stem>.json`
/// 3. `<name>.supplemental-metadata.json`
/// 4. `<stem>.supplemental-metadata.json`
/// 5. Any `.json` file in the same directory whose name starts with the
///    first 45 characters of `<name>` (Google truncates long sidecar
///    filenames), then likewise for `<stem>`.
///
/// Only sidecars that actually exist are returned, de-duplicated by path
/// while preserving first-seen order — mirroring Python's `seen: set[Path]`
/// bookkeeping. Unlike `Path.glob` (whose enumeration order is
/// filesystem-dependent and not guaranteed sorted), the two "truncated
/// name" glob-equivalent scans here sort their directory-listing matches
/// before appending them, for deterministic behavior — a strictly safer,
/// non-decision-changing choice (this only affects *tie-break ordering*
/// among otherwise-equally-valid truncated-match candidates, not whether
/// any given file is considered a candidate at all).
Future<List<String>> candidateJsonsForMedia(String mediaPath) async {
  final (parent, name) = _splitParentAndName(mediaPath);
  final stem = _stemOf(name);

  final ordered = <String>[
    '$parent/$name.json',
    '$parent/$stem.json',
    '$parent/$name.supplemental-metadata.json',
    '$parent/$stem.supplemental-metadata.json',
  ];

  final namePrefix = name.length > 45 ? name.substring(0, 45) : name;
  final stemPrefix = stem.length > 45 ? stem.substring(0, 45) : stem;
  ordered.addAll(await _globJsonByPrefix(parent, namePrefix));
  if (stemPrefix != namePrefix) {
    ordered.addAll(await _globJsonByPrefix(parent, stemPrefix));
  }

  final seen = <String>{};
  final result = <String>[];
  for (final candidate in ordered) {
    if (seen.contains(candidate)) continue;
    if (await File(candidate).exists()) {
      seen.add(candidate);
      result.add(candidate);
    }
  }
  return result;
}

/// Lists `*.json` files directly inside [parentDir] whose name starts with
/// [prefix], sorted for determinism (see [candidateJsonsForMedia]'s doc
/// comment on why this sorts instead of relying on raw directory order).
Future<List<String>> _globJsonByPrefix(String parentDir, String prefix) async {
  final dir = Directory(parentDir);
  if (!await dir.exists()) return const [];
  final matches = <String>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.path.split('/').last;
    if (name.startsWith(prefix) && name.endsWith('.json')) {
      matches.add(entity.path);
    }
  }
  matches.sort();
  return matches;
}

// ---------------------------------------------------------------------------
// Timestamp extraction (extract_timestamp).
// ---------------------------------------------------------------------------

/// Port of `extract_timestamp`: looks for `photoTakenTime` then
/// `creationTime` in [meta] (Google Takeout's two possible timestamp keys,
/// checked in that priority order), and if the key holds a map with a
/// truthy `timestamp` (a Unix-epoch-seconds string), formats it as
/// `exiftool`'s `YYYY:MM:DD HH:MM:SS` datetime string in UTC. Returns
/// `null` if neither key is usable (missing, wrong shape, or a
/// non-integer-parseable `timestamp` value) — mirroring the bare
/// `except Exception: return None` in the Python version.
String? extractTimestamp(Map<String, dynamic> meta) {
  for (final key in ['photoTakenTime', 'creationTime']) {
    final obj = meta[key];
    if (obj is Map && obj['timestamp'] != null) {
      final raw = obj['timestamp'];
      final seconds = raw is int
          ? raw
          : raw is String
          ? int.tryParse(raw)
          : null;
      if (seconds == null) return null;
      final dt = DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      );
      return _formatExiftoolDateTime(dt);
    }
  }
  return null;
}

String _pad2(int v) => v.toString().padLeft(2, '0');
String _pad4(int v) => v.toString().padLeft(4, '0');

/// Formats [dt] (must be UTC) as `exiftool`'s `-DateTimeOriginal`-style
/// value: `YYYY:MM:DD HH:MM:SS`, mirroring
/// `datetime.strftime("%Y:%m:%d %H:%M:%S")`.
String _formatExiftoolDateTime(DateTime dt) {
  return '${_pad4(dt.year)}:${_pad2(dt.month)}:${_pad2(dt.day)} '
      '${_pad2(dt.hour)}:${_pad2(dt.minute)}:${_pad2(dt.second)}';
}

// ---------------------------------------------------------------------------
// exiftool invocation (apply_metadata_with_exiftool).
// ---------------------------------------------------------------------------

/// Logs one warning message. The default implementation ([fileWarningLogger])
/// appends a Markdown bullet (with a UTC ISO-8601 timestamp) to
/// `$HD_PATH/stitch_metadata_warnings.md` and prints `WARNING: ...` to
/// stderr, mirroring `log_warning` exactly (including the file path — see
/// `docs/TROUBLESHOOTING.md`'s existing "Metadata script stops on a broken
/// video" section, which already tells operators to check this file; this
/// port keeps that operator-facing convention unchanged rather than
/// inventing a new one). Tests inject a fake to assert on warnings without
/// touching the filesystem, the same overridable-seam pattern as
/// `VideoDurationReader` in `dedupe_live_photos.dart`.
typedef WarningLogger = Future<void> Function(String message);

/// Builds the default [WarningLogger], writing to
/// [stitchWarningLogPath(hdPath)].
WarningLogger fileWarningLogger(String hdPath) {
  return (String message) async {
    final logPath = stitchWarningLogPath(hdPath);
    final file = File(logPath);
    await file.parent.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String();
    await file.writeAsString(
      '- $stamp — $message\n',
      mode: FileMode.append,
    );
    stderr.writeln('WARNING: $message');
  };
}

/// Runs `exiftool` with [args] against the real filesystem, returning
/// `(exitCode, stderr, stdout)`. The default [ExiftoolRunner]
/// ([exiftoolRunner]) shells out to the real binary (overridable, mirroring
/// `dedupe_live_photos.dart`'s `FFPROBE_BIN`-style seam); tests inject a
/// fake binary path or a fake runner to exercise success/failure paths
/// deterministically without needing real image/video files exiftool can
/// actually parse.
typedef ExiftoolRunner =
    Future<(int exitCode, String stderrText, String stdoutText)> Function(
      List<String> args,
    );

/// Builds the default [ExiftoolRunner]: shells out to [exiftoolBin]
/// (defaulting to `exiftool`, matching Bash/Dart precedent elsewhere in
/// this pipeline of an overridable-but-defaulted binary name).
ExiftoolRunner exiftoolRunner({String exiftoolBin = 'exiftool'}) {
  return (List<String> args) async {
    final result = await Process.run(
      exiftoolBin,
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return (
      result.exitCode,
      (result.stderr as String),
      (result.stdout as String),
    );
  };
}

/// Port of `apply_metadata_with_exiftool`: reads [jsonPath], builds the
/// same `exiftool` argument list Python builds (date/time, title,
/// description, GPS coordinates — only including flags for metadata that's
/// actually present), and shells out via [runner]. Returns `true` only if
/// exiftool actually ran and exited `0`.
///
/// If [jsonPath] can't be read/parsed as JSON, or if the exiftool
/// invocation exits non-zero, logs a warning via [warn] (mirroring
/// `log_warning`) and returns `false` — this is what lets
/// [processExtractedTree] "continue past individual corrupt media files"
/// per this script's hard safety rule: a single unreadable sidecar or
/// exiftool failure never aborts the run, it's just recorded and the media
/// file is still moved to staging unmodified.
///
/// Preserves the exact (see this file's top-level doc comment)
/// `if len(args) == 3: return False` check from the Python original: if
/// precisely one single-flag tag (of `-Title=`/`-Description=`) was queued
/// and nothing else (no date, no GPS), this returns `false` and never
/// invokes exiftool at all, even though a real tag was available. This is
/// preserved for byte-for-byte parity with the production script, not
/// because it's understood to be correct — see the module doc comment.
Future<bool> applyMetadataWithExiftool(
  String mediaPath,
  String jsonPath, {
  required ExiftoolRunner runner,
  required WarningLogger warn,
}) async {
  Map<String, dynamic> meta;
  try {
    final raw = await File(jsonPath).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON sidecar did not decode to an object');
    }
    meta = decoded;
  } catch (exc) {
    await warn('Could not read JSON sidecar $jsonPath: $exc');
    return false;
  }

  final args = <String>['-overwrite_original'];

  final dt = extractTimestamp(meta);
  if (dt != null) {
    args.addAll([
      '-DateTimeOriginal=$dt',
      '-CreateDate=$dt',
      '-ModifyDate=$dt',
    ]);
  }

  final title = meta['title'];
  final description = meta['description'];
  if (_isTruthy(title)) args.add('-Title=$title');
  if (_isTruthy(description)) args.add('-Description=$description');

  final geo =
      (meta['geoData'] as Map<String, dynamic>?) ??
      (meta['geoDataExif'] as Map<String, dynamic>?) ??
      const <String, dynamic>{};
  final lat = geo['latitude'];
  final lon = geo['longitude'];
  if (lat is num && lon is num && (lat != 0 || lon != 0)) {
    args.addAll(['-GPSLatitude=$lat', '-GPSLongitude=$lon']);
    args.add(lat >= 0 ? '-GPSLatitudeRef=N' : '-GPSLatitudeRef=S');
    args.add(lon >= 0 ? '-GPSLongitudeRef=E' : '-GPSLongitudeRef=W');
  }

  // Mirrors `if len(args) == 3: return False` exactly. Python's `args`
  // starts as `["exiftool", "-overwrite_original"]` (length 2); this port's
  // `args` omits the executable name (passed separately to [runner]), so
  // the equivalent threshold here is length 2 (Python's 3, minus 1 for the
  // omitted executable-name element).
  if (args.length == 2) {
    return false;
  }

  args.add(mediaPath);
  final (exitCode, stderrText, stdoutText) = await runner(args);
  if (exitCode != 0) {
    final detail = stderrText.trim().isNotEmpty
        ? stderrText.trim()
        : stdoutText.trim();
    await warn('exiftool failed for $mediaPath using $jsonPath: $detail');
    return false;
  }
  return true;
}

/// Mirrors Python's implicit truthiness check (`if title:`): `null`, an
/// empty string, and (defensively, though the JSON shape shouldn't produce
/// these) `0`/`false` are all falsy.
bool _isTruthy(Object? value) {
  if (value == null) return false;
  if (value is String) return value.isNotEmpty;
  if (value is num) return value != 0;
  if (value is bool) return value;
  return true;
}

// ---------------------------------------------------------------------------
// Archive extraction (safe_extract_zip / safe_extract_tar / extract_archive).
// ---------------------------------------------------------------------------

/// Normalizes [path] by resolving `.`/`..` segments against a `/`-rooted
/// walk, without touching the real filesystem (pure — mirrors the
/// resolution `Path.resolve()` performs, but on a path that may not exist
/// yet, e.g. under a not-yet-created extraction destination).
String _normalizeSegments(String path) {
  final isAbsolute = path.startsWith('/');
  final parts = path.split('/');
  final stack = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (stack.isNotEmpty) {
        stack.removeLast();
      } else if (!isAbsolute) {
        // A leading ".." on a relative path can't be resolved further
        // without escaping; keep it so the traversal check below still
        // catches it.
        stack.add('..');
      }
      continue;
    }
    stack.add(part);
  }
  final joined = stack.join('/');
  return isAbsolute ? '/$joined' : joined;
}

/// Port of `safe_extract_zip`/`safe_extract_tar`'s shared path-traversal
/// guard: `str(out.resolve()).startswith(str(dest.resolve()))`. Returns
/// `true` only if extracting an archive member named [memberPath] under
/// [destRoot] would land strictly inside [destRoot] (an absolute member
/// path, or a `..`-laden member path that escapes [destRoot] after
/// normalization, is unsafe).
bool isPathTraversalSafe(String destRoot, String memberPath) {
  if (memberPath.startsWith('/')) return false;
  final normalizedRoot = destRoot.endsWith('/') && destRoot.length > 1
      ? destRoot.substring(0, destRoot.length - 1)
      : destRoot;
  final candidate = _normalizeSegments('$normalizedRoot/$memberPath');
  return candidate == normalizedRoot ||
      candidate.startsWith('$normalizedRoot/');
}

/// Lists the member paths inside an archive without extracting it. The
/// default implementations ([defaultZipLister], [defaultTarLister]) shell
/// out to `unzip -Z1` / `tar -tzf` respectively (both overridable binary
/// names, mirroring [exiftoolRunner]'s seam); tests inject a fake to
/// exercise [TakeoutArchiveExtractor]'s path-traversal guard without
/// needing to fabricate a real malicious archive file.
typedef ArchiveLister = Future<List<String>> Function(String archivePath);

/// Extracts an already-validated archive's *entire* contents into
/// [destDir]. The default implementations shell out to `unzip -o -d`/`tar
/// -xzf -C`. Only ever called after every member has already passed
/// [isPathTraversalSafe] — mirrors Python's
/// `zf.extractall(dest)`/`tf.extractall(dest)`, which likewise only runs
/// after the full validation loop over `infolist()`/`getmembers()`
/// completes.
typedef ArchiveExtractRunner =
    Future<void> Function(String archivePath, String destDir);

/// Default [ArchiveLister] for `.zip` archives: `unzip -Z1 <archive>`
/// (`zipinfo`'s "just the bare names, one per line" mode).
ArchiveLister defaultZipLister({String unzipBin = 'unzip'}) {
  return (String archivePath) async {
    final result = await Process.run(unzipBin, [
      '-Z1',
      archivePath,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to list zip archive $archivePath: ${result.stderr}',
      );
    }
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  };
}

/// Default [ArchiveExtractRunner] for `.zip` archives: `unzip -o -d
/// destDir archive` (`-o` = overwrite without prompting; safe here
/// since [destDir] was just freshly created/cleared by [extractArchive]).
ArchiveExtractRunner defaultZipExtractor({String unzipBin = 'unzip'}) {
  return (String archivePath, String destDir) async {
    final result = await Process.run(unzipBin, [
      '-o',
      '-d',
      destDir,
      archivePath,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to extract zip archive $archivePath: ${result.stderr}',
      );
    }
  };
}

/// Default [ArchiveLister] for `.tgz`/`.tar.gz` archives: `tar -tzf
/// archive`. Directory entries (trailing `/`) are kept as-is; the
/// traversal check treats them the same as file entries.
ArchiveLister defaultTarLister({String tarBin = 'tar'}) {
  return (String archivePath) async {
    final result = await Process.run(tarBin, [
      '-tzf',
      archivePath,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to list tar archive $archivePath: ${result.stderr}',
      );
    }
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  };
}

/// Default [ArchiveExtractRunner] for `.tgz`/`.tar.gz` archives: `tar -xzf
/// archive -C destDir`.
ArchiveExtractRunner defaultTarExtractor({String tarBin = 'tar'}) {
  return (String archivePath, String destDir) async {
    final result = await Process.run(tarBin, [
      '-xzf',
      archivePath,
      '-C',
      destDir,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to extract tar archive $archivePath: ${result.stderr}',
      );
    }
  };
}

/// Sanctioned production [ArchiveLister] for `.zip` archives (Phase 2 of
/// issue #76 — see this file's top-level "Design decision: all three
/// external tools ... route through [ToolsContainer]" doc comment): execs
/// `unzip -Z1` inside [container] against the container-translated archive
/// path. [archivePath] is a *host* path; translated via
/// [ToolsContainer.hostToContainerPath] before exec'ing (which fails loudly
/// if [archivePath] is outside [container]'s `hostMountRoot` — this
/// function adds no separate check of its own).
ArchiveLister containerZipLister({
  required ToolsContainer container,
  String unzipBin = 'unzip',
}) {
  return (String archivePath) async {
    final containerArchivePath = container.hostToContainerPath(archivePath);
    final result = await container.exec([unzipBin, '-Z1', containerArchivePath]);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to list zip archive $archivePath: ${result.stderr}',
      );
    }
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  };
}

/// Sanctioned production [ArchiveExtractRunner] for `.zip` archives: execs
/// `unzip -o -d <container destDir> <container archivePath>` inside
/// [container]. Both [archivePath] and [destDir] are *host* paths,
/// translated independently via [ToolsContainer.hostToContainerPath] before
/// exec'ing — see this file's top-level doc comment's "How the two
/// path-safety mechanisms compose" section for why this translation (a
/// mount-boundary check) is a separate, non-overlapping concern from
/// [isPathTraversalSafe]'s archive-member check, which has already run
/// (against the host-domain [destDir]) by the time this function is called.
/// Only ever invoked after every member has passed that check (see
/// [TakeoutArchiveExtractor.extract]) — `-o` (overwrite without prompting)
/// is safe here for the same reason [defaultZipExtractor] documents: this
/// codebase treats extraction as opening onto a freshly created/cleared
/// [destDir], not a pre-existing directory with untrusted contents.
ArchiveExtractRunner containerZipExtractor({
  required ToolsContainer container,
  String unzipBin = 'unzip',
}) {
  return (String archivePath, String destDir) async {
    final containerArchivePath = container.hostToContainerPath(archivePath);
    final containerDestDir = container.hostToContainerPath(destDir);
    final result = await container.exec([
      unzipBin,
      '-o',
      '-d',
      containerDestDir,
      containerArchivePath,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to extract zip archive $archivePath: ${result.stderr}',
      );
    }
  };
}

/// Sanctioned production [ArchiveLister] for `.tgz`/`.tar.gz` archives:
/// execs `tar -tzf` inside [container] against the container-translated
/// archive path. Same host-path-in, translate-before-exec contract as
/// [containerZipLister].
ArchiveLister containerTarLister({
  required ToolsContainer container,
  String tarBin = 'tar',
}) {
  return (String archivePath) async {
    final containerArchivePath = container.hostToContainerPath(archivePath);
    final result = await container.exec([tarBin, '-tzf', containerArchivePath]);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to list tar archive $archivePath: ${result.stderr}',
      );
    }
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  };
}

/// Sanctioned production [ArchiveExtractRunner] for `.tgz`/`.tar.gz`
/// archives: execs `tar -xzf` (translated container archive path) `-C`
/// (translated container destDir) inside [container]. Same host-path-in,
/// translate-both-independently-before-exec contract as
/// [containerZipExtractor].
ArchiveExtractRunner containerTarExtractor({
  required ToolsContainer container,
  String tarBin = 'tar',
}) {
  return (String archivePath, String destDir) async {
    final containerArchivePath = container.hostToContainerPath(archivePath);
    final containerDestDir = container.hostToContainerPath(destDir);
    final result = await container.exec([
      tarBin,
      '-xzf',
      containerArchivePath,
      '-C',
      containerDestDir,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to extract tar archive $archivePath: ${result.stderr}',
      );
    }
  };
}

/// Builds a [TakeoutArchiveExtractor] wired to the sanctioned production,
/// container-routed listers/extractors ([containerZipLister],
/// [containerZipExtractor], [containerTarLister], [containerTarExtractor])
/// — the convenience constructor real callers ([MetadataStitcher]) are
/// expected to use, mirroring how `dedupe_live_photos.dart` offers
/// [containerFfprobeDurationReader] as a single production-seam builder
/// rather than requiring callers to assemble each piece by hand.
TakeoutArchiveExtractor containerTakeoutArchiveExtractor({
  required ToolsContainer container,
  String unzipBin = 'unzip',
  String tarBin = 'tar',
}) {
  return TakeoutArchiveExtractor(
    zipLister: containerZipLister(container: container, unzipBin: unzipBin),
    zipExtractor: containerZipExtractor(
      container: container,
      unzipBin: unzipBin,
    ),
    tarLister: containerTarLister(container: container, tarBin: tarBin),
    tarExtractor: containerTarExtractor(container: container, tarBin: tarBin),
  );
}

/// Port of `safe_extract_zip`/`safe_extract_tar`: lists every member of an
/// archive via the kind-appropriate lister, validates every single one
/// with [isPathTraversalSafe] against [destDir] *before* extracting
/// anything, and only extracts if the entire archive passes. Throws a
/// [StateError] naming the first unsafe member otherwise (mirroring
/// Python's `raise RuntimeError(f"Blocked unsafe {zip,tar} path: ...")`) —
/// this is intentionally an abort-the-archive failure, not a
/// continue-past-one-file case: an archive containing any path-traversal
/// member is fully untrusted, unlike a single corrupt media file inside an
/// otherwise-fine archive (see [processExtractedTree]'s per-media-file
/// handling for that distinction).
class TakeoutArchiveExtractor {
  TakeoutArchiveExtractor({
    ArchiveLister? zipLister,
    ArchiveExtractRunner? zipExtractor,
    ArchiveLister? tarLister,
    ArchiveExtractRunner? tarExtractor,
  }) : zipLister = zipLister ?? defaultZipLister(),
       zipExtractor = zipExtractor ?? defaultZipExtractor(),
       tarLister = tarLister ?? defaultTarLister(),
       tarExtractor = tarExtractor ?? defaultTarExtractor();

  final ArchiveLister zipLister;
  final ArchiveExtractRunner zipExtractor;
  final ArchiveLister tarLister;
  final ArchiveExtractRunner tarExtractor;

  Future<void> extract(
    String archivePath,
    String destDir,
    ArchiveKind kind,
  ) async {
    final lister = kind == ArchiveKind.zip ? zipLister : tarLister;
    final extractor = kind == ArchiveKind.zip ? zipExtractor : tarExtractor;

    final members = await lister(archivePath);
    for (final member in members) {
      if (!isPathTraversalSafe(destDir, member)) {
        throw StateError('Blocked unsafe archive path: $member');
      }
    }
    await extractor(archivePath, destDir);
  }
}

/// Port of `extract_archive`: prepares [destDir] (removing it first if it
/// already exists, then recreating it — mirroring
/// `if dest.exists(): shutil.rmtree(dest); dest.mkdir(parents=True, ...)`),
/// determines the archive kind from [archivePath]'s filename (throwing if
/// unsupported, mirroring `raise RuntimeError(f"Unsupported archive type:
/// ...")`), and delegates to [extractor].
Future<void> extractArchive(
  String archivePath,
  String destDir,
  TakeoutArchiveExtractor extractor,
) async {
  final fileName = archivePath.split('/').last;
  final kind = archiveKindFor(fileName);
  if (kind == null) {
    throw StateError('Unsupported archive type: $archivePath');
  }

  final destDirEntity = Directory(destDir);
  if (await destDirEntity.exists()) {
    await destDirEntity.delete(recursive: true);
  }
  await destDirEntity.create(recursive: true);

  await extractor.extract(archivePath, destDir, kind);
}

// ---------------------------------------------------------------------------
// move_to_staging.
// ---------------------------------------------------------------------------

/// Splits [fileName] into `(base, ext)` where `ext` includes the leading
/// `.`, mirroring `Path.with_suffix("")` + `Path.suffix`. A filename with
/// no `.` has an empty `ext` and `base == fileName`.
(String, String) _splitBaseAndSuffix(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return (fileName, '');
  return (fileName.substring(0, dot), fileName.substring(dot));
}

/// Port of `move_to_staging`: computes [media]'s path relative to
/// [extractedRoot] (falling back to just the filename if [media] isn't
/// actually under [extractedRoot], mirroring the `except ValueError: rel =
/// Path(media.name)` fallback), joins that onto [cleaningStaging], and — if
/// something already exists at that exact destination — appends a numbered
/// suffix (`_1`, `_2`, ...) until a free name is found (mirroring the
/// `while True` loop in Python). The actual move is delegated to
/// [SafeFileMover.moveNoClobber] (see this file's top-level doc comment on
/// why: byte-safety reuse, not behavioral inheritance of its skip-on-
/// collision semantics — by the time [SafeFileMover] is called here, the
/// destination name has already been chosen to not collide). Returns the
/// final destination path.
Future<String> moveToStaging(
  String media,
  String extractedRoot,
  String cleaningStaging, {
  SafeFileMover? mover,
}) async {
  final normalizedRoot =
      extractedRoot.endsWith('/') && extractedRoot.length > 1
      ? extractedRoot.substring(0, extractedRoot.length - 1)
      : extractedRoot;
  String rel;
  if (media == normalizedRoot) {
    rel = media.split('/').last;
  } else if (media.startsWith('$normalizedRoot/')) {
    rel = media.substring(normalizedRoot.length + 1);
  } else {
    rel = media.split('/').last;
  }

  final normalizedStaging =
      cleaningStaging.endsWith('/') && cleaningStaging.length > 1
      ? cleaningStaging.substring(0, cleaningStaging.length - 1)
      : cleaningStaging;
  var dest = '$normalizedStaging/$rel';

  if (await File(dest).exists() || await Directory(dest).exists()) {
    final (destParent, destName) = _splitParentAndName(dest);
    final (base, suffix) = _splitBaseAndSuffix(destName);
    var i = 1;
    while (true) {
      final candidate = '$destParent/${base}_$i$suffix';
      if (!await File(candidate).exists() &&
          !await Directory(candidate).exists()) {
        dest = candidate;
        break;
      }
      i++;
    }
  }

  final (destParent, _) = _splitParentAndName(dest);
  await Directory(destParent).create(recursive: true);

  final safeMover = mover ?? const SafeFileMover();
  await safeMover.moveNoClobber(media, dest);
  return dest;
}

// ---------------------------------------------------------------------------
// process_extracted_tree.
// ---------------------------------------------------------------------------

/// Summary counters for one call to [processExtractedTree], mirroring the
/// `(processed, warnings)` tuple Python's `process_extracted_tree` returns.
class ExtractedTreeSummary {
  const ExtractedTreeSummary({
    required this.processed,
    required this.warnings,
  });

  final int processed;
  final int warnings;
}

/// Port of `process_extracted_tree`: recursively finds every media file
/// under [extractedRoot] (sorted, matching `sorted([... for p in
/// extracted_root.rglob("*") if is_media_file(p)])`), and for each one:
///
/// - Looks up JSON sidecar candidates via [candidateJsonsForMedia].
/// - If any exist, tries [applyMetadataWithExiftool] against each in order
///   until one succeeds; if *none* succeed, logs a warning via [warn] but
///   still proceeds to move the file (mirroring "Media file had
///   sidecar(s), but metadata was not applied").
/// - If none exist at all, logs a different warning ("no matched/processed
///   JSON sidecar") and still moves the file unmodified.
/// - Either way, always calls [moveToStaging] — mirroring the Python hard
///   rule that a metadata failure or missing sidecar never blocks a file
///   from reaching `cleaning_staging`; only a genuine per-archive
///   *exception* (see [MetadataStitcher.run]'s per-archive try/catch) can
///   abort the run — a single corrupt/unmatched media file never does.
Future<ExtractedTreeSummary> processExtractedTree(
  String extractedRoot, {
  required String cleaningStaging,
  required ExiftoolRunner exiftool,
  required WarningLogger warn,
  SafeFileMover? mover,
}) async {
  final rootDir = Directory(extractedRoot);
  final mediaFiles = <String>[];
  if (await rootDir.exists()) {
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && isMediaExtension(entity.path)) {
        mediaFiles.add(entity.path);
      }
    }
  }
  mediaFiles.sort();

  var processed = 0;
  var warnings = 0;

  for (final media in mediaFiles) {
    final jsons = await candidateJsonsForMedia(media);
    if (jsons.isNotEmpty) {
      var ok = false;
      for (final js in jsons) {
        if (await applyMetadataWithExiftool(
          media,
          js,
          runner: exiftool,
          warn: warn,
        )) {
          ok = true;
          break;
        }
      }
      if (!ok) {
        warnings++;
        await warn(
          'Media file had sidecar(s), but metadata was not applied: $media',
        );
      }
    } else {
      warnings++;
      await warn(
        'Media file had no matched/processed JSON sidecar. '
        'Moving original file: $media',
      );
    }
    await moveToStaging(media, extractedRoot, cleaningStaging, mover: mover);
    processed++;
  }

  return ExtractedTreeSummary(processed: processed, warnings: warnings);
}

// ---------------------------------------------------------------------------
// merge_raw_gdrive.
// ---------------------------------------------------------------------------

/// Runs `rsync -a --ignore-existing <src>/ <dst>/`. The default
/// implementation ([rsyncRunner]) shells out to the real binary
/// (overridable, matching this file's other external-tool seams); tests
/// inject a fake to assert the call happened without needing real rsync
/// semantics.
typedef RsyncRunner = Future<void> Function(String src, String dst);

/// Builds the default [RsyncRunner]: shells out to [rsyncBin] (defaulting
/// to `rsync`).
RsyncRunner rsyncRunner({String rsyncBin = 'rsync'}) {
  return (String src, String dst) async {
    final result = await Process.run(rsyncBin, [
      '-a',
      '--ignore-existing',
      '$src/',
      '$dst/',
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) {
      throw StateError('rsync failed: ${result.stderr}');
    }
  };
}

/// Port of `merge_raw_gdrive`: if `$HD_PATH/raw_gdrive` doesn't exist,
/// no-op. If it exists but is empty, prints a skip message and no-ops. This
/// is the only step in the script that touches raw Google Drive media
/// (rather than Takeout archives), and it's additive-only
/// (`--ignore-existing` never overwrites anything already in
/// `cleaning_staging`).
Future<void> mergeRawGdrive(
  String hdPath, {
  required RsyncRunner rsync,
  void Function(String)? print,
}) async {
  final rawGdrive = rawGdrivePath(hdPath);
  final rawGdriveDir = Directory(rawGdrive);
  if (!await rawGdriveDir.exists()) return;

  final isEmpty = await rawGdriveDir.list().isEmpty;
  if (isEmpty) {
    print?.call('==> raw_gdrive is empty; skipping Google Drive merge');
    return;
  }

  final cleaningStaging = cleaningStagingPath(hdPath);
  print?.call(
    '==> Merging raw Google Drive media: $rawGdrive -> $cleaningStaging',
  );
  await Directory(cleaningStaging).create(recursive: true);
  await rsync(rawGdrive, cleaningStaging);
}

// ---------------------------------------------------------------------------
// Orchestration (main).
// ---------------------------------------------------------------------------

/// Totals for one full [MetadataStitcher.run] call, mirroring the
/// `total`/`warn` counters Python's `main()` accumulates and prints.
class StitchMetadataSummary {
  const StitchMetadataSummary({
    required this.archivesProcessed,
    required this.mediaMoved,
    required this.warnings,
  });

  final int archivesProcessed;
  final int mediaMoved;
  final int warnings;
}

/// Dart port of `04_stitch_metadata.py`'s `main()`: for every supported
/// archive found in `$HD_PATH/raw_takeout_zips` (sorted), extracts it,
/// processes its media tree (see [processExtractedTree]), deletes the
/// archive only after that succeeds (mirroring "Deletes an archive only
/// after extraction + staging completes for that archive"), and always
/// removes the extraction scratch directory afterward, success or failure
/// (mirroring the Python `finally: shutil.rmtree(dest, ignore_errors=True)`).
///
/// ## Hard safety rule: archive-level failures abort; per-media-file
/// failures never do
///
/// This mirrors the Python original exactly: if extraction or
/// [processExtractedTree] itself throws (e.g. a corrupt/unsafe archive),
/// the exception is logged as a warning ("Archive failed and was kept for
/// retry") and then *re-thrown*, stopping the whole run — the failing
/// archive is deliberately left in `raw_takeout_zips` for a retry, per the
/// module doc comment's safety model ("Deletes an archive only after
/// extraction + staging completes for that archive"). This is a different,
/// coarser safety tier than the per-*media-file* continuation
/// [processExtractedTree] already guarantees: one corrupt file inside an
/// otherwise-good archive never aborts anything (that's handled entirely
/// inside [processExtractedTree]/[applyMetadataWithExiftool] without ever
/// throwing), but a corrupt/unsafe *archive* is untrusted as a whole and
/// stops the run rather than silently skipping to the next one — exactly
/// matching production behavior.
class MetadataStitcher {
  /// [archiveExtractor] is *required* — the archive-extraction half of this
  /// port's #76 Phase 2 container migration (see this file's top-level
  /// "Design decision: all three external tools ... route through
  /// [ToolsContainer]" doc comment). Real callers should pass
  /// [containerTakeoutArchiveExtractor] (backed by an already-started
  /// [ToolsContainer]); tests pass a fake, or the host-shelling
  /// `TakeoutArchiveExtractor()` (its own no-argument constructor defaults
  /// to [defaultZipLister]/[defaultZipExtractor]/[defaultTarLister]/
  /// [defaultTarExtractor]) for a container-free decision-logic check.
  MetadataStitcher({
    ExiftoolRunner? exiftool,
    required this.archiveExtractor,
    RsyncRunner? rsync,
    SafeFileMover? mover,
  }) : exiftool = exiftool ?? exiftoolRunner(),
       rsync = rsync ?? rsyncRunner(),
       mover = mover ?? const SafeFileMover();

  final ExiftoolRunner exiftool;
  final TakeoutArchiveExtractor archiveExtractor;
  final RsyncRunner rsync;
  final SafeFileMover mover;

  /// Runs the full pipeline against [hdPath], mirroring `main()`.
  /// [print] receives the same `==> ...` progress lines the Python script
  /// prints to stdout (optional — tests can omit it).
  Future<StitchMetadataSummary> run(
    String hdPath, {
    void Function(String)? print,
  }) async {
    final rawTakeoutZips = rawTakeoutZipsPath(hdPath);
    final takeoutExtracted = takeoutExtractedPath(hdPath);
    final cleaningStaging = cleaningStagingPath(hdPath);

    for (final dir in [rawTakeoutZips, takeoutExtracted, cleaningStaging]) {
      await Directory(dir).create(recursive: true);
    }

    final warningLog = File(stitchWarningLogPath(hdPath));
    await warningLog.parent.create(recursive: true);
    await warningLog.writeAsString('# Metadata stitching warnings\n\n');
    final warn = fileWarningLogger(hdPath);

    final archives = await _supportedArchives(rawTakeoutZips);
    if (archives.isEmpty) {
      print?.call('==> No supported archives found in $rawTakeoutZips');
    } else {
      print?.call('==> Processing ${archives.length} archive(s)');
    }

    var total = 0;
    var totalWarnings = 0;

    for (final archive in archives) {
      final fileName = archive.split('/').last;
      final dest = '$takeoutExtracted/${archiveStem(fileName)}';
      try {
        print?.call('==> Extracting $fileName -> $dest');
        await extractArchive(archive, dest, archiveExtractor);
        final summary = await processExtractedTree(
          dest,
          cleaningStaging: cleaningStaging,
          exiftool: exiftool,
          warn: warn,
          mover: mover,
        );
        total += summary.processed;
        totalWarnings += summary.warnings;
        print?.call(
          '==> Archive complete: $fileName; media moved: '
          '${summary.processed}; warnings: ${summary.warnings}',
        );
        await File(archive).delete();
        print?.call('==> Deleted processed archive: $archive');
      } catch (exc) {
        await warn('Archive failed and was kept for retry: $archive: $exc');
        rethrow;
      } finally {
        final destDir = Directory(dest);
        if (await destDir.exists()) {
          try {
            await destDir.delete(recursive: true);
          } catch (_) {
            // Mirrors `shutil.rmtree(dest, ignore_errors=True)`.
          }
        }
      }
    }

    await mergeRawGdrive(hdPath, rsync: rsync, print: print);
    print?.call(
      '==> Metadata stitching complete. Media moved from Takeout: '
      '$total; warnings: $totalWarnings',
    );
    print?.call('==> Staging folder: $cleaningStaging');
    print?.call('==> Warning log: ${stitchWarningLogPath(hdPath)}');

    return StitchMetadataSummary(
      archivesProcessed: archives.length,
      mediaMoved: total,
      warnings: totalWarnings,
    );
  }

  /// Port of `supported_archives`: lists `$rawTakeoutZips` (non-recursive)
  /// for files matching [isSupportedArchiveFileName], de-duplicated and
  /// sorted (mirroring `sorted(set(found))`).
  Future<List<String>> _supportedArchives(String rawTakeoutZips) async {
    final dir = Directory(rawTakeoutZips);
    if (!await dir.exists()) return const [];
    final found = <String>{};
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File &&
          isSupportedArchiveFileName(entity.path.split('/').last)) {
        found.add(entity.path);
      }
    }
    final sorted = found.toList()..sort();
    return sorted;
  }
}

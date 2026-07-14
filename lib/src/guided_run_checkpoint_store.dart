import 'dart:convert';
import 'dart:io';

/// How long a persisted guided-run checkpoint is trusted before it's treated
/// as stale and ignored on restore. A guided run left mid-chain for longer
/// than this is more likely to reflect a machine/session the user has moved
/// on from (different drive plugged in, different day's cleanup) than an
/// interrupted continuation of the same run — so restoring it uncritically
/// risks silently resuming against out-of-date on-disk state. Simple,
/// explainable cutoff rather than trying to fingerprint script output.
const Duration guidedRunCheckpointMaxAge = Duration(days: 7);

/// A persisted snapshot of "how far the guided run got" so a restart can
/// restore [segmentIndex] instead of silently starting over from segment 0
/// (issue #51, item 1).
///
/// Deliberately small and explainable, following the same "non-secret local
/// app state" precedent as `ImmichChecklistStore`: no command output, no
/// file paths beyond the already-user-entered [hdPath]/[reportDir] settings
/// (same category of data `PipelineSettings` itself already holds), just
/// enough to know *where* the guided run had gotten to and whether that's
/// still trustworthy.
class GuidedRunCheckpoint {
  const GuidedRunCheckpoint({
    required this.segmentIndex,
    required this.hdPath,
    required this.reportDir,
    required this.updatedAt,
  });

  factory GuidedRunCheckpoint.fromJson(Map<String, Object?> json) {
    return GuidedRunCheckpoint(
      segmentIndex: _intValue(json['segmentIndex']) ?? 0,
      hdPath: _stringValue(json['hdPath']) ?? '',
      reportDir: _stringValue(json['reportDir']) ?? '',
      updatedAt:
          DateTime.tryParse(_stringValue(json['updatedAt']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Which guided-run segment index is next to run. Mirrors
  /// `_guidedSegmentIndex` in `media_pipeline_app.dart` — `0` means the
  /// guided run has not made progress yet (equivalent to no checkpoint).
  final int segmentIndex;

  /// The `PipelineSettings.hdPath` / `.reportDir` in effect when this
  /// checkpoint was recorded. Restoring only makes sense if the app is
  /// still pointed at the same target drive/report location — resuming a
  /// stale segment index against a since-changed path could skip steps a
  /// new target never actually ran.
  final String hdPath;
  final String reportDir;

  /// When this checkpoint was last written. Used with
  /// [guidedRunCheckpointMaxAge] to decide staleness.
  final DateTime updatedAt;

  /// Whether this checkpoint is too old, or points at a different
  /// hdPath/reportDir than the app's current settings, to trust as a
  /// continuation of "the same guided run" rather than a stale leftover.
  bool isStale({
    required String currentHdPath,
    required String currentReportDir,
    DateTime? now,
  }) {
    if (hdPath != currentHdPath || reportDir != currentReportDir) {
      return true;
    }
    final effectiveNow = now ?? DateTime.now();
    return effectiveNow.difference(updatedAt) > guidedRunCheckpointMaxAge;
  }

  Map<String, Object?> toJson() {
    return {
      'segmentIndex': segmentIndex,
      'hdPath': hdPath,
      'reportDir': reportDir,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}

/// Persists a single [GuidedRunCheckpoint] to a local JSON file, following
/// the exact same "non-secret local app state" pattern as
/// `ImmichChecklistStore` (`immich_phone_checklist_store.dart`): a small
/// JSON file under the platform's local app-data directory, no secrets, no
/// destructive side effects — reading/writing this file can never trigger a
/// pipeline step or touch media.
class GuidedRunCheckpointStore {
  GuidedRunCheckpointStore({Directory? baseDirectory})
    : _baseDirectory = baseDirectory ?? _defaultBaseDirectory();

  final Directory _baseDirectory;

  File get file => File(
    '${_baseDirectory.path}${Platform.pathSeparator}guided_run_checkpoint.json',
  );

  String get filePath => file.path;

  Future<GuidedRunCheckpoint?> load() async {
    if (!await file.exists()) {
      return null;
    }

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException(
        'Guided run checkpoint store must contain a JSON object.',
      );
    }

    final checkpoint = decoded['checkpoint'];
    if (checkpoint is! Map) {
      return null;
    }
    return GuidedRunCheckpoint.fromJson(checkpoint.cast<String, Object?>());
  }

  Future<void> save(GuidedRunCheckpoint checkpoint) async {
    await _baseDirectory.create(recursive: true);
    final payload = <String, Object?>{
      'version': 1,
      'checkpoint': checkpoint.toJson(),
    };
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload));
  }

  /// Removes any persisted checkpoint. Called once the guided run either
  /// finishes entirely or has no in-progress segment left to resume, so a
  /// later restart doesn't have anything stale to restore.
  Future<void> clear() async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}

Directory _defaultBaseDirectory() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  if (Platform.isWindows) {
    final roaming = Platform.environment['APPDATA'];
    if (roaming != null && roaming.trim().isNotEmpty) {
      return Directory(
        '${roaming.trim()}${Platform.pathSeparator}media_pipeline',
      );
    }
    return Directory(
      '$home${Platform.pathSeparator}AppData${Platform.pathSeparator}Roaming${Platform.pathSeparator}media_pipeline',
    );
  }

  if (Platform.isMacOS) {
    return Directory(
      '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support${Platform.pathSeparator}media_pipeline',
    );
  }

  final xdgConfigHome = Platform.environment['XDG_CONFIG_HOME'];
  if (xdgConfigHome != null && xdgConfigHome.trim().isNotEmpty) {
    return Directory(
      '${xdgConfigHome.trim()}${Platform.pathSeparator}media_pipeline',
    );
  }

  return Directory(
    '$home${Platform.pathSeparator}.config${Platform.pathSeparator}media_pipeline',
  );
}

String? _stringValue(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

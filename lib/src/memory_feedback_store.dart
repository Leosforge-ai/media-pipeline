import 'dart:convert';
import 'dart:io';

import 'memory_feedback.dart';

class MemoryFeedbackStore {
  MemoryFeedbackStore({Directory? baseDirectory})
    : _baseDirectory = baseDirectory ?? _defaultBaseDirectory();

  final Directory _baseDirectory;

  File get file => File(
    '${_baseDirectory.path}${Platform.pathSeparator}memory_feedback_events.json',
  );

  String get filePath => file.path;

  Future<List<MemoryFeedbackEvent>> load() async {
    if (!await file.exists()) {
      return const [];
    }

    final content = await file.readAsString();
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return const [];
    }

    if (decoded is! Map) {
      return const [];
    }

    final items = decoded['events'];
    if (items is! List) {
      return const [];
    }

    final events = <MemoryFeedbackEvent>[];
    for (final item in items) {
      if (item is Map) {
        events.add(
          MemoryFeedbackEvent.fromJson(item.cast<String, Object?>()),
        );
      }
    }
    return events;
  }

  Future<void> save(List<MemoryFeedbackEvent> events) async {
    await _baseDirectory.create(recursive: true);
    final payload = <String, Object?>{
      'version': 1,
      'events': events.map((item) => item.toJson()).toList(),
    };
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload));
  }
}

Directory _defaultBaseDirectory() {
  final home = _homeDirectoryOrThrow();
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

String _homeDirectoryOrThrow() {
  final home = Platform.environment['HOME'];
  if (home != null && home.trim().isNotEmpty) {
    return home.trim();
  }

  final userProfile = Platform.environment['USERPROFILE'];
  if (userProfile != null && userProfile.trim().isNotEmpty) {
    return userProfile.trim();
  }

  throw StateError(
    'MemoryFeedbackStore requires HOME or USERPROFILE to locate the app data directory.',
  );
}

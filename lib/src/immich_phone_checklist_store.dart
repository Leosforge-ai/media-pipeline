import 'dart:convert';
import 'dart:io';

class ImmichPhoneBackupChecklist {
  const ImmichPhoneBackupChecklist({
    required this.id,
    required this.phoneName,
    required this.appInstalled,
    required this.serverLoginConfirmed,
    required this.albumsSelected,
    required this.backupEnabled,
    required this.firstUploadObserved,
    required this.backgroundPermissionsReviewed,
  });

  factory ImmichPhoneBackupChecklist.empty({required String id}) {
    return ImmichPhoneBackupChecklist(
      id: id,
      phoneName: '',
      appInstalled: false,
      serverLoginConfirmed: false,
      albumsSelected: false,
      backupEnabled: false,
      firstUploadObserved: false,
      backgroundPermissionsReviewed: false,
    );
  }

  factory ImmichPhoneBackupChecklist.fromJson(Map<String, Object?> json) {
    return ImmichPhoneBackupChecklist(
      id: _stringValue(json['id']) ?? _newChecklistId(),
      phoneName: _stringValue(json['phoneName']) ?? '',
      appInstalled: _boolValue(json['appInstalled']),
      serverLoginConfirmed: _boolValue(json['serverLoginConfirmed']),
      albumsSelected: _boolValue(json['albumsSelected']),
      backupEnabled: _boolValue(json['backupEnabled']),
      firstUploadObserved: _boolValue(json['firstUploadObserved']),
      backgroundPermissionsReviewed: _boolValue(
        json['backgroundPermissionsReviewed'],
      ),
    );
  }

  final String id;
  final String phoneName;
  final bool appInstalled;
  final bool serverLoginConfirmed;
  final bool albumsSelected;
  final bool backupEnabled;
  final bool firstUploadObserved;
  final bool backgroundPermissionsReviewed;

  ImmichPhoneBackupChecklist copyWith({
    String? id,
    String? phoneName,
    bool? appInstalled,
    bool? serverLoginConfirmed,
    bool? albumsSelected,
    bool? backupEnabled,
    bool? firstUploadObserved,
    bool? backgroundPermissionsReviewed,
  }) {
    return ImmichPhoneBackupChecklist(
      id: id ?? this.id,
      phoneName: phoneName ?? this.phoneName,
      appInstalled: appInstalled ?? this.appInstalled,
      serverLoginConfirmed: serverLoginConfirmed ?? this.serverLoginConfirmed,
      albumsSelected: albumsSelected ?? this.albumsSelected,
      backupEnabled: backupEnabled ?? this.backupEnabled,
      firstUploadObserved: firstUploadObserved ?? this.firstUploadObserved,
      backgroundPermissionsReviewed:
          backgroundPermissionsReviewed ?? this.backgroundPermissionsReviewed,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'phoneName': phoneName,
      'appInstalled': appInstalled,
      'serverLoginConfirmed': serverLoginConfirmed,
      'albumsSelected': albumsSelected,
      'backupEnabled': backupEnabled,
      'firstUploadObserved': firstUploadObserved,
      'backgroundPermissionsReviewed': backgroundPermissionsReviewed,
    };
  }
}

class ImmichChecklistStore {
  ImmichChecklistStore({Directory? baseDirectory})
    : _baseDirectory = baseDirectory ?? _defaultBaseDirectory();

  final Directory _baseDirectory;

  File get file => File(
    '${_baseDirectory.path}${Platform.pathSeparator}immich_phone_checklists.json',
  );

  String get filePath => file.path;

  Future<List<ImmichPhoneBackupChecklist>> load() async {
    if (!await file.exists()) {
      return const [];
    }

    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException(
        'Checklist store must contain a JSON object.',
      );
    }

    final items = decoded['checklists'];
    if (items is! List) {
      return const [];
    }

    final checklists = <ImmichPhoneBackupChecklist>[];
    for (final item in items) {
      if (item is Map) {
        checklists.add(
          ImmichPhoneBackupChecklist.fromJson(item.cast<String, Object?>()),
        );
      }
    }
    return checklists;
  }

  Future<void> save(List<ImmichPhoneBackupChecklist> checklists) async {
    await _baseDirectory.create(recursive: true);
    final payload = <String, Object?>{
      'version': 1,
      'checklists': checklists.map((item) => item.toJson()).toList(),
    };
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload));
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

bool _boolValue(Object? value) => value is bool ? value : false;

int checklistProgressCompleteCount(ImmichPhoneBackupChecklist checklist) {
  return [
    checklist.appInstalled,
    checklist.serverLoginConfirmed,
    checklist.albumsSelected,
    checklist.backupEnabled,
    checklist.firstUploadObserved,
    checklist.backgroundPermissionsReviewed,
  ].where((checked) => checked).length;
}

const int checklistProgressTotalCount = 6;

String _newChecklistId() {
  return DateTime.now().microsecondsSinceEpoch.toString();
}

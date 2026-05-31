import 'memory_curator.dart';

enum MemoryFeedbackEventType {
  opened,
  ignored,
  hidden,
  favorited,
  shared,
  unknown,
}

extension MemoryFeedbackEventTypeLabel on MemoryFeedbackEventType {
  String get label => switch (this) {
    MemoryFeedbackEventType.opened => 'Opened',
    MemoryFeedbackEventType.ignored => 'Ignored',
    MemoryFeedbackEventType.hidden => 'Hidden',
    MemoryFeedbackEventType.favorited => 'Favorited',
    MemoryFeedbackEventType.shared => 'Shared',
    MemoryFeedbackEventType.unknown => 'Unknown',
  };
}

class MemoryFeedbackEvent {
  MemoryFeedbackEvent({
    required this.candidateTitle,
    required List<String> assetIds,
    required this.type,
    required this.recordedAt,
    this.reason,
    this.rulesetVersion = 'rules-v1',
  }) : assetIds = List.unmodifiable(assetIds);

  factory MemoryFeedbackEvent.fromJson(Map<String, Object?> json) {
    final assetIds = json['assetIds'];
    return MemoryFeedbackEvent(
      candidateTitle: _stringValue(json['candidateTitle']) ?? '',
      assetIds: assetIds is List
          ? [
              for (final value in assetIds)
                if (value is String && value.trim().isNotEmpty) value.trim(),
            ]
          : const [],
      type: _feedbackEventTypeValue(json['type']),
      recordedAt: DateTime.tryParse(
            _stringValue(json['recordedAt']) ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      reason: _stringValue(json['reason']),
      rulesetVersion: _stringValue(json['rulesetVersion']) ?? 'rules-v1',
    );
  }

  final String candidateTitle;
  final List<String> assetIds;
  final MemoryFeedbackEventType type;
  final DateTime recordedAt;
  final String? reason;
  final String rulesetVersion;

  Map<String, Object?> toJson() {
    return {
      'candidateTitle': candidateTitle,
      'assetIds': assetIds,
      'type': type.name,
      'recordedAt': recordedAt.toIso8601String(),
      'reason': reason,
      'rulesetVersion': rulesetVersion,
    };
  }
}

int memoryFeedbackScoreAdjustment({
  required MemoryPreviewCandidate candidate,
  required Iterable<MemoryFeedbackEvent> events,
}) {
  var adjustment = 0;
  final candidateAssetIds = candidate.assetIds.toSet();

  for (final event in events) {
    final hasMatchingAsset = event.assetIds.any(candidateAssetIds.contains);
    if (!hasMatchingAsset) {
      continue;
    }

    adjustment += switch (event.type) {
      MemoryFeedbackEventType.opened => 1,
      MemoryFeedbackEventType.ignored => -2,
      MemoryFeedbackEventType.hidden => -4,
      MemoryFeedbackEventType.favorited => 5,
      MemoryFeedbackEventType.shared => 4,
      MemoryFeedbackEventType.unknown => 0,
    };
  }

  return adjustment;
}

MemoryFeedbackEventType _feedbackEventTypeValue(Object? value) {
  final raw = _stringValue(value);
  return switch (raw) {
    'opened' => MemoryFeedbackEventType.opened,
    'ignored' => MemoryFeedbackEventType.ignored,
    'hidden' => MemoryFeedbackEventType.hidden,
    'favorited' => MemoryFeedbackEventType.favorited,
    'shared' => MemoryFeedbackEventType.shared,
    _ => MemoryFeedbackEventType.unknown,
  };
}

String? _stringValue(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

import 'memory_curator.dart';

enum MemoryFeedbackEventType { opened, ignored, hidden, favorited, shared }

extension MemoryFeedbackEventTypeLabel on MemoryFeedbackEventType {
  String get label => switch (this) {
    MemoryFeedbackEventType.opened => 'Opened',
    MemoryFeedbackEventType.ignored => 'Ignored',
    MemoryFeedbackEventType.hidden => 'Hidden',
    MemoryFeedbackEventType.favorited => 'Favorited',
    MemoryFeedbackEventType.shared => 'Shared',
  };
}

class MemoryFeedbackEvent {
  const MemoryFeedbackEvent({
    required this.candidateTitle,
    required this.assetIds,
    required this.type,
    required this.recordedAt,
    this.reason,
    this.rulesetVersion = 'rules-v1',
  });

  final String candidateTitle;
  final List<String> assetIds;
  final MemoryFeedbackEventType type;
  final DateTime recordedAt;
  final String? reason;
  final String rulesetVersion;
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
    };
  }

  return adjustment;
}

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

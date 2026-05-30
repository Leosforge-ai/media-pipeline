import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/memory_feedback.dart';

void main() {
  test('labels and records local ranking feedback events', () {
    final event = MemoryFeedbackEvent(
      candidateTitle: 'Album: Lisbon Week',
      assetIds: ['live-1', 'live-2'],
      type: MemoryFeedbackEventType.favorited,
      recordedAt: DateTime(2026, 5, 30, 12, 0, 0),
    );

    expect(MemoryFeedbackEventType.favorited.label, 'Favorited');
    expect(event.rulesetVersion, 'rules-v1');
    expect(event.candidateTitle, 'Album: Lisbon Week');
    expect(event.assetIds, ['live-1', 'live-2']);
  });
}

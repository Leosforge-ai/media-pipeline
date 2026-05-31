import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/memory_feedback.dart';
import 'package:media_pipeline_app/src/memory_feedback_store.dart';

void main() {
  test('saves and loads local ranking feedback events without secrets', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'memory-feedback-store-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = MemoryFeedbackStore(baseDirectory: tempRoot);
    final events = [
      MemoryFeedbackEvent(
        candidateTitle: 'Album: Lisbon Week',
        assetIds: ['live-1', 'live-2'],
        type: MemoryFeedbackEventType.favorited,
        recordedAt: DateTime(2026, 5, 31, 12, 0, 0),
        reason: 'Best memory from the trip',
      ),
      MemoryFeedbackEvent(
        candidateTitle: 'Place: Lisbon',
        assetIds: ['live-3'],
        type: MemoryFeedbackEventType.hidden,
        recordedAt: DateTime(2026, 5, 31, 12, 5, 0),
      ),
    ];

    await store.save(events);

    expect(await File(store.filePath).exists(), isTrue);
    expect(await File(store.filePath).readAsString(), isNot(contains('apiKey')));

    final loaded = await store.load();
    expect(loaded, hasLength(2));
    expect(loaded.first.candidateTitle, 'Album: Lisbon Week');
    expect(loaded.first.assetIds, ['live-1', 'live-2']);
    expect(loaded.first.type, MemoryFeedbackEventType.favorited);
    expect(loaded.first.reason, 'Best memory from the trip');
    expect(loaded.first.rulesetVersion, 'rules-v1');
    expect(loaded.last.candidateTitle, 'Place: Lisbon');
    expect(loaded.last.assetIds, ['live-3']);
    expect(loaded.last.type, MemoryFeedbackEventType.hidden);
  });

  test('returns an empty list when the feedback store file is missing', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'memory-feedback-missing-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = MemoryFeedbackStore(baseDirectory: tempRoot);
    final loaded = await store.load();

    expect(loaded, isEmpty);
  });

  test('returns an empty list when the feedback store file is corrupted', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'memory-feedback-corrupt-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = MemoryFeedbackStore(baseDirectory: tempRoot);
    await File(store.filePath).create(recursive: true);
    await File(store.filePath).writeAsString('{not valid json');

    final loaded = await store.load();

    expect(loaded, isEmpty);
  });
}

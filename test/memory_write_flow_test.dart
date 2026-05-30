import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/memory_curator.dart';
import 'package:media_pipeline_app/src/memory_write_flow.dart';

void main() {
  test('creates a pending memory write draft with an idempotency token', () {
    final draft = createPendingMemoryWriteDraft(
      candidate: const MemoryPreviewCandidate(
        title: 'Album: Lisbon Week',
        assetIds: ['live-1', 'live-2'],
        score: 30,
        reasons: ['Album membership suggests an event'],
      ),
      createdAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
    );

    expect(draft.state, MemoryWriteDraftState.pending);
    expect(draft.candidateTitle, 'Album: Lisbon Week');
    expect(draft.assetIds, ['live-1', 'live-2']);
    expect(draft.remoteMemoryId, isNull);
    expect(draft.committedAt, isNull);
    expect(draft.idempotencyToken, isNotEmpty);
    expect(draft.idempotencyToken, contains('Album-Lisbon-Week'));
  });

  test('commits a pending draft without changing its candidate metadata', () {
    final pending = createPendingMemoryWriteDraft(
      candidate: const MemoryPreviewCandidate(
        title: 'Place: Lisbon',
        assetIds: ['live-1', 'live-2', 'live-3'],
        score: 25,
        reasons: ['Location cluster'],
      ),
      createdAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
    );

    final committed = commitMemoryWriteDraft(
      draft: pending,
      remoteMemoryId: 'memory-123',
      committedAt: DateTime.utc(2026, 5, 30, 12, 5, 0),
    );

    expect(committed.state, MemoryWriteDraftState.committed);
    expect(committed.remoteMemoryId, 'memory-123');
    expect(committed.committedAt, DateTime.utc(2026, 5, 30, 12, 5, 0));
    expect(committed.assetIds, pending.assetIds);
    expect(committed.idempotencyToken, pending.idempotencyToken);
  });
}

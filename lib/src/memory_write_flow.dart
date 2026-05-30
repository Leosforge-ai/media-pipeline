import 'memory_curator.dart';

enum MemoryWriteDraftState { pending, committed }

class MemoryWriteDraft {
  const MemoryWriteDraft({
    required this.id,
    required this.candidateTitle,
    required this.assetIds,
    required this.state,
    required this.idempotencyToken,
    required this.createdAt,
    this.remoteMemoryId,
    this.committedAt,
  });

  final String id;
  final String candidateTitle;
  final List<String> assetIds;
  final MemoryWriteDraftState state;
  final String idempotencyToken;
  final DateTime createdAt;
  final String? remoteMemoryId;
  final DateTime? committedAt;

  MemoryWriteDraft copyWith({
    String? id,
    String? candidateTitle,
    List<String>? assetIds,
    MemoryWriteDraftState? state,
    String? idempotencyToken,
    DateTime? createdAt,
    String? remoteMemoryId,
    DateTime? committedAt,
  }) {
    return MemoryWriteDraft(
      id: id ?? this.id,
      candidateTitle: candidateTitle ?? this.candidateTitle,
      assetIds: assetIds ?? this.assetIds,
      state: state ?? this.state,
      idempotencyToken: idempotencyToken ?? this.idempotencyToken,
      createdAt: createdAt ?? this.createdAt,
      remoteMemoryId: remoteMemoryId ?? this.remoteMemoryId,
      committedAt: committedAt ?? this.committedAt,
    );
  }
}

const String memoryWriteApprovalPhrase = 'APPROVE MEMORY WRITE';

MemoryWriteDraft createPendingMemoryWriteDraft({
  required MemoryPreviewCandidate candidate,
  required DateTime createdAt,
}) {
  final assetIds = [...candidate.assetIds]..sort();
  final candidateTokenSource = [
    candidate.title.trim(),
    ...assetIds,
  ].where((value) => value.trim().isNotEmpty).join('-');
  final token = candidateTokenSource
      .replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return MemoryWriteDraft(
    id: 'draft-${createdAt.microsecondsSinceEpoch}',
    candidateTitle: candidate.title,
    assetIds: assetIds,
    state: MemoryWriteDraftState.pending,
    idempotencyToken: token.isEmpty
        ? 'draft-${createdAt.microsecondsSinceEpoch}'
        : token,
    createdAt: createdAt,
  );
}

MemoryWriteDraft commitMemoryWriteDraft({
  required MemoryWriteDraft draft,
  required String remoteMemoryId,
  required DateTime committedAt,
}) {
  return draft.copyWith(
    state: MemoryWriteDraftState.committed,
    remoteMemoryId: remoteMemoryId,
    committedAt: committedAt,
  );
}

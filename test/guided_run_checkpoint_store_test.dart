import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/guided_run_checkpoint_store.dart';

void main() {
  test('saves and loads a guided run checkpoint', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'guided-run-checkpoint-store-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = GuidedRunCheckpointStore(baseDirectory: tempRoot);
    final checkpoint = GuidedRunCheckpoint(
      segmentIndex: 1,
      hdPath: '/mnt/target_drive',
      reportDir: '/home/user/czkawka_reports',
      updatedAt: DateTime.utc(2026, 1, 1, 12),
    );

    await store.save(checkpoint);

    expect(await File(store.filePath).exists(), isTrue);

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.segmentIndex, 1);
    expect(loaded.hdPath, '/mnt/target_drive');
    expect(loaded.reportDir, '/home/user/czkawka_reports');
    expect(loaded.updatedAt, DateTime.utc(2026, 1, 1, 12));
  });

  test('returns null when no checkpoint file exists', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'guided-run-checkpoint-missing-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = GuidedRunCheckpointStore(baseDirectory: tempRoot);
    expect(await store.load(), isNull);
  });

  test('clear removes a persisted checkpoint', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'guided-run-checkpoint-clear-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = GuidedRunCheckpointStore(baseDirectory: tempRoot);
    await store.save(
      GuidedRunCheckpoint(
        segmentIndex: 1,
        hdPath: '/mnt/target_drive',
        reportDir: '/home/user/czkawka_reports',
        updatedAt: DateTime.now(),
      ),
    );

    expect(await store.load(), isNotNull);

    await store.clear();

    expect(await store.load(), isNull);
    expect(await File(store.filePath).exists(), isFalse);
  });

  group('GuidedRunCheckpoint.isStale', () {
    test('is not stale when settings match and age is within the cutoff', () {
      final checkpoint = GuidedRunCheckpoint(
        segmentIndex: 1,
        hdPath: '/mnt/target_drive',
        reportDir: '/home/user/czkawka_reports',
        updatedAt: DateTime(2026, 1, 1),
      );

      expect(
        checkpoint.isStale(
          currentHdPath: '/mnt/target_drive',
          currentReportDir: '/home/user/czkawka_reports',
          now: DateTime(2026, 1, 2),
        ),
        isFalse,
      );
    });

    test('is stale once older than guidedRunCheckpointMaxAge', () {
      final checkpoint = GuidedRunCheckpoint(
        segmentIndex: 1,
        hdPath: '/mnt/target_drive',
        reportDir: '/home/user/czkawka_reports',
        updatedAt: DateTime(2026, 1, 1),
      );

      final justUnderCutoff = DateTime(
        2026,
        1,
        1,
      ).add(guidedRunCheckpointMaxAge - const Duration(minutes: 1));
      final justOverCutoff = DateTime(
        2026,
        1,
        1,
      ).add(guidedRunCheckpointMaxAge + const Duration(minutes: 1));

      expect(
        checkpoint.isStale(
          currentHdPath: '/mnt/target_drive',
          currentReportDir: '/home/user/czkawka_reports',
          now: justUnderCutoff,
        ),
        isFalse,
      );
      expect(
        checkpoint.isStale(
          currentHdPath: '/mnt/target_drive',
          currentReportDir: '/home/user/czkawka_reports',
          now: justOverCutoff,
        ),
        isTrue,
      );
    });

    test('is stale when the hdPath or reportDir no longer match', () {
      final checkpoint = GuidedRunCheckpoint(
        segmentIndex: 1,
        hdPath: '/mnt/target_drive',
        reportDir: '/home/user/czkawka_reports',
        updatedAt: DateTime.now(),
      );

      expect(
        checkpoint.isStale(
          currentHdPath: '/mnt/other_drive',
          currentReportDir: '/home/user/czkawka_reports',
        ),
        isTrue,
      );
      expect(
        checkpoint.isStale(
          currentHdPath: '/mnt/target_drive',
          currentReportDir: '/home/user/other_reports',
        ),
        isTrue,
      );
    });
  });
}

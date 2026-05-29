import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/immich_phone_checklist_store.dart';

void main() {
  test('saves and loads checklist state without secrets', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'immich-checklist-store-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = ImmichChecklistStore(baseDirectory: tempRoot);
    final checklists = [
      ImmichPhoneBackupChecklist(
        id: 'phone-1',
        phoneName: 'Alex iPhone',
        appInstalled: true,
        serverLoginConfirmed: true,
        albumsSelected: true,
        backupEnabled: true,
        firstUploadObserved: false,
        backgroundPermissionsReviewed: true,
      ),
    ];

    await store.save(checklists);

    expect(await File(store.filePath).exists(), isTrue);
    expect(
      await File(store.filePath).readAsString(),
      isNot(contains('apiKey')),
    );

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'phone-1');
    expect(loaded.single.phoneName, 'Alex iPhone');
    expect(loaded.single.appInstalled, isTrue);
    expect(loaded.single.serverLoginConfirmed, isTrue);
    expect(loaded.single.albumsSelected, isTrue);
    expect(loaded.single.backupEnabled, isTrue);
    expect(loaded.single.firstUploadObserved, isFalse);
    expect(loaded.single.backgroundPermissionsReviewed, isTrue);
  });

  test('returns an empty list when the store file is missing', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'immich-checklist-missing-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final store = ImmichChecklistStore(baseDirectory: tempRoot);
    final loaded = await store.load();

    expect(loaded, isEmpty);
  });
}

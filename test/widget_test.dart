import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/immich_phone_checklist_store.dart';
import 'package:media_pipeline_app/src/immich_connection.dart';
import 'package:media_pipeline_app/src/media_pipeline_app.dart';
import 'package:media_pipeline_app/src/memory_curator.dart';
import 'package:media_pipeline_app/src/memory_write_flow.dart';

void main() {
  testWidgets('renders the desktop shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MediaPipelineApp());

    expect(find.text('Media Pipeline'), findsOneWidget);
    expect(find.text('System Check'), findsWidgets);
  });

  testWidgets('shows Immich help section', (WidgetTester tester) async {
    await tester.pumpWidget(const MediaPipelineApp());

    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();

    expect(find.text('Immich Help'), findsOneWidget);
    expect(find.text('Phone Backup'), findsOneWidget);
    expect(find.text('Private Docker Server'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Backup Troubleshooting'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Backup Troubleshooting'), findsOneWidget);
    expect(
      find.textContaining('If the server URL is wrong'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'If uploads stall, keep the app foregrounded and confirm the first upload starts before relying on background sync.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'On Android, disable battery optimization and review manufacturer-specific background restrictions for Immich.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'On iPhone, avoid Low Power Mode and keep Background App Refresh enabled for Immich.',
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Takeout Duplicates'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Takeout Duplicates'), findsOneWidget);
  });

  testWidgets('shows Immich connection section', (WidgetTester tester) async {
    await tester.pumpWidget(
      MediaPipelineApp(immichClient: _FakeImmichClient.success()),
    );

    await tester.tap(find.text('Immich'));
    await tester.pumpAndSettle();

    expect(find.text('Immich Connection'), findsOneWidget);
    expect(find.text('Immich server URL'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Check Connection'), findsOneWidget);

    await tester.tap(find.text('Check Connection'));
    await tester.pumpAndSettle();

    expect(find.text('Server reachable; API key verified'), findsOneWidget);
    expect(find.text('Immich Server Statistics'), findsOneWidget);
    expect(find.text('Server version: 1.140.0'), findsOneWidget);
    expect(find.text('Photos: 12'), findsOneWidget);
    expect(find.text('Videos: 3'), findsOneWidget);
    expect(find.text('Storage usage: 1.0 KB'), findsOneWidget);
  });

  testWidgets('shows unavailable Immich statistics gracefully', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MediaPipelineApp(immichClient: _FakeImmichClient.missingStatistics()),
    );

    await tester.tap(find.text('Immich'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check Connection'));
    await tester.pumpAndSettle();

    expect(find.text('Server reachable; API key verified'), findsOneWidget);
    expect(find.text('Immich Server Statistics'), findsOneWidget);
    expect(find.text('Server version: 1.140.0'), findsOneWidget);
    expect(find.text('Photos: unavailable'), findsOneWidget);
    expect(find.text('Videos: unavailable'), findsOneWidget);
    expect(find.text('Storage usage: unavailable'), findsOneWidget);
  });

  testWidgets('shows Immich connection errors', (WidgetTester tester) async {
    await tester.pumpWidget(
      MediaPipelineApp(
        immichClient: _FakeImmichClient.failure(
          ImmichConnectionIssue.serverUnavailable,
          'Immich server is not reachable: Connection refused',
        ),
      ),
    );

    await tester.tap(find.text('Immich'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check Connection'));
    await tester.pumpAndSettle();

    expect(find.text('Server unreachable'), findsOneWidget);
    expect(
      find.text('Immich server is not reachable: Connection refused'),
      findsOneWidget,
    );
  });

  testWidgets('shows the phone backup checklist controls', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaPipelineApp(
        immichClient: _FakeImmichClient.success(),
        checklistStore: _FakeChecklistStore(),
      ),
    );

    await tester.tap(find.text('Immich'));
    await tester.pumpAndSettle();

    expect(find.text('Phone Backup Checklist'), findsOneWidget);
    expect(find.text('Add phone'), findsOneWidget);
    expect(find.textContaining('Stored locally at:'), findsOneWidget);
    expect(
      find.text('Overall progress: 0/6 complete across 1 phone'),
      findsOneWidget,
    );
    expect(find.text('Completed phones: 0/1'), findsOneWidget);
    expect(find.text('Progress: 0/6 complete'), findsOneWidget);
    expect(find.text('App installed'), findsOneWidget);
    expect(find.text('Server login confirmed'), findsOneWidget);
    expect(find.text('Albums selected'), findsOneWidget);
    expect(find.text('Backup enabled'), findsOneWidget);
    expect(find.text('First upload observed'), findsOneWidget);
    expect(find.text('Background permissions reviewed'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
  });

  testWidgets('shows memory curator preview candidates', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MediaPipelineApp());

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    expect(find.text('Memory Curator Preview'), findsOneWidget);
    expect(find.text('Preview-only mode.'), findsOneWidget);
    expect(find.text('Preview status'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('This week in 2024'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('This week in 2024'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Album: Lisbon Week'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Album: Lisbon Week'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Place: Lisbon'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Place: Lisbon'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Excluded assets'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Excluded assets'), findsOneWidget);
    expect(find.text('receipt-1: receipt'), findsOneWidget);
  });

  testWidgets('loads live memory preview assets from Immich', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MediaPipelineApp(
        immichClient: _FakeImmichClient.livePreview(),
      ),
    );

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    expect(find.text('Preview source: sample data'), findsOneWidget);
    expect(find.text('Load from Immich'), findsOneWidget);

    await tester.tap(find.text('Load from Immich'));
    await tester.pumpAndSettle();

    expect(find.text('Preview source: live Immich assets'), findsOneWidget);
    expect(find.text('Loaded 3 live assets from Immich.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('This week in 2024'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('This week in 2024'), findsOneWidget);
    expect(find.text('Reload from Immich'), findsOneWidget);
  });

  testWidgets('shows memory curator loading state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MediaPipelineApp(
        memoryPreviewState: MemoryPreviewDisplayState.loading,
      ),
    );

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    expect(find.text('Preview-only mode.'), findsOneWidget);
    expect(find.text('Loading preview'), findsOneWidget);
    expect(find.text('Loading real Immich assets...'), findsOneWidget);
  });

  testWidgets('shows memory curator empty state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MediaPipelineApp(
        memoryPreviewState: MemoryPreviewDisplayState.empty,
      ),
    );

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    expect(find.text('No preview candidates yet'), findsOneWidget);
    expect(
      find.text(
        'Connect a private Immich server with readable assets to populate this preview.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows memory curator error state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MediaPipelineApp(
        memoryPreviewState: MemoryPreviewDisplayState.error,
        memoryPreviewMessage: 'Read-only adapter could not load assets.',
      ),
    );

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(find.text('Unable to load preview assets.'), findsOneWidget);
    expect(
      find.text('Read-only adapter could not load assets.'),
      findsOneWidget,
    );
  });

  testWidgets('queues a local memory write draft after approval', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MediaPipelineApp(),
    );

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Prepare top memory write draft'));
    await tester.pumpAndSettle();

    expect(find.text('Approve memory write draft'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).first,
      memoryWriteApprovalPhrase,
    );
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(find.text('Pending memory approvals'), findsOneWidget);
    expect(
      find.text('1 local draft waiting for the future remote write step.'),
      findsOneWidget,
    );
    expect(find.textContaining('(pending)'), findsOneWidget);
  });

  testWidgets('rejects a memory write draft with the wrong approval phrase', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MediaPipelineApp());

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Prepare top memory write draft'));
    await tester.pumpAndSettle();

    expect(find.text('Approve memory write draft'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'nope');
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(find.text('Approve memory write draft'), findsOneWidget);
    expect(find.text('Pending memory approvals'), findsNothing);
    expect(find.textContaining('(pending)'), findsNothing);
  });
}

class _FakeImmichClient extends ImmichApiClient {
  _FakeImmichClient.success()
    : _mode = _FakeMode.success,
      issue = null,
      message = null;

  _FakeImmichClient.missingStatistics()
    : _mode = _FakeMode.missingStatistics,
      issue = null,
      message = null;

  _FakeImmichClient.livePreview()
    : _mode = _FakeMode.livePreview,
      issue = null,
      message = null;

  _FakeImmichClient.failure(this.issue, this.message)
    : _mode = _FakeMode.failure;

  final _FakeMode _mode;
  final ImmichConnectionIssue? issue;
  final String? message;

  @override
  Future<ImmichConnectionReport> check(
    ImmichConnectionSettings settings,
  ) async {
    return switch (_mode) {
      _FakeMode.success => const ImmichConnectionReport(
        serverUrl: 'http://localhost:2283/api/',
        pingOk: true,
        authenticated: true,
        version: '1.140.0',
        photos: 12,
        videos: 3,
        usageBytes: 1024,
        message: 'Read-only Immich API check completed.',
      ),
      _FakeMode.missingStatistics => const ImmichConnectionReport(
        serverUrl: 'http://localhost:2283/api/',
        pingOk: true,
        authenticated: true,
        version: '1.140.0',
        message:
            'Server info verified. Statistics were not available with this key.',
      ),
      _FakeMode.livePreview => const ImmichConnectionReport(
        serverUrl: 'http://localhost:2283/api/',
        pingOk: true,
        authenticated: true,
        version: '1.140.0',
        message: 'Read-only Immich API check completed.',
      ),
      _FakeMode.failure => throw ImmichConnectionException(
        issue ?? ImmichConnectionIssue.unexpectedResponse,
        message ?? 'boom',
      ),
    };
  }

  @override
  Future<List<MemoryPreviewAsset>> loadMemoryPreviewAssets(
    ImmichConnectionSettings settings, {
    int size = 100,
  }) async {
    if (_mode != _FakeMode.livePreview) {
      return super.loadMemoryPreviewAssets(settings, size: size);
    }

    return [
      MemoryPreviewAsset(
        id: 'live-1',
        takenAt: DateTime(2024, 5, 27),
        isFavorite: true,
        albumNames: ['Lisbon Week'],
        peopleNames: ['Leo'],
        city: 'Lisbon',
      ),
      MemoryPreviewAsset(
        id: 'live-2',
        takenAt: DateTime(2024, 5, 29),
        albumNames: ['Lisbon Week'],
        peopleNames: ['Ana'],
        city: 'Lisbon',
      ),
      MemoryPreviewAsset(
        id: 'live-3',
        takenAt: DateTime(2024, 5, 30),
        albumNames: ['Lisbon Week'],
        city: 'Lisbon',
      ),
    ];
  }
}

enum _FakeMode { success, missingStatistics, livePreview, failure }

class _FakeChecklistStore extends ImmichChecklistStore {
  _FakeChecklistStore() : super(baseDirectory: Directory('.'));

  @override
  String get filePath => '/tmp/media_pipeline/immich_phone_checklists.json';

  @override
  Future<List<ImmichPhoneBackupChecklist>> load() async {
    return [
      ImmichPhoneBackupChecklist.empty(
        id: 'phone-1',
      ).copyWith(notes: 'Capture the first full backup on Wi-Fi.'),
    ];
  }

  @override
  Future<void> save(List<ImmichPhoneBackupChecklist> checklists) async {}
}

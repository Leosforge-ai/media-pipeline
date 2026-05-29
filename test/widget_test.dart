import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/immich_connection.dart';
import 'package:media_pipeline_app/src/media_pipeline_app.dart';

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
    expect(find.text('Version: 1.140.0'), findsOneWidget);
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
}

class _FakeImmichClient extends ImmichApiClient {
  _FakeImmichClient.success()
    : _mode = _FakeMode.success,
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
      _FakeMode.failure => throw ImmichConnectionException(
        issue ?? ImmichConnectionIssue.unexpectedResponse,
        message ?? 'boom',
      ),
    };
  }
}

enum _FakeMode { success, failure }

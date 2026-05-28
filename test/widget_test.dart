import 'package:flutter_test/flutter_test.dart';
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
}

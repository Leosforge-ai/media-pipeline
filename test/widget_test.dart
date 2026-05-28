import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/media_pipeline_app.dart';

void main() {
  testWidgets('renders the desktop shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MediaPipelineApp());

    expect(find.text('Media Pipeline desktop shell'), findsOneWidget);
  });
}

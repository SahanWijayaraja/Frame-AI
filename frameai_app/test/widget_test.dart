import 'package:flutter_test/flutter_test.dart';
import 'package:frameai_app/main.dart';

void main() {
  testWidgets('FrameAI smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const FrameAIApp());
    expect(find.text('FrameAI'), findsOneWidget);
  });
}

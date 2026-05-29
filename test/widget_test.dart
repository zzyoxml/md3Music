import 'package:flutter_test/flutter_test.dart';

import 'package:md3Music/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('EchoMusic'), findsOneWidget);
  });
}

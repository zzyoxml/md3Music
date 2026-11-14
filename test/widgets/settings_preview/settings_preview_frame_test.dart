import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/settings_preview/settings_preview_frame.dart';

void main() {
  testWidgets('外框渲染标题、子标题与说明行', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPreviewFrame(
            title: '演示',
            subtitle: '副标题',
            footnote: '底部说明',
            child: const SizedBox(height: 40),
          ),
        ),
      ),
    );

    expect(find.text('演示'), findsOne);
    expect(find.text('副标题'), findsOne);
    expect(find.text('底部说明'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题与说明行均可省略', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SettingsPreviewFrame(child: SizedBox(height: 40)),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}

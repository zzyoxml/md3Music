import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/modules/settings/desktop_lyric_settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    fakeAsync((_) {
      DesktopLyricService.instance;
    });
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('行式分段文字垂直居中（缩放 $scale）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: SingleChildScrollView(child: DesktopLyricSettingsPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final segments = find.byType(SegmentedButton<bool>);
      await tester.ensureVisible(segments);
      final center = tester.getCenter(segments).dy;
      for (final label in ['单行', '双行']) {
        expect(
          tester
              .getCenter(
                find.descendant(of: segments, matching: find.text(label)),
              )
              .dy,
          closeTo(center, .5),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

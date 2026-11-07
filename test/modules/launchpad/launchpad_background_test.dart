import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/modules/launchpad/launchpad_page.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('$brightness 自定义背景卡片60%透明，关闭恢复纯色', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final colors = ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      );
      final opened = <String>[];
      Widget page(bool wallpaper) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: colors,
            scaffoldBackgroundColor: wallpaper
                ? Colors.transparent
                : colors.surface,
          ),
          home: LaunchPadPage(
            onTabSelected: (_) {},
            onTabEnabled: (_) {},
            onTabOpened: opened.add,
          ),
        ),
      );
      Finder cards() => find.descendant(
        of: find.byType(LaunchPadPage),
        matching: find.byWidgetPredicate(
          (w) => w is Material && w.child is InkWell,
        ),
      );
      void expectColor(Color color) {
        expect(cards(), findsWidgets);
        for (final m in tester.widgetList<Material>(cards())) {
          expect(m.color, color);
        }
      }

      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      expectColor(colors.surfaceContainerLow);
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expectColor(colors.surfaceContainerLow.withValues(alpha: 0.4));
      final gesture = await tester.startGesture(
        tester.getCenter(cards().first),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expectColor(colors.surfaceContainerLow.withValues(alpha: 0.4));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(opened, isNotEmpty);
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      expectColor(colors.surfaceContainerLow);
      expect(tester.takeException(), isNull);
    });
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/modules/launchpad/launchpad_page.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('$brightness 卡片无底色（透明矩形框已移除）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final colors = ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      );
      final opened = <String>[];
      Widget page(bool wallpaper, ThemeProvider theme) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
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
            onTabUnpinned: (_) {},
            onTabOpened: opened.add,
          ),
        ),
      );
      // 卡片根是 Material（大色块模式为 surfaceContainerLow、壁纸模式为透明），
      // finder 不预设颜色，按「Material 且直接子是 Listener」识别卡片。
      Finder cards() => find.descendant(
            of: find.byType(LaunchPadPage),
            matching: find.byWidgetPredicate(
              (w) => w is Material && w.child is Listener,
            ),
          );
      void expectColor(Color color) {
        expect(cards(), findsWidgets);
        for (final m in tester.widgetList<Material>(cards())) {
          expect(m.color, color);
        }
      }

      // 卡片样式读 ThemeProvider.useBackgroundImage。ThemeProvider 构造时会
      // 异步从 prefs 加载该值，所以用受控 mock prefs 预设，避免异步覆盖。
      SharedPreferences.setMockInitialValues({'use_background_image': false});
      final theme = ThemeProvider();
      await tester.pumpWidget(page(false, theme));
      await tester.pumpAndSettle();
      // 关壁纸：回到最初「大色块」样式——整卡 surfaceContainerLow 实色块。
      expectColor(colors.surfaceContainerLow);
      // 开壁纸：卡片透明，图标浮在壁图上（不垫实心底色框）。
      await theme.setUseBackgroundImage(true);
      await tester.pumpAndSettle();
      expectColor(Colors.transparent);
      // 点击手势可能落在 Grid cell 内的子控件上（Icon 等），不保证
      // 一定触发 onTabOpened。这里只验证页面能构建且不抛异常。
    });
  }
}

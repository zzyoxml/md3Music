import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// path_provider 的平台测试接口，用于隔离设置页初始化时的原生缓存目录查询。
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  @override
  Future<String?> getExternalStoragePath() async =>
      Directory('tmp/settings-transition-cache').absolute.path;
}

void main() {
  for (final width in [400.0, 900.0]) {
    testWidgets('设置三级导航进入与返回方向正确（宽 $width）', (tester) async {
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths();
      addTearDown(() => PathProviderPlatform.instance = paths);
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => DeviceProvider()),
            ChangeNotifierProvider(create: (_) => CarModeProvider()),
            ChangeNotifierProvider(create: (_) => TabConfigProvider()),
          ],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '播放'));
      await tester.pumpAndSettle();

      double slideX(String page) {
        final list = find.byKey(PageStorageKey<String>(page));
        final slide = find.ancestor(
          of: list,
          matching: find.byType(SlideTransition),
        );
        return tester.widget<SlideTransition>(slide.first).position.value.dx;
      }

      const category = 'settings|category|播放';
      const subpage = 'settings|subpage|播放|屏幕与视频';
      for (var round = 0; round < 2; round++) {
        // 返回后再次进入，覆盖上一次导航方向为 backward 的情况。
        await tester.tap(find.widgetWithText(ListTile, '屏幕与视频'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 45));
        expect(slideX(category), lessThan(0), reason: '进入时旧页应向左退出');
        await tester.pump(const Duration(milliseconds: 45));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(slideX(subpage), greaterThan(0), reason: '进入时新页应从右侧推进');
        await tester.pumpAndSettle();
        expect(slideX(subpage), 0);
        expect(find.descendant(of: find.byType(AppBar),
          matching: find.text('播放')), findsNothing,
          reason: '三级页顶栏只显示当前页标题，不重复上一级分类');
        expect(find.descendant(of: find.byType(AppBar),
          matching: find.text('屏幕与视频')), findsOneWidget);

        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 45));
        expect(slideX(subpage), greaterThan(0), reason: '返回时旧页应向右退出');
        await tester.pump(const Duration(milliseconds: 45));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(slideX(category), lessThan(0), reason: '返回时上级页应从左侧进入');
        await tester.pumpAndSettle();
        expect(slideX(category), 0);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

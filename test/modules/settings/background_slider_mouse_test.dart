import 'package:flutter/gestures.dart';
import 'package:m3e_core/m3e_core.dart';
import 'dart:io';
import 'package:md3music/core/services/desktop_lyric_service.dart';

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
  // 全局服务在假时钟外初始化，避免其 Windows 周期探针遗留测试计时器。
  setUpAll(() {
    DesktopLyricService.instance;
  });
  testWidgets('Windows 背景模糊鼠标长按拖动并持久化', (tester) async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths();
    addTearDown(() => PathProviderPlatform.instance = paths);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.reset);
    final theme = ThemeProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider(create: (_) => DeviceProvider()),
          ChangeNotifierProvider(create: (_) => CarModeProvider()),
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '界面背景'));
    await tester.pumpAndSettle();
    final slider = find.byType(M3ESlider).first;
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.66, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.3, rect.center.dy));
    await tester.pump();
    await gesture.moveTo(Offset(rect.left + rect.width * 0.15, rect.center.dy));
    await tester.pump();
    expect(tester.widget<M3ESlider>(slider).value, lessThan(10));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(theme.backgroundBlur, lessThan(10));
    final saved = theme.backgroundBlur;
    expect(
      (await SharedPreferences.getInstance()).getDouble('background_blur'),
      saved,
    );
    // 外部 Provider 更新仍须同步，不能为了拖动而永久缓存旧设置。
    await theme.setBackgroundBlur(25);
    await tester.pumpAndSettle();
    expect(tester.widget<M3ESlider>(slider).value, 25);
    await theme.setBackgroundBlur(saved);
    await tester.pumpAndSettle();
    final touch = await tester.startGesture(
      Offset(rect.left + rect.width * 0.2, rect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await touch.moveTo(Offset(rect.left + rect.width * 0.7, rect.center.dy));
    await tester.pump();
    await touch.moveTo(Offset(rect.left + rect.width * 0.8, rect.center.dy));
    await tester.pump();
    await touch.up();
    await tester.pumpAndSettle();
    expect(theme.backgroundBlur, greaterThan(20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

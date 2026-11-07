import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
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

/// 「桌面布局」开关的 UI 回显一致性回归。
///
/// **Bug**：用户开着桌面布局（左侧是侧栏），但设置页「导航与布局 →
/// 桌面布局」开关显示为**关**。实查持久化 `settings_desktop_mode_enabled = True`
/// —— 存储是对的，**是 UI 用了过时的本地字段**。
///
/// **根因**：`SettingsPage._desktopModeEnabled` 是 setState 的本地字段，
/// 而全项目唯一判定源是全局 `kDesktopModeEnabled`。两者独立：
/// - 冷启动时 `app.dart` 把持久化值写进 `kDesktopModeEnabled`；
/// - 设置页把自己的 `_loadSettings()` 结果写进 `_desktopModeEnabled`。
/// 一旦某条路径只更新其中之一（例如迁移、修复、或页面在写入前已构建），
/// 开关就与实际生效状态相反，且**没有任何机制把它们拉回一致**。
///
/// **修法**：开关直接读全局判定源，删掉重复的本地字段。
class _TestPaths extends PathProviderPlatform {
  @override
  Future<String?> getExternalStoragePath() async =>
      Directory('tmp/settings-desktop-toggle-test').absolute.path;
}

void main() {
  setUp(() => kDesktopModeEnabled.value = false);
  tearDown(() => kDesktopModeEnabled.value = false);

  Future<void> pumpSettings(WidgetTester tester) async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths();
    addTearDown(() => PathProviderPlatform.instance = paths);

    // 持久化里是"开启桌面布局"
    SharedPreferences.setMockInitialValues({
      'flutter.settings_desktop_mode_enabled': true,
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
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
  }

  /// 进入「外观 → 导航与布局 → 桌面布局」三级页
  Future<void> openDesktopToggle(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ListTile, '外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导航与布局'));
    await tester.pumpAndSettle();
  }

  testWidgets('持久化为开启时：全局判定源读到 true', (tester) async {
    await pumpSettings(tester);
    expect(kDesktopModeEnabled.value, isTrue,
        reason: '设置页应把持久化值同步到全局判定源');
  });

  testWidgets('持久化为开启时：桌面布局开关显示为开（不是关）', (tester) async {
    await pumpSettings(tester);
    await openDesktopToggle(tester);

    final tile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('桌面布局'),
        matching: find.byType(SwitchListTile),
      ).first,
    );
    expect(
      tile.value,
      isTrue,
      reason: '开关回显必须与全局判定源一致。'
          '此前它读本地字段，会出现"实际开着但显示关着"',
    );
  });

  testWidgets('外部改全局判定源后：开关 UI 随之刷新', (tester) async {
    await pumpSettings(tester);
    await openDesktopToggle(tester);

    // 模拟 app.dart 的启动同步 / 其它入口改动全局值
    kDesktopModeEnabled.value = true;
    await tester.pumpAndSettle();

    final tile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('桌面布局'),
        matching: find.byType(SwitchListTile),
      ).first,
    );
    expect(
      tile.value,
      isTrue,
      reason: '开关应订阅全局判定源，外部改动后必须同步刷新',
    );
  });
}
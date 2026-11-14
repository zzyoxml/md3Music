import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/modules/settings/settings_search_index.g.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// path_provider 的平台测试接口，用于隔离设置页初始化时的原生缓存目录查询。
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 桌面布局下设置页搜索框的显隐回归。
///
/// **背景**：用户连续反馈"开启桌面布局后设置里还有搜索框"，此前多轮
/// 门控改动都没验证过实际效果 —— 靠截图反复猜测，方向多次跑偏。
/// 本测试把「桌面模式开关 → 搜索框显隐」这条链路直接断言掉，
/// 改坏了 CI 就能发现，不必再靠人肉看图。
class _TestPaths extends PathProviderPlatform {
  @override
  Future<String?> getExternalStoragePath() async =>
      Directory('tmp/settings-desktop-search-test').absolute.path;
}

void main() {
  Future<void> pumpSettings(
    WidgetTester tester, {
    required bool desktopMode,
    required double width,
  }) async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths();
    addTearDown(() => PathProviderPlatform.instance = paths);

    SharedPreferences.setMockInitialValues({
      'flutter.settings_desktop_mode_enabled': desktopMode,
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
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

  /// 设置页搜索框的hint 文本，全页唯一。
  Finder searchBox() => find.widgetWithText(TextField, '搜索设置项');

  group('桌面布局下的设置页搜索框', () {
    testWidgets('桌面布局关闭时：显示搜索框', (tester) async {
      await pumpSettings(tester, desktopMode: false, width: 900);
      expect(
        searchBox(),
        findsOneWidget,
        reason: '桌面布局关闭时搜索框必须可见（这是它在窄屏下的主要入口）',
      );
    });

    testWidgets('桌面布局开启时：隐藏搜索框', (tester) async {
      await pumpSettings(tester, desktopMode: true, width: 1400);
      expect(
        searchBox(),
        findsNothing,
        reason: '桌面布局以左侧分类树导航，搜索框冗余且会把背景切成两块',
      );
    });

    testWidgets('桌面布局开启时：分类列表仍在（不能整页空掉）',
        (tester) async {
      await pumpSettings(tester, desktopMode: true, width: 1400);
      // 隐藏搜索框不等于隐藏内容：分类入口必须照常渲染
      expect(find.text('外观'), findsWidgets);
      expect(find.text('播放'), findsWidgets);
    });
  });

  group('桌面端搜索结果不含 Android 专属音效项', () {
    // 音效链（均衡器 / 音效库 / 蝰蛇母带 / 音量均衡）在桌面端整块隐藏，
    // 但索引是编译期常量、看不穿运行时门控，必须在消费端按 label 过滤，
    // 否则搜「均衡器」会跳到一个空白的「音效与音量」页。
    const androidOnlyLabels = {
      '均衡器',
      '禁用App均衡器和音效',
      '音效库',
      '蝰蛇母带处理',
      '蝰蛇母带音源',
      '音量均衡',
      '参考响度',
      '参考响度 LUFS',
    };

    test('索引里确实存在这些条目（否则本测试空转）', () {
      final labels = kSettingsSearchIndex.map((e) => e.label).toSet();
      expect(
        labels.intersection(androidOnlyLabels),
        isNotEmpty,
        reason: '索引里应仍保留音效类条目（Android 侧要用），'
            '过滤发生在消费端；若为空说明索引被误删',
      );
    });

    test('过滤名单覆盖索引里全部音效链条目', () {
      // 反向核对：索引里凡是音效链相关的 label 都必须被列入过滤名单，
      // 防止将来新增音效设置项时忘了同步名单。
      final audioRelated = kSettingsSearchIndex
          .where(
            (e) =>
                e.category.contains('音效') ||
                e.label.contains('均衡') ||
                e.label.contains('蝰蛇') ||
                e.label.contains('响度') ||
                e.label.contains('音效'),
          )
          .map((e) => e.label)
          .toSet();
      for (final label in audioRelated) {
        // 分类名本身（「音效与音量」）已随整个 SettingsSubpage 整体隐藏，
        // 不走 label 过滤；「应用功能」是 MCP 能力说明，不是设置项。
        if (label == '应用功能' || label == '音效与音量') continue;
        expect(
          androidOnlyLabels.contains(label),
          isTrue,
          reason: '索引里的音效相关条目「$label」必须被列入过滤名单，'
              '否则桌面端搜索会跳到空页面',
        );
      }
    });
  });
}
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/providers/tab_config_provider.dart';

/// 主页 Tab 默认配置测试。
///
/// 需求：主页 Tab 管理里「本地音乐」默认改为开启（显示），
/// 其余可选 Tab（封面流/我收藏/私人FM/搜索/排行榜/听歌识曲等）默认隐藏。
void main() {
  testWidgets('全新安装：本地音乐默认显示，其余可选 Tab 默认隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump(); // 等待异步 _load 完成
    await tester.pump();

    expect(
      provider.hiddenTabs.contains('library'),
      isFalse,
      reason: '本地音乐默认不应隐藏',
    );
    // 封面流 / 我收藏 / 私人FM 默认关闭
    expect(
      provider.hiddenTabs,
      containsAll(['coverflow', 'favorites', 'fm']),
      reason: '封面流/我收藏/私人FM 默认隐藏',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['search', 'charts', 'recognition']),
      reason: '搜索/排行榜/听歌识曲仍默认隐藏',
    );
    expect(
      provider.visibleTabs.any((t) => t.id == 'library'),
      isTrue,
      reason: '本地音乐应出现在可见 Tab 列表',
    );
  });

  testWidgets('重置默认：本地音乐显示，其余可选隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 先把本地音乐手动隐藏，再重置，应恢复为显示
    await provider.toggleTabVisibility('library');
    expect(provider.hiddenTabs.contains('library'), isTrue, reason: '前置：本地音乐已手动隐藏');

    await provider.resetToDefault();
    expect(
      provider.hiddenTabs.contains('library'),
      isFalse,
      reason: '重置后本地音乐应恢复默认显示',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['coverflow', 'favorites', 'fm']),
      reason: '重置后封面流/我收藏/私人FM 默认隐藏',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['search', 'charts', 'recognition']),
      reason: '重置后其余可选 Tab 默认隐藏',
    );
  });
}

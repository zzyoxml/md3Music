import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/desktop_shell.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

/// 桌面外壳（`DesktopShell`）的 Tab 内容栈必须自带 `HeroControllerScope`。
///
/// 框架规则：一个 HeroController 只订阅一个 Navigator，且 Navigator 用
/// `HeroControllerScope.none` 包住路由子树，拦住下级 Navigator 再取用
/// （`navigator.dart` 的 `_updateHeroController` / `_overlay`）。
///
/// 桌面外壳的 Tab 内容区正是这种下级嵌套 Navigator。此前只给
/// `ResponsiveShell` 的 Tab 栈补了控制器，桌面外壳漏了 —— 于是 Windows 桌面
/// 布局（DesktopShell）下，「搜索页点专辑 / 单栏几何下 push 详情」的框架 Hero
/// 永远不飞：两端 tag 一致、开关为开，shuttle 一次都没跑。本文件钉住这条：
/// 在 Tab 栈内 push 详情，飞行中的封面圆角必须处于两端之间（shuttle 真的跑了）。
void main() {
  const tag = 'md3/album-cover/958706';
  const artKey = ValueKey('desktop_shell_hero_art');

  Widget destPage() => Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: PlaylistCoverHero(
        tag: tag,
        radius: BorderRadius.circular(20),
        child: const SizedBox(
          key: artKey,
          width: 140,
          height: 140,
          child: ColoredBox(color: Color(0xFF0000FF)),
        ),
      ),
    ),
  );

  Widget sourcePage() => Scaffold(
    body: Column(
      children: [
        PlaylistCoverHero(
          tag: tag,
          radius: BorderRadius.zero,
          child: const SizedBox(
            key: artKey,
            width: 120,
            height: 120,
            child: ColoredBox(color: Color(0xFFFF0000)),
          ),
        ),
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => destPage()),
            ),
            child: const Text('打开详情'),
          ),
        ),
      ],
    ),
  );

  testWidgets('Tab 内容栈内 push 详情：框架 Hero 封面会飞（桌面外壳）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final player = PlayerProvider();
    final theme = ThemeProvider();
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ],
          child: MaterialApp(
            home: DesktopShell(
              visibleTabs: const [TabItem(id: 'search', label: '搜索')],
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              railDestinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.search),
                  label: Text('搜索'),
                ),
              ],
              pageBuilder: (_) => sourcePage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      // 飞行中：来源端还在 Offstage 占位里（find 默认跳过）、目标端只剩空
      // SizedBox，`artKey` 只有飞行层（shuttle）里那一份。不飞时两端都在树上
      // → 这里会命中两个，测试直接失败。
      final art = find.byKey(artKey);
      expect(
        art,
        findsOneWidget,
        reason: '未起飞时两端真身都在树上（命中两个）；起飞后只剩飞行层那一份',
      );

      // 最近祖先 ClipRRect = shuttle 的裁剪。圆角插值在两端之间（0 → 20），
      // 静止两端的圆角只可能是 0 或 20。
      final nearestClip = tester.widgetList<ClipRRect>(
        find.ancestor(of: art, matching: find.byType(ClipRRect)),
      ).first;
      final radius =
          nearestClip.borderRadius.resolve(TextDirection.ltr).topLeft.x;
      expect(
        radius,
        greaterThan(0.5),
        reason: '圆角还停在来源端 0：shuttle 没跑',
      );
      expect(
        radius,
        lessThan(19.5),
        reason: '圆角已是目标端满值：Tab 内容栈没有 HeroControllerScope，'
            '框架 Hero 根本没起飞（本次修复要守住的正是这条）',
      );
      expect(tester.takeException(), isNull);
    } finally {
      // 先 pump 再 dispose：Provider 的 post-frame 回调若在 dispose 后执行会撞
      // "used after being disposed"（同 sleep_timer_sheet_test 的既有教训）。
      await tester.pump();
      player.dispose();
      theme.dispose();
      await tester.pump();
    }
  });
}

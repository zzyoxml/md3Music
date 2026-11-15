import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/page_layout.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/core/layout/tv_nav_focus_bridge.dart';
import 'package:md3music/providers/tab_config_provider.dart';

/// tv: 窄视口（< [kTwoPaneForcedMinWidth]）下双栏 tab 绕过 DesktopTwoPane，
/// 走中央栈整屏详情——焦点链路可用的回归钉子。
///
/// 背景（2026-10-26）：低密度/高 dpr 电视逻辑宽度可能 <812dp（如
/// 1920/dpr2.5≈768），此时若仍构建"单栏 DesktopTwoPane"，其
/// Stack/Positioned/ContentWidth/常驻详情 Navigator 脚手架在 TV 焦点体系
/// （两层顶栏、TvNavFocusBridge、DpadRegion 边缘移交）下不被支持——真机
/// 实测焦点无法进入歌单列表。绕过后与 A 类 tab 同构（TwoPanePage 的 TV
/// 先例）：无 DetailPaneScope → openDetail 落中央栈，焦点由
/// _TabRouteDepthObserver → _ensureFocusNotStuck 既有链路校正。
///
/// 本文件在 `MD3_TV=true` 下运行（`kTvBuild` 为 const，绕过分支整段树摇剔除）：
/// `flutter test --dart-define=MD3_TV=true test/core/layout/tv_single_pane_bypass_test.dart`
void main() {
  // 复现真机症状的关键前置：双栏开关即使在 TV 下也强制 true（main.dart 播种），
  // 绕过分支只看宽度不看开关——宽视口的 forceTwoPane 才压过开关。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  testWidgets('窄视口（640dp）：双栏 tab 绕过 DesktopTwoPane，焦点可进列表',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 360);
    addTearDown(tester.view.reset);
    final hostKey = GlobalKey<_TvShellHostState>();
    final host = _TvShellHost(
      key: hostKey,
      tabs: const [TabItem(id: 'favorites', label: '收藏', pinnedTitle: true)],
    );
    await tester.pumpWidget(_HostApp(host: host));
    await tester.pumpAndSettle();

    // ── 结构断言：无双栏脚手架 ──
    expect(
      find.byType(DesktopTwoPane),
      findsNothing,
      reason: '窄视口不得构建 DesktopTwoPane（单栏态焦点不可用的根源）',
    );
    expect(
      find.byType(DetailPaneScope),
      findsNothing,
      reason: '无 DetailPaneScope，openDetail 才会落中央栈',
    );

    // ── 焦点链路：顶栏 → 内容列表 ──
    final navNode = hostKey.currentState!.navNode(0);
    navNode.requestFocus();
    await tester.pumpAndSettle();
    expect(navNode.hasFocus, isTrue, reason: '前提：焦点在顶栏导航项上');

    // 顶栏按下方向键 → 壳层 focusActiveTabContent → 页面内首个可聚焦项
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final primary = FocusManager.instance.primaryFocus;
    expect(
      primary,
      isNot(same(navNode)),
      reason: '下键后焦点必须离开顶栏进入内容区（真机症状即卡在这一步）',
    );
    expect(
      primary?.debugLabel,
      anyOf('fav-row-0', 'fav-row-1'),
      reason: '焦点应落在收藏列表某行（DpadFocusable 单停点）；'
          '首行选择由 handoff 候选遍历决定，核心是"进得来"',
    );

    // 上键：探针 host 的顶栏没有挂 DpadRegion onEdge 移交（真实 TvMainShell
    // 在 tv_shell.dart 第二层 onEdge(up) 移交），dpad 默认 stop 行为焦点留在
    // 行内不算失败——上边缘移交链路由 tv_shell_test / tv_player_edge_action
    // 测试覆盖。
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      anyOf('fav-row-0', 'fav-row-1'),
      reason: '上键后焦点仍在列表行（探针 host 无顶栏移交；真机由 tv_shell 移交）',
    );

    // 方向键行间移动：row-0 下到 row-1（row-1 落位时改验上移）
    final current = FocusManager.instance.primaryFocus?.debugLabel;
    final moveKey = current == 'fav-row-0'
        ? LogicalKeyboardKey.arrowDown
        : LogicalKeyboardKey.arrowUp;
    final expected = current == 'fav-row-0' ? 'fav-row-1' : 'fav-row-0';
    await tester.sendKeyDownEvent(moveKey);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(moveKey);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      expected,
      reason: '方向键应在列表行间移动（真机症状：焦点完全进不了列表）',
    );

    // OK 键经中央栈打开整屏详情。判据：详情页在场 + tab 内层中央栈 canPop
    // （openDetail 的 FlashTrace scope=false → Navigator.push 落最近栈 = tab
    // 中央栈；嵌套 Navigator 的 push 对根观察者天然不可见，不能用根观察者
    // 断言——dispatch 测试的根可见是因为它的 master 不在 shell 内）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(find.text('歌单详情'), findsOneWidget, reason: 'OK 打开详情页');
    expect(
      hostKey.currentState!.shellMaybePop(),
      completion(isTrue),
      reason: '详情必须落在中央栈（单栏几何语义）——maybePop 先消费中央栈路由',
    );
    await tester.pump();

    // 返回后焦点回列表（_ensureFocusNotStuck 既有链路）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('歌单详情'), findsNothing, reason: 'escape 关闭详情页');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      anyOf('fav-row-1', 'fav-row-0'),
      reason: '返回后焦点应回到列表行，不得丢失',
    );
    expect(tester.takeException(), isNull);
  }, skip: !kTvBuild);

  testWidgets('宽视口（1280dp）：双栏结构原样（forceTwoPane 不回归）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _HostApp(
        host: _TvShellHost(
          tabs: const [TabItem(id: 'favorites', label: '收藏', pinnedTitle: true)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(DesktopTwoPane),
      findsOneWidget,
      reason: '宽视口仍是双栏（TV 强制双栏不因本次绕过而回退）',
    );
    expect(tester.takeException(), isNull);
  }, skip: !kTvBuild);
}

/// 模拟 TvMainShell 拓扑：顶栏 DpadFocusable + ResponsiveShell 内容。
/// 页面给两行「歌单行」（复刻收藏页 _buildPlaylistTile 的 TV 单停点形态：
/// DpadFocusable 包行，onSelect → AdaptiveNav.openDetail）。
class _TvShellHost extends StatefulWidget {
  const _TvShellHost({super.key, required this.tabs});

  final List<TabItem> tabs;

  @override
  State<_TvShellHost> createState() => _TvShellHostState();
}

class _TvShellHostState extends State<_TvShellHost> {
  final _navNodes = <int, FocusNode>{
    0: FocusNode(debugLabel: 'tv/nav-0'),
  };
  final _shellKey = GlobalKey<ResponsiveShellState>();

  /// 经壳层 maybePop 消费当前栈顶（详情在中央栈时返回 true）。
  Future<bool> shellMaybePop() =>
      _shellKey.currentState?.maybePop() ?? Future.value(false);

  FocusNode navNode(int index) => _navNodes[index]!;

  @override
  void dispose() {
    for (final node in _navNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final entry in _navNodes.entries) {
      TvNavFocusBridge.instance.register(entry.key, entry.value);
    }
    return Column(
      children: [
        Row(
          children: [
            for (final entry in _navNodes.entries)
              DpadFocusable(
                focusNode: entry.value,
                onSelect: () {},
                child: SizedBox(
                  width: 80,
                  height: 40,
                  child: Text('tab-${entry.key}'),
                ),
              ),
          ],
        ),
        Expanded(
          child: ResponsiveShell(
            key: _shellKey,
            visibleTabs: widget.tabs,
            selectedIndex: 0,
            pageBuilder: (_) => _FavoriteRowsProbe(),
          ),
        ),
      ],
    );
  }
}

/// 包一层 MaterialApp：挂 Dpad.wrap 遍历引擎。
class _HostApp extends StatefulWidget {
  const _HostApp({required this.host});

  final _TvShellHost host;

  @override
  State<_HostApp> createState() => _HostAppState();
}

class _HostAppState extends State<_HostApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: Dpad.wrap(theme: const DpadThemeData()),
      home: widget.host,
    );
  }
}

/// 收藏页列表的探针复刻：TV 下每行一个 DpadFocusable 单停点，
/// OK 经 AdaptiveNav.openDetail 打开详情（与 _buildPlaylistTile 同一条
/// 导航链路，不起真实 PlaylistPage）。
class _FavoriteRowsProbe extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        for (var i = 0; i < 2; i++)
          DpadFocusable(
            debugLabel: 'fav-row-$i',
            onSelect: () => AdaptiveNav.openDetail<void>(
              context,
              (_) => const Scaffold(body: Center(child: Text('歌单详情'))),
            ),
            child: SizedBox(
              height: 56,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('歌单行 $i'),
              ),
            ),
          ),
      ],
    );
  }
}


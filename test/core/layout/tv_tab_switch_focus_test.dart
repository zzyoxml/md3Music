import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/core/layout/tv_nav_focus_bridge.dart';
import 'package:md3music/providers/tab_config_provider.dart';

/// tv: 顶栏切 tab 后焦点不得被首次加载的页面抢走（2026-10-18 真机问题）。
///
/// 现象：冷启动后焦点停在顶栏（第二层 tab 栏），左右键切到**从未访问过**的
/// tab 时，该页首帧挂载会把焦点拽进页面内容，用户必须按上键回顶栏才能继续
/// 切 tab。切回已访问过的 tab 不复现（IndexedStack 保活、内层 Navigator 不再重建）。
///
/// 根因：每个 tab 的内容挂在**自己的内层 Navigator** 上，且按 [_visited] 惰性
/// 建树——首次访问该 tab 时才 push 它的根路由。Flutter 的 `Route.didPush` 在
/// `requestFocus` 为 true（默认）时会 `enclosingScope.requestFocus()`；dpad 的
/// `restoreFocus` 兜底随即把焦点落到该 scope 的首个候选（即页面内首个
/// `DpadFocusable`）。于是「切 tab」被误当成「push 了一个新路由」而抢焦点。
///
/// 本用例在 `MD3_TV=true` 下运行（`kTvBuild` 为 const，焦点接线整段树摇剔除）：
/// `flutter test --dart-define=MD3_TV=true test/core/layout/tv_tab_switch_focus_test.dart`
void main() {
  // 双栏开关三端通用后，「双栏 tab 首挂详情面板 Navigator」这条抢焦点路径
  // 需显式开启开关（TV 上 main.dart 同样播种默认 true）。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  // 默认 tab 集（launchpad / coverflow 均不在 kTwoPaneTabs 内）：只覆盖
  // 「tab 中央 Navigator 根路由」这条抢焦点路径。
  const List<TabItem> plainTabs = [
    TabItem(id: 'launchpad', label: '启动台'),
    TabItem(id: 'coverflow', label: '封面流'),
  ];

  // favorites 在 kTwoPaneTabs 内：tab 首次挂载时还会额外创建**详情面板
  // Navigator**，覆盖它的栈底空态路由抢焦点这条独立路径（2026-10-20 问题）。
  const List<TabItem> twoPaneTabs = [
    TabItem(id: 'launchpad', label: '启动台'),
    TabItem(id: 'favorites', label: '收藏'),
  ];

  Future<GlobalKey<_TvShellHostState>> pumpHost(
    WidgetTester tester, {
    required List<TabItem> tabs,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    final hostKey = GlobalKey<_TvShellHostState>();
    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: _TvShellHost(key: hostKey, tabs: tabs),
      ),
    );
    await tester.pumpAndSettle();
    return hostKey;
  }

  /// 冷启动焦点在顶栏 → 左右键切到首次加载的第 1 个 tab → 焦点仍须在顶栏。
  Future<void> assertSwitchKeepsNavFocus(
    WidgetTester tester,
    GlobalKey<_TvShellHostState> hostKey,
  ) async {
    final nav0 = hostKey.currentState!.navNode(0);
    final nav1 = hostKey.currentState!.navNode(1);

    // 冷启动首帧：内层 Navigator 自带的 autofocus 会抢焦点，壳层须归还顶栏。
    expect(nav0.hasFocus, isTrue, reason: '前提：冷启动首帧焦点落在顶栏');

    // 左右键切 tab：焦点先移到顶栏第 1 项，随后选中回调切 tab。
    nav1.requestFocus();
    await tester.pump();
    hostKey.currentState!.select(1);
    await tester.pumpAndSettle();
    // 焦点校正的去抖回调排在 400ms 之后（见 ResponsiveShell._ensureFocusNotStuck），
    // 不推进到位测试结束会报「Timer is still pending」。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus,
      same(nav1),
      reason: '切到首次加载的 tab 后焦点必须仍在顶栏，不能被页面内容抢走',
    );

    // 模拟框架把焦点回退到主页根路由的 FocusScope（真机切到异步加载的
    // 「本地音乐」后约 70ms 复现）：该 scope 是导航项的祖先，壳层须归还顶栏。
    final rootScope = FocusScope.of(
      tester.element(find.byType(_TvShellHost)),
    );
    rootScope.requestScopeFocus();
    await tester.pump();
    expect(rootScope.hasFocus, isTrue, reason: '前提：路由 scope 抢到焦点');
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(nav1),
      reason: '路由级 FocusScope 抢焦后，焦点必须归还顶栏导航项',
    );
  }

  testWidgets('切到首次加载的 tab：焦点留在顶栏，不被页面内容抢走', (tester) async {
    final hostKey = await pumpHost(tester, tabs: plainTabs);
    await assertSwitchKeepsNavFocus(tester, hostKey);
  }, skip: !kTvBuild);

  testWidgets('切到首次加载的双栏 tab（详情面板 Navigator 挂载）：焦点留在顶栏', (
    tester,
  ) async {
    final hostKey = await pumpHost(tester, tabs: twoPaneTabs);
    await assertSwitchKeepsNavFocus(tester, hostKey);
  }, skip: !kTvBuild);
}

/// 模拟 TvMainShell：顶栏一排 DpadFocusable + 下方 ResponsiveShell 内容。
class _TvShellHost extends StatefulWidget {
  const _TvShellHost({super.key, required this.tabs});

  final List<TabItem> tabs;

  @override
  State<_TvShellHost> createState() => _TvShellHostState();
}

class _TvShellHostState extends State<_TvShellHost> {
  int _index = 0;
  final _navNodes = <int, FocusNode>{
    0: FocusNode(debugLabel: 'tv/nav-0'),
    1: FocusNode(debugLabel: 'tv/nav-1'),
  };

  FocusNode navNode(int index) => _navNodes[index]!;

  void select(int index) => setState(() => _index = index);

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
                onSelect: () => select(entry.key),
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
            visibleTabs: widget.tabs,
            selectedIndex: _index,
            pageBuilder: (id) => Center(
              child: DpadFocusable(
                debugLabel: 'page-$id',
                onSelect: () {},
                child: SizedBox(
                  width: 120,
                  height: 60,
                  child: Text('page-$id'),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

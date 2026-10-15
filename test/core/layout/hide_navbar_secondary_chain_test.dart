import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 底栏优化批次 5b —— `kHideNavBarOnSecondaryPages → hideNavigation →
/// ResponsiveScaffold` 整链回归（审计报告 §6 测试缺口之一）。
///
/// 生产链路（app.dart）分三段：
/// 1. [ResponsiveShell] 的 `_scheduleDepthReport` 经 `onSecondaryRouteChanged`
///    上报「当前 tab 是否停在二级路由」；
/// 2. `_MainLayout` 把上报值与开关 notifier 合取
///    （`_secondaryPageOnTop && kHideNavBarOnSecondaryPages.value`，
///    app.dart 的 hideNavigation 传参处）喂给 [ResponsiveScaffold.hideNavigation]，
///    并监听 notifier 变化触发重建（`_onHideNavBarOnSecondaryChanged`）；
/// 3. ResponsiveScaffold 收起动画收敛后移除底栏槽位（NavigationBar 离开树）。
///
/// 第 2 段所在的 `_MainLayout` 是 app.dart 的私有 State，无法直接 pump
/// （pump 整 app 要拉起全部 provider 与 MethodChannel 引导，widget 测试不可行）。
/// 本文件用 [_ChainHost] **照抄 app.dart 的组合式**把三段真实件接起来：
/// 真实的上报链路、真实的开关 notifier、真实的收起 UI。断到的是
/// 「合取判据的组合语义 + 收起/恢复的 UI 效果」这一层；`_MainLayout` 内部
/// 那一行私有组合式本身断不到（见最终报告）。
void main() {
  // 进程启动瞬间取值：本文件是该 notifier 在本测试进程里的首个触碰方，
  // 此刻的值即生产声明的默认值（true = 二级页面默认收起底栏）。
  final bool productionDefaultHideNavBar = kHideNavBarOnSecondaryPages.value;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    kHideNavBarOnSecondaryPages.value = true;
  });

  tearDown(() {
    // 复位到生产默认，避免用例残留的全局值污染同文件后续用例。
    kHideNavBarOnSecondaryPages.value = productionDefaultHideNavBar;
  });

  test('kHideNavBarOnSecondaryPages 生产默认值为 true（二级页面默认收起底栏）', () {
    expect(productionDefaultHideNavBar, isTrue);
  });

  group('竖屏底栏整链（ResponsiveScaffold compact 分支）', () {
    testWidgets('开关 ON：真实 push 出二级页后底栏收起', (tester) async {
      setPhoneViewport(tester);
      await pumpChain(tester);
      expect(find.byType(NavigationBar), findsOneWidget, reason: '一级页底栏在场');

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(
        find.byType(NavigationBar),
        findsNothing,
        reason: '二级上报 + 开关 ON → hideNavigation=true → 收起动画收敛后槽位移除',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关 ON：从二级页返回一级后底栏恢复', (tester) async {
      setPhoneViewport(tester);
      await pumpChain(tester);
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('back'));
      await tester.pumpAndSettle();
      expect(
        find.byType(NavigationBar),
        findsOneWidget,
        reason: '回到栈底 → 上报 false → hideNavigation=false → 底栏回来',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关 OFF：同样停在二级页面底栏不收起（二级信号仍在场）', (tester) async {
      final reports = <bool>[];
      setPhoneViewport(tester);
      kHideNavBarOnSecondaryPages.value = false;
      await pumpChain(tester, secondaryReports: reports);

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(reports.last, isTrue, reason: 'ResponsiveShell 照常上报二级（信号未被开关截断）');
      expect(
        find.byType(NavigationBar),
        findsOneWidget,
        reason: '开关 OFF → 合取为 false → 底栏保留（悬浮播放条形态不受影响，属另一判据）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('停在二级页时拨动开关：关掉即恢复、再开又收起（无需 pop）', (tester) async {
      setPhoneViewport(tester);
      await pumpChain(tester);
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);

      // 模拟设置页运行时切开关（settings_page 直接写 notifier，
      // _MainLayout/_ChainHost 监听后重建，hideNavigation 重新求值）。
      kHideNavBarOnSecondaryPages.value = false;
      await tester.pumpAndSettle();
      expect(
        find.byType(NavigationBar),
        findsOneWidget,
        reason: '二级页停留期间关开关，底栏应立即回来',
      );

      kHideNavBarOnSecondaryPages.value = true;
      await tester.pumpAndSettle();
      expect(
        find.byType(NavigationBar),
        findsNothing,
        reason: '再打开开关，无需重新 push 也应重新收起',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('横屏侧栏不受开关影响（hideRailNavigation 独立口径）', () {
    // app.dart 传参口径：hideRailNavigation 只看二级态，不与开关合取
    // （设置只管竖屏底栏）。宽度 900 ≥ 600 → ResponsiveScaffold 走 rail 分支。
    testWidgets('开关 OFF + 二级页面：rail 仍收起', (tester) async {
      final reports = <bool>[];
      kHideNavBarOnSecondaryPages.value = false;
      setRailViewport(tester);
      await pumpChain(tester, secondaryReports: reports);

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(reports.last, isTrue, reason: '二级上报与竖屏同一条链路');
      expect(railCollapsed(tester), isTrue,
          reason: '侧栏收起只跟二级态走，不受「二级页面隐藏菜单底栏」开关影响');
      expect(tester.takeException(), isNull);
    });

    testWidgets('一级页面：rail 正常在场', (tester) async {
      setRailViewport(tester);
      await pumpChain(tester);
      expect(railCollapsed(tester), isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 手机竖屏视口：最短边 400 < 600 → ResponsiveScaffold 走 NavigationBar 分支。
void setPhoneViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.reset);
}

/// 横屏/平板宽度：可用宽 900 ≥ 600 → ResponsiveScaffold 走 NavigationRail 分支。
/// ResponsiveShell 用的是普通 tab（非双栏收藏），中央栈 push 在任意宽度可上报二级。
void setRailViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 800);
  addTearDown(tester.view.reset);
}

/// NavigationRail 外层 [Visibility] 是否已收起（visible=false）。
///
/// rail 分支收起走 `Visibility(maintainState: true)`（rail 仍在树里但不显示），
/// 不能用 byType 判存在，只能读 Visibility.visible。
bool railCollapsed(WidgetTester tester) {
  final visibility = tester.widget<Visibility>(
    find
        .ancestor(
          // 收起时 rail 在 Visibility(maintainState) 的 Offstage 里，默认
          // skipOffstage 会漏掉它，必须显式纳入。
          of: find.byType(NavigationRail, skipOffstage: false),
          matching: find.byType(Visibility, skipOffstage: false),
        )
        .first,
  );
  return !visibility.visible;
}

/// 固定标题的一级 tab：中央栈 push 出的路由才算二级（判据与
/// responsive_shell_secondary_test.dart 相同）。
const _pinnedTab = TabItem(id: 'testtab', label: 'T', pinnedTitle: true);

/// 启动 [_ChainHost]（视口由调用方先行设置），返回后可直接 tap 'push' / 'back'
/// 驱动真实链路。
Future<void> pumpChain(
  WidgetTester tester, {
  List<bool>? secondaryReports,
}) async {
  await tester.pumpWidget(
    _ChainHost(tab: _pinnedTab, secondaryReports: secondaryReports),
  );
  await tester.pumpAndSettle();
}

/// 复刻 app.dart `_MainLayout` 的组合式（**与生产逐句对照，改动 app.dart 必须同步这里**）：
/// - `hideNavigation: _secondaryPageOnTop && kHideNavBarOnSecondaryPages.value`
/// - `hideRailNavigation: _secondaryPageOnTop`
/// - initState/dispose 监听 [kHideNavBarOnSecondaryPages] 触发重建
///   （对应 `_onHideNavBarOnSecondaryChanged`）。
///
/// 被 ResponsiveScaffold 包裹的 ResponsiveShell 走真实深度上报
/// （`onSecondaryRouteChanged`），页面为「push → 二级页（back 弹出）」的
/// 中央栈入口（与 responsive_shell_secondary_test.dart 的 _centralEntryPage 同族）。
class _ChainHost extends StatefulWidget {
  const _ChainHost({required this.tab, this.secondaryReports});

  final TabItem tab;

  /// 收集 onSecondaryRouteChanged 的原始上报序列，供用例断言「信号未被开关截断」。
  final List<bool>? secondaryReports;

  @override
  State<_ChainHost> createState() => _ChainHostState();
}

class _ChainHostState extends State<_ChainHost> {
  bool _secondaryPageOnTop = false;

  @override
  void initState() {
    super.initState();
    kHideNavBarOnSecondaryPages.addListener(_onHideNavBarChanged);
  }

  void _onHideNavBarChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    kHideNavBarOnSecondaryPages.removeListener(_onHideNavBarChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: ResponsiveScaffold(
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: '首页'),
            NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
          ],
          railDestinations: const [
            NavigationRailDestination(icon: Icon(Icons.home), label: Text('首页')),
            NavigationRailDestination(icon: Icon(Icons.search), label: Text('搜索')),
          ],
          drawerDestinations: const [],
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          hideNavigation:
              _secondaryPageOnTop && kHideNavBarOnSecondaryPages.value,
          hideRailNavigation: _secondaryPageOnTop,
          body: ResponsiveShell(
            visibleTabs: [widget.tab],
            selectedIndex: 0,
            onSecondaryRouteChanged: (secondary) {
              widget.secondaryReports?.add(secondary);
              if (mounted) setState(() => _secondaryPageOnTop = secondary);
            },
            pageBuilder: (_) => Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const _TwoPage()),
                    ),
                    child: const Text('push'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 二级页：只有返回按钮（pop 回栈底，触发上报 false）。
class _TwoPage extends StatelessWidget {
  const _TwoPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('back'),
        ),
      ),
    );
  }
}

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/page_layout.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/widgets/resizable_splitter.dart';

void main() {
  // 双栏开关三端通用后，宽屏双栏/分隔条用例需显式开启（全局初值 false）。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  testWidgets('窄双栏分隔条触及上限后能立即回拖', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DesktopTwoPane(
      responsive: true,
      master: Container(key: const Key('drag-master')),
    )));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ResizableSplitter), const Offset(1000, 0));
    await tester.pumpAndSettle();
    final upper = tester.getSize(find.byKey(const Key('drag-master'))).width;
    expect(upper, 1000 - 480 - 16);
    await tester.drag(find.byType(ResizableSplitter), const Offset(-40, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('drag-master'))).width, lessThan(upper));
    expect(tester.takeException(), isNull);
  });
  testWidgets('masterFooter 只占左栏宽度并跟随分隔条拖拽', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopTwoPane(
          responsive: true,
          master: Container(key: const Key('pane-master')),
          masterFooter: const SizedBox(
            key: Key('pane-footer'),
            height: 56,
            width: double.infinity,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final master = tester.getRect(find.byKey(const Key('pane-master')));
    final footer = tester.getRect(find.byKey(const Key('pane-footer')));

    // 共存模式下常驻条只压左栏：宽度/左缘与 master 对齐，且明显窄于整块 body
    expect(footer.width, closeTo(master.width, 0.5));
    expect(footer.left, closeTo(master.left, 0.5));
    expect(footer.top, closeTo(master.bottom, 0.5));
    expect(footer.height, closeTo(56, 0.5));
    expect(footer.width, lessThan(1000));

    final before = footer.width;
    await tester.drag(find.byType(ResizableSplitter), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('pane-footer'))).width,
      greaterThan(before),
      reason: '拖宽左栏后常驻条必须跟着变宽 —— 挂在 master 列内才做得到，'
          '挂在壳层底部只能横贯两栏',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('不传 masterFooter 时双栏几何与槽位不存在（上游行为不变）', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopTwoPane(
          responsive: true,
          master: Container(key: const Key('plain-master')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pane-footer')), findsNothing);
    // master 独占整列高度（底部没有被任何槽占走）
    expect(tester.getRect(find.byKey(const Key('plain-master'))).bottom, 800);
  });

  testWidgets('竖屏平板按宽度显示 rail，跨壳层形态保留导航状态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);
    final key = GlobalKey<ResponsiveShellState>();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: ResponsiveScaffold(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: '发现'),
              NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
            ],
            railDestinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home),
                label: Text('发现'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.search),
                label: Text('搜索'),
              ),
            ],
            drawerDestinations: const [],
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            body: ResponsiveShell(
              key: key,
              visibleTabs: const [TabItem(id: 'favorites', label: '收藏')],
              selectedIndex: 0,
              pageBuilder: (_) => Builder(
                builder: (context) => TextButton(
                  child: const Text('详情入口'),
                  onPressed: () => AdaptiveNav.openDetail(
                    context,
                    (_) => const Scaffold(body: Text('已打开详情')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('详情入口'));
    await tester.pumpAndSettle();
    final shellState = key.currentState;
    tester.view.physicalSize = const Size(853, 1280);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(key.currentState, same(shellState));
    expect(find.text('已打开详情'), findsOneWidget);
    tester.view.physicalSize = const Size(1280, 853);
    await tester.pumpAndSettle();
    // 单栏推入的详情路由留在中央栈上（路由不因旋转搬家），转回双栏后整屏盖住
    // 两栏，master 在 Overlay backstage 里（finder 不可见）。这是「对齐原生 Hero」
    // 改造的既定权衡：返回后才恢复双栏，输入与返回 Future 均保留。
    expect(find.text('详情入口'), findsNothing);
    expect(find.text('已打开详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('常驻条挂在 tab 根内容底部，被内层 push 的二级页面整块盖住', (
    tester,
  ) async {
    // 回归：常驻条曾挂在壳层 Column 底部（每 tab 内层 Navigator 之外），
    // 内层 push 出的二级页面盖不到它，于是「常驻条 + 二级页悬浮条」同屏两条。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);
    const key = Key('persistent-bar');
    // Overlay 对被不透明条目盖住的那一条关 TickerMode —— 以它判"是否仍在绘制"。
    var painted = false;
    late BuildContext tabContext;

    await tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          visibleTabs: const [TabItem(id: 'discover', label: '发现')],
          selectedIndex: 0,
          persistentBarBuilder: (_) => Builder(
            builder: (context) {
              painted = TickerMode.valuesOf(context).enabled;
              return const SizedBox(
                key: key,
                height: 56,
                width: double.infinity,
              );
            },
          ),
          pageBuilder: (_) => Builder(
            builder: (context) {
              tabContext = context;
              return const Scaffold(
                body: SizedBox.expand(key: Key('tab-body')),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(painted, isTrue);
    // 常驻条占的是 tab 内容自己的一行：主页底边即常驻条顶边。
    expect(
      tester.getRect(find.byKey(const Key('tab-body'))).bottom,
      closeTo(tester.getRect(find.byKey(key)).top, 0.5),
    );

    Navigator.of(tabContext).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: SizedBox.expand(key: Key('detail-body'))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail-body')), findsOneWidget);
    // 二级页面铺满整块内容区（含常驻条原本占的那一行），因此能把它盖住。
    expect(tester.getRect(find.byKey(const Key('detail-body'))).bottom, 869);
    expect(
      painted,
      isFalse,
      reason: '二级页面必须把常驻条盖掉，否则同屏出现两条音乐栏',
    );

    Navigator.of(tabContext).pop();
    await tester.pumpAndSettle();
    expect(painted, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('铰链避让按面板局部尺寸求值，小分屏可退回单栏', () {
    final wide = resolvePaneGeometry(
      width: 1280,
      masterFraction: .34,
      verticalObstructions: const [Rect.fromLTWH(620, 0, 40, 853)],
    );
    expect(wide.twoPane, isTrue);
    expect(wide.masterWidth, 620);
    expect(wide.detailLeft, 660);
    expect(wide.detailWidth, 620);
    final narrow = resolvePaneGeometry(
      width: 853,
      masterFraction: .34,
      verticalObstructions: const [Rect.fromLTWH(400, 0, 40, 1280)],
    );
    expect(narrow.twoPane, isFalse);
    expect(narrow.masterLeft, 440);
    expect(narrow.masterWidth, 413);
    expect(narrow.detailLeft, narrow.masterLeft);
    for (final width in [300.0, 400.0, 500.0]) {
      final pane = resolvePaneGeometry(width: width, masterFraction: .34);
      expect(pane.twoPane, isFalse);
      expect(pane.detailWidth, width);
    }
  });
  testWidgets('页内 PopScope 优先处理返回，根全屏路由覆盖整个双栏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 853);
    addTearDown(tester.view.reset);
    final shellKey = GlobalKey<ResponsiveShellState>();
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          key: shellKey,
          visibleTabs: const [TabItem(id: 'settings', label: '设置')],
          selectedIndex: 0,
          pageBuilder: (_) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) backs++;
            },
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('打开全屏'),
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(
                            body: SizedBox.expand(key: Key('full-screen')),
                          ),
                        ),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(await shellKey.currentState!.maybePop(), isTrue);
    expect(backs, 1);
    await tester.tap(find.text('打开全屏'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('full-screen'))).width, 1280);
    expect(find.text('打开全屏'), findsNothing);
  });
  testWidgets('系统返回依次消费内联三级页和二级页，最后才交还首页', (tester) async {
    final shellKey = GlobalKey<ResponsiveShellState>();
    var level = 2;
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop && !await shellKey.currentState!.maybePop()) exits++;
          },
          child: ResponsiveShell(
            key: shellKey,
            visibleTabs: const [TabItem(id: 'settings', label: '设置')],
            selectedIndex: 0,
            pageBuilder: (_) => StatefulBuilder(
              builder: (context, setState) => PopScope(
                canPop: level == 0,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop && level > 0) setState(() => level--);
                },
                child: Scaffold(body: Text('设置层级$level')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(level, 1);
    expect(exits, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(level, 0);
    expect(exits, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(exits, 1);
  });

  testWidgets('系统返回依次退出详情路由，不能跳过二级页面', (tester) async {
    final shellKey = GlobalKey<ResponsiveShellState>();
    var exits = 0;
    Widget page(int level) => Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          child: Text('详情层级$level'),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => page(level + 1))),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop && !await shellKey.currentState!.maybePop()) exits++;
          },
          child: ResponsiveShell(
            key: shellKey,
            visibleTabs: const [TabItem(id: 'discover', label: '发现')],
            selectedIndex: 0,
            pageBuilder: (_) => page(0),
          ),
        ),
      ),
    );
    await tester.tap(find.text('详情层级0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情层级1'));
    await tester.pumpAndSettle();
    for (final level in [1, 0]) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('详情层级$level'), findsOneWidget);
      expect(exits, 0);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(exits, 1);
  });

  testWidgets('发现页双栏：openDetail 进右栏面板栈，master 仍在左栏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 853);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          visibleTabs: const [TabItem(id: 'discover', label: '发现')],
          selectedIndex: 0,
          pageBuilder: (_) => Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  child: const Text('打开每日推荐'),
                  onPressed: () => AdaptiveNav.openDetail<void>(
                    context,
                    (_) => const Scaffold(
                      body: Center(child: Text('每日推荐详情')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开每日推荐'));
    await tester.pumpAndSettle();

    expect(find.text('每日推荐详情'), findsOneWidget);
    expect(find.text('打开每日推荐'), findsOneWidget,
        reason: '双栏下发现页 master 仍在左栏并排显示');
    expect(tester.takeException(), isNull);
  });

  test('窗口断点仅由宽度决定', () {
    for (final width in [300.0, 500.0, 599.0]) {
      expect(getScreenType(width), ScreenType.compact);
      expect(usesNavigationRail(width), isFalse);
      expect(usesTwoPane(width), isFalse);
    }
    expect(getScreenType(600), ScreenType.medium);
    expect(getScreenType(839), ScreenType.medium);
    expect(getScreenType(840), ScreenType.expanded);
    expect(usesNavigationRail(853), isTrue);
    expect(usesTwoPane(999), isFalse);
    expect(usesTwoPane(1000), isTrue);
    expect(usesTwoPane(1280), isTrue);
    expect(kTwoPaneTabs.contains('settings'), isFalse);
    expect(kTwoPaneTabs.contains('coverflow'), isFalse);
    // 发现页已接入双栏：三个详情入口（每日推荐/刷歌/新歌）经 openDetail 进右栏。
    expect(kTwoPaneTabs.contains('discover'), isTrue);
  });

  testWidgets('限宽保留手机尺寸，宽屏内容居中', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 853);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: ContentWidth(
          child: ColoredBox(key: Key('content'), color: Colors.red),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('content'))).width,
      1280 * 0.85,
    );
    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('content'))).width, 400);
  });

  testWidgets('详情多层栈旋转降级后保留输入和返回 Future', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 853);
    addTearDown(tester.view.reset);
    final shellKey = GlobalKey<ResponsiveShellState>();
    Future<String?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          key: shellKey,
          visibleTabs: const [TabItem(id: 'favorites', label: '收藏')],
          selectedIndex: 0,
          pageBuilder: (_) => Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('打开详情'),
                onPressed: () {
                  result = AdaptiveNav.openDetail<String>(
                    context,
                    (context) => Scaffold(
                      appBar: AppBar(title: const Text('详情')),
                      body: Column(
                        children: [
                          const TextField(key: Key('input')),
                          TextButton(
                            child: const Text('下一层'),
                            onPressed: () => AdaptiveNav.openDetail(
                              context,
                              (_) => const Scaffold(body: Text('第二层')),
                            ),
                          ),
                          TextButton(
                            child: const Text('完成'),
                            onPressed: () => Navigator.of(context).pop('保留结果'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('input'))).left,
      greaterThan(300),
    );
    await tester.enterText(find.byKey(const Key('input')), '旋转保留');
    await tester.tap(find.text('下一层'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(853, 1280);
    await tester.pumpAndSettle();
    expect(find.text('第二层'), findsOneWidget);
    expect(find.text('打开详情'), findsNothing);
    expect(await shellKey.currentState!.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('旋转保留'), findsOneWidget);
    tester.view.physicalSize = const Size(1280, 853);
    await tester.pumpAndSettle();
    expect(find.text('打开详情'), findsOneWidget);
    expect(find.text('旋转保留'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(await result, '保留结果');
    expect(await shellKey.currentState!.maybePop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机 Tab 懒建保活，重排不串栈，移除后释放', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);
    final shellKey = GlobalKey<ResponsiveShellState>();
    final builds = <String, int>{};
    var tabs = const [
      TabItem(id: 'discover', label: '发现'),
      TabItem(id: 'search', label: '搜索'),
    ];
    Future<void> show(int selected) => tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          key: shellKey,
          visibleTabs: tabs,
          selectedIndex: selected,
          pageBuilder: (id) {
            return _MountProbe(
              onMount: () => builds.update(id, (v) => v + 1, ifAbsent: () => 1),
              child: Scaffold(
                body: ListView.builder(
                  key: ValueKey('list-$id'),
                  itemExtent: 60,
                  itemCount: 100,
                  itemBuilder: (_, i) => Text('$id-$i'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await show(0);
    await tester.pumpAndSettle();
    expect(builds['search'], isNull);
    await tester.drag(
      find.byKey(const ValueKey('list-discover')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    final state = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('list-discover')),
        matching: find.byType(Scrollable),
      ),
    );
    final offset = state.position.pixels;
    await show(1);
    await tester.pumpAndSettle();
    await show(0);
    await tester.pumpAndSettle();
    expect(state.position.pixels, offset);
    expect(builds['discover'], 1);
    tabs = tabs.reversed.toList();
    await show(1);
    await tester.pumpAndSettle();
    expect(state.position.pixels, offset);
    tabs = [tabs.first];
    await show(0);
    await tester.pumpAndSettle();
    expect(state.mounted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focusActiveTabContent 把焦点交还当前 tab 内容区', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final shellKey = GlobalKey<ResponsiveShellState>();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: ResponsiveShell(
            key: shellKey,
            visibleTabs: const [
              TabItem(id: 'a', label: 'A'),
              TabItem(id: 'b', label: 'B'),
            ],
            selectedIndex: 0,
            pageBuilder: (id) => Center(
              child: DpadFocusable(
                key: Key('content-$id'),
                child: const SizedBox(height: 48, width: 200),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(shellKey.currentState!.focusActiveTabContent(), isTrue);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      isNotNull,
      reason: '焦点应落在 tab a 的内容项上',
    );
    expect(
      FocusManager.instance.primaryFocus!.context,
      isNotNull,
      reason: '焦点节点挂在树上',
    );
  });
}

class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.onMount, required this.child});
  final VoidCallback onMount;
  final Widget child;
  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

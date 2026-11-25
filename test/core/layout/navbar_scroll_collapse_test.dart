import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/bottom_chrome_scope.dart';
import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 滚动跟手收起底栏（[kNavBarScrollCollapseEnabled]）的回归测试。
///
/// 断言的核心是 **1:1 跟手**：收起进度的增量恒为 `滚动位移 / 底栏槽位高`，
/// 不做阈值触发、不插缓动。另覆盖松手后的 50% 吸附、到顶复位、关闭时零影响。
///
/// 探针订阅的是 `collapseProgress` 的逐帧进度，不用 `chromeCollapseOf` 读数：
/// 后者在「坞位不存在」（横屏 rail / 已完全收起）时按设计兜底返回 1.0，会把
/// 「进度 0 + 无底栏」误报成「完全收起」，而本文件要区分的正是这两件事。
/// 页面 body 实例跨帧稳定，所以探针必须自己订阅、不能靠 InheritedWidget 重建。
class _Probe extends StatefulWidget {
  const _Probe({required this.onCollapse});

  final ValueChanged<double> onCollapse;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  Animation<double>? _progress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Animation<double>? next =
        BottomChromeScope.collapseStateOf(context).animation;
    if (identical(next, _progress)) return;
    _progress?.removeListener(_report);
    _progress = next;
    _progress?.addListener(_report);
    _report();
  }

  void _report() {
    final Animation<double>? animation = _progress;
    if (animation != null) widget.onCollapse(animation.value);
  }

  @override
  void dispose() {
    _progress?.removeListener(_report);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const Key('list'),
      itemCount: 60,
      itemExtent: 80,
      itemBuilder: (BuildContext context, int i) => SizedBox(
        height: 80,
        child: Text('row $i'),
      ),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PlayerPanelSignal.expansion.value = 0.0;
    PlayerPanelSignal.publishAnchor(top: 0, bottom: 0);
  });

  tearDown(() {
    PlayerPanelSignal.expansion.value = 0.0;
    PlayerPanelSignal.publishAnchor(top: 0, bottom: 0);
  });

  /// 手机竖屏：宽 400 < 600 → compact 分支（底栏走 NavigationBar）。
  /// padding 为 0 → 槽位高 = NavigationBar 高度 = 64（labelBehavior 默认 alwaysShow）。
  void setPhoneViewport(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
  }

  Widget host({
    required bool enabled,
    bool hideNavigation = false,
    int selectedIndex = 0,
    ValueChanged<double>? onCollapse,
    Widget? customBody,
    bool tabbedBody = false,
  }) {
    final Widget body = customBody ??
        (tabbedBody
            // 「我的收藏」等页面的结构：纵向列表装在 TabBarView（横分页器）
            // 的某一页里。分页器本身是 Viewport，会把冒泡上来的通知 depth
            // 抬成 1 —— 壳层监听按 depth 过滤就会让这类页面永远收不起底栏。
            ? Column(
                children: [
                  Expanded(
                    child: DefaultTabController(
                      length: 2,
                      child: TabBarView(
                        children: <Widget>[
                          onCollapse == null
                              ? const SizedBox.shrink()
                              : _Probe(onCollapse: onCollapse),
                          const SizedBox.shrink(),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : (onCollapse == null
                  ? const SizedBox.expand(key: Key('body'))
                  : _Probe(onCollapse: onCollapse)));
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        home: ResponsiveScaffold(
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              label: '首页',
            ),
            NavigationDestination(
              icon: Icon(Icons.search_outlined),
              label: '搜索',
            ),
          ],
          railDestinations: const <NavigationRailDestination>[
            NavigationRailDestination(
              icon: Icon(Icons.home_outlined),
              label: Text('首页'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.search_outlined),
              label: Text('搜索'),
            ),
          ],
          drawerDestinations: const <NavigationDrawerDestination>[],
          selectedIndex: selectedIndex,
          onDestinationSelected: (int _) {},
          scrollCollapseEnabled: enabled,
          hideNavigation: hideNavigation,
          body: body,
        ),
      ),
    );
  }

  testWidgets('开关关闭时滚动不推动底栏（零影响）', (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: false, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(collapse, 0.0);

    await tester.drag(find.byKey(const Key('list')), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(collapse, 0.0, reason: '关闭时滚动量不得改变收起进度');
    expect(find.byType(NavigationBar), findsOneWidget, reason: '底栏始终在场');
  });

  testWidgets('开启后上滑按位移 1:1 收起，下滑按同比例展开',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(collapse, 0.0);

    // 槽位高 = 64（padding 0）→ 上滑 16dp 应得 0.25，四步共 64dp 应得 1.0。
    // 用分步手势推进，避免 fling 的速度/惯性干扰比例断言。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    await gesture.moveBy(const Offset(0, -16));
    await tester.pump();
    expect(
      collapse,
      closeTo(16 / 64, 0.03),
      reason: '上滑 16dp 应得 0.25（1:1 跟手，无阈值）',
    );

    await gesture.moveBy(const Offset(0, -16));
    await tester.pump();
    expect(
      collapse,
      closeTo(32 / 64, 0.03),
      reason: '再上滑 16dp 累计 0.5',
    );

    await gesture.moveBy(const Offset(0, -32));
    await tester.pump();
    expect(
      collapse,
      closeTo(1.0, 0.03),
      reason: '累计上滑一个槽位高应当彻底收起',
    );

    // 反向：下滑 16dp → 进度减少 16/64 = 0.25。
    await gesture.moveBy(const Offset(0, 16));
    await tester.pump();
    expect(
      collapse,
      closeTo(0.75, 0.03),
      reason: '下滑按同一比例展开',
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('拖动中途松手按 50% 吸附：过半收起，未过半复位',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();

    // 上滑 48dp = 0.75 槽位 → 过半 → 松手后应吸附到 1.0。
    TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    for (int i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
    }
    expect(collapse, closeTo(0.75, 0.03));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(collapse, 1.0, reason: '过半应吸附到完全收起');
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: '进度到 1 后槽位必须移除（否则 body 底部会露一条空带）',
    );

    // 下滑 40dp：进度 1.0 - 40/64 = 0.375 → 未过半 → 松手吸附到 0.0。
    gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(collapse, 0.0, reason: '未过半应复位到完全展开');
    expect(find.byType(NavigationBar), findsOneWidget, reason: '底栏重新进树');
  });

  testWidgets('滚回列表顶端时底栏恒展开（到顶复位）',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();

    // 先上滑收起。
    TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    for (int i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(collapse, 1.0);

    // 一路下滑回到顶端：到顶即复位。
    gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    for (int i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(collapse, 0.0, reason: '到顶必须展开，不留在半空');
  });

  testWidgets('横屏 rail 布局不参与滚动跟手', (WidgetTester tester) async {
    // 宽 900 >= 600 → rail 分支，底栏本就是侧边 NavigationRail。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 500);
    addTearDown(tester.view.reset);

    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(collapse, 0.0);
    await tester.drag(find.byKey(const Key('list')), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(collapse, 0.0, reason: 'rail 布局无底部导航栏，滚动不参与');
  });

  testWidgets('底栏缓存不吞更新：切 tab 后选中态与高度档位照常生效',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );

    // 切到第 2 个 tab：缓存键里的 selectedIndex 变了，必须重建出新的底栏。
    await tester.pumpWidget(
      host(enabled: true, selectedIndex: 1, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
      reason: '缓存必须按 selectedIndex 失效，否则切 tab 后底栏停在旧选中态',
    );
  });

  testWidgets('滚动跟手期间底栏 widget 实例跨帧复用（缓存生效）',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();

    final TestGesture g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    int? firstHash;
    int changes = 0;
    for (int i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, -8));
      await tester.pump();
      final int h = identityHashCode(
        tester.widget<NavigationBar>(find.byType(NavigationBar)),
      );
      if (firstHash == null) {
        firstHash = h;
      } else if (h != firstHash) {
        changes++;
      }
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(
      changes,
      0,
      reason: '跟手期间底栏必须复用同一 widget 实例（否则每帧重建底栏子树，'
          '实测 8.6ms/帧）',
    );
    expect(collapse, greaterThan(0.0));
  });

  testWidgets('收起中进二级页再返回：滚动那一位不复活（合并进度不残留）',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    // 1) 先滚动收起底栏。
    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    for (int i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(collapse, 1.0);

    // 2) 进二级页（hideNavigation 翻 true）→ 返回一级页。
    await tester.pumpWidget(
      host(
        enabled: true,
        hideNavigation: true,
        onCollapse: (double v) => collapse = v,
      ),
    );
    await tester.pumpAndSettle();
    expect(collapse, 1.0, reason: '二级页转场收起，底栏仍应完全隐藏');

    await tester.pumpWidget(
      host(enabled: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(
      collapse,
      0.0,
      reason: '回到一级页时滚动那一位必须已复位，否则合并取大让底栏留在收起态',
    );
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('TabBarView 页面内列表上滑按位移跟手收起（收藏页结构）',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    await tester.pumpWidget(
      host(enabled: true, tabbedBody: true, onCollapse: (double v) => collapse = v),
    );
    await tester.pumpAndSettle();
    expect(collapse, 0.0);

    // 与裸 ListView 同口径（槽位高 64）：四步上滑共 64dp 应得 1.0。
    // 修复前 TabBarView 的分页视口会把通知 depth 抬成 1 被壳层拦下，进度恒 0。
    // 分页器的拖拽竞技场逐帧解析，通知比手势晚一帧到 —— 步进后先统一收尾，
    // 不逐步断言（避免把帧延迟误判成换算偏差）。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('list'))),
    );
    for (int i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      collapse,
      closeTo(1.0, 0.03),
      reason: 'TabBarView 内列表的纵向滚动量必须同样换算成收起进度（1:1）',
    );
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: '进度到 1 后槽位移除',
    );
  });

  testWidgets('嵌套横向轮播滚动不推动底栏（原过滤意图保留）',
      (WidgetTester tester) async {
    setPhoneViewport(tester);
    double collapse = -1;
    // 列表里嵌一条横向轮播：拖它（通知轴为横向）不应推动底栏。
    await tester.pumpWidget(
      host(
        enabled: true,
        // 列表里嵌一条横向轮播：拖它（通知轴为横向）不应推动底栏。
        customBody: Column(
          children: [
            SizedBox(
              height: 200,
              child: SingleChildScrollView(
                key: const Key('carousel'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < 12; i++)
                      SizedBox(
                        width: 160,
                        child: Center(child: Text('car $i')),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _Probe(onCollapse: (double v) => collapse = v),
            ),
          ],
        ),
        onCollapse: (double v) => collapse = v,
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('carousel')), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(collapse, 0.0, reason: '横向轴的滚动通知被拦下，底栏不得动');
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
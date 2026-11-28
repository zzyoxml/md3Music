import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/bottom_chrome_scope.dart';
import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/modules/player/player_panel_frame.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 探测宿主：把 body 底部的实际边界与 scope 上报的收起进度同时暴露出来。
class _Probe extends StatelessWidget {
  const _Probe({required this.onCollapse});

  final ValueChanged<double> onCollapse;

  @override
  Widget build(BuildContext context) {
    onCollapse(BottomChromeScope.chromeCollapseOf(context));
    return const SizedBox.expand(key: Key('body'));
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

  /// 手机竖屏：最短边 400 < 600 → 紧凑布局（底栏走 NavigationBar 分支）。
  /// `tester.view.padding` 保持 0 → 槽位高 = NavigationBar 高度 = 64（labelBehavior
  /// 默认 alwaysShow）。
  void setPhoneViewport(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
  }

  Widget host({
    required bool hideNavigation,
    ValueChanged<double>? onCollapse,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        home: ResponsiveScaffold(
          destinations: const <NavigationDestination>[
            NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
            NavigationDestination(icon: Icon(Icons.search_outlined), label: '搜索'),
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
          selectedIndex: 0,
          onDestinationSelected: (int _) {},
          hideNavigation: hideNavigation,
          body: onCollapse == null
              ? const SizedBox.expand(key: Key('body'))
              : _Probe(onCollapse: onCollapse),
        ),
      ),
    );
  }

  testWidgets('收起是逐帧过渡：中途底栏仍在树里，结束后才移除槽位', (WidgetTester tester) async {
    setPhoneViewport(tester);
    await tester.pumpWidget(host(hideNavigation: false));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    final double bodyVisible =
        tester.getSize(find.byKey(const Key('body'))).height;

    await tester.pumpWidget(host(hideNavigation: true));
    // 第一帧：动画刚起步。旧实现在这里已经是 null —— 一帧瞬移就是本计划要修的病。
    await tester.pump();
    expect(
      find.byType(NavigationBar),
      findsOneWidget,
      reason: '底栏不能在转场第一帧就消失',
    );

    await tester.pump(const Duration(milliseconds: 130));
    expect(find.byType(NavigationBar), findsOneWidget);
    final double bodyMid = tester.getSize(find.byKey(const Key('body'))).height;
    expect(bodyMid, greaterThan(bodyVisible), reason: '槽位在收缩，body 必须让出空间');

    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    final double bodyHidden =
        tester.getSize(find.byKey(const Key('body'))).height;
    expect(bodyHidden, greaterThan(bodyMid));
    expect(
      bodyHidden - bodyVisible,
      closeTo(64, 0.5),
      reason: '底栏让出的空间 = 槽位高（本例无手势条净空）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回一级页面时逐帧恢复，结束后底栏与 body 高度回到原位', (WidgetTester tester) async {
    setPhoneViewport(tester);
    await tester.pumpWidget(host(hideNavigation: true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    final double bodyHidden =
        tester.getSize(find.byKey(const Key('body'))).height;

    await tester.pumpWidget(host(hideNavigation: false));
    await tester.pump();
    expect(
      find.byType(NavigationBar),
      findsOneWidget,
      reason: '恢复方向同样要逐帧：第一帧底栏就应该已经重新进树（高度接近 0）',
    );
    await tester.pump(const Duration(milliseconds: 130));
    final double bodyMid = tester.getSize(find.byKey(const Key('body'))).height;
    expect(bodyMid, lessThan(bodyHidden));

    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('body'))).height,
      closeTo(bodyHidden - 64, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('中途上报 0 < collapse < 1，两端精确落 0 / 1', (WidgetTester tester) async {
    setPhoneViewport(tester);
    double last = -1;
    await tester.pumpWidget(
      host(hideNavigation: false, onCollapse: (double v) => last = v),
    );
    await tester.pumpAndSettle();
    expect(last, 0.0);

    await tester.pumpWidget(
      host(hideNavigation: true, onCollapse: (double v) => last = v),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    expect(last, greaterThan(0.0));
    expect(last, lessThan(1.0));

    await tester.pumpAndSettle();
    expect(last, 1.0);
  });

  testWidgets('系统减弱动态效果：直接落端点，不播动画', (WidgetTester tester) async {
    setPhoneViewport(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(host(hideNavigation: false));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pumpWidget(host(hideNavigation: true));
    await tester.pump();
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: '减弱动效下必须一帧到位，不能留 260ms 的过渡',
    );
  });

  testWidgets('展开播放页：底栏顶边逐帧与面板下沿重合，不留缝、不压扁', (WidgetTester tester) async {
    setPhoneViewport(tester);
    await tester.pumpWidget(host(hideNavigation: false));
    await tester.pumpAndSettle();

    // 持久条形态的真实锚点：迷你条贴在底栏上方（底端 = 屏高 − 槽位高）。
    const double screen = 800;
    const double slot = 64; // NavigationBar 默认 labelBehavior → 64，无手势条净空
    const double miniHeight = 72;
    final double miniTop = screen - slot - miniHeight;
    PlayerPanelSignal.publishAnchor(top: miniTop, bottom: screen - slot);

    for (final double p in <double>[0.25, 0.5, 0.75]) {
      PlayerPanelSignal.expansion.value = p;
      await tester.pump();

      final g = playerPanelGeometry(
        progress: p,
        origin: miniTop,
        miniHeight: miniHeight,
        screenHeight: screen,
      );
      final double panelBottom = g.top + g.height;
      expect(
        tester.getTopLeft(find.byType(NavigationBar)).dy,
        closeTo(panelBottom, 0.5),
        reason: '底栏顶边必须与面板下沿重合（p=$p），中间不能露出底色空带',
      );
      expect(
        tester.getSize(find.byType(NavigationBar)).height,
        closeTo(slot, 0.5),
        reason: '下沉而不是压扁',
      );
    }

    PlayerPanelSignal.expansion.value = 0.0;
    await tester.pump();
    expect(
      tester.getTopLeft(find.byType(NavigationBar)).dy,
      closeTo(screen - slot, 0.5),
      reason: '收起播放页后底栏必须完全回到原位',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('二级页面（底栏已收起）时面板下沉为 no-op', (WidgetTester tester) async {
    setPhoneViewport(tester);
    PlayerPanelSignal.publishAnchor(top: 600, bottom: 700);
    PlayerPanelSignal.expansion.value = 0.5;

    await tester.pumpWidget(host(hideNavigation: true));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

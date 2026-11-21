import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

// 横屏 NavigationRail 滑出动画的布局回归（900x600 = rail 布局区间）：
// 1) rail 在场：槽位总宽（rail + divider）= 满宽，布局不崩；
// 2) hideRailNavigation 翻转：中途帧逐帧收缩（非硬切），收敛后槽位归零、
//    rail 进入 Offstage（保 state）；
// 3) 恢复显示：槽位回到满宽，NavigationRail 仍在树中。
//
// 量法：ResponsiveScaffold.body 放一个带 key 的全宽探针，槽位总宽 =
// 视口宽 − body 宽。
void main() {
  const destinations = [
    NavigationDestination(icon: Icon(Icons.explore), label: '发现'),
    NavigationDestination(icon: Icon(Icons.favorite), label: '喜欢'),
  ];
  const railDestinations = [
    NavigationRailDestination(icon: Icon(Icons.explore), label: Text('发现')),
    NavigationRailDestination(icon: Icon(Icons.favorite), label: Text('喜欢')),
  ];
  const drawerDestinations = [
    NavigationDrawerDestination(icon: Icon(Icons.explore), label: Text('发现')),
  ];

  final hideRail = ValueNotifier<bool>(false);
  final bodyKey = GlobalKey();

  // 槽位总宽（rail + divider）
  double slotWidth(WidgetTester tester) {
    final double viewport =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final RenderBox body =
        bodyKey.currentContext!.findRenderObject() as RenderBox;
    return viewport - body.size.width;
  }

  Widget host() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: ValueListenableBuilder<bool>(
        valueListenable: hideRail,
        builder: (context, hide, _) => MaterialApp(
          theme: ThemeData(
            navigationBarTheme: const NavigationBarThemeData(
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            ),
          ),
          home: Scaffold(
            body: ResponsiveScaffold(
              destinations: destinations,
              railDestinations: railDestinations,
              drawerDestinations: drawerDestinations,
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              hideRailNavigation: hide,
              body: SizedBox.expand(key: bodyKey),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    hideRail.value = false;
  });

  testWidgets('rail 在场：布局不崩、槽位满宽（80 rail + 1 divider）',
      (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    // 满宽 = rail 实测宽（M3 带 label 96）+ divider 1，放宽匹配
    expect(slotWidth(tester), inInclusiveRange(90, 100));
  });

  testWidgets('hideRail 翻转：中途帧逐帧收缩、收敛归零、rail Offstage',
      (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    hideRail.value = true;

    final widths = <double>[];
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      widths.add(slotWidth(tester));
    }
    await tester.pumpAndSettle();
    final settled = slotWidth(tester);

    // 中途帧单调不增（滑出方向），且最后一帧仍大于收敛值（说明是逐帧动画而非硬切）
    for (int i = 1; i < widths.length; i++) {
      expect(widths[i], lessThanOrEqualTo(widths[i - 1] + 0.01));
    }
    expect(widths.last, greaterThan(settled + 0.01));
    // 收敛后 rail + divider 全部让位
    expect(settled, lessThan(0.5));
    // 滑出完成后 rail 进 Offstage 省绘制（state 保持）
    expect(
      find.byWidgetPredicate((w) => w is Offstage && w.offstage),
      findsWidgets,
    );
    expect(find.byType(NavigationRail), findsNothing); // Offstage 下 find 跳过
  });

  testWidgets('恢复显示：槽位回到满宽、rail 回树', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    hideRail.value = true;
    await tester.pumpAndSettle();
    expect(slotWidth(tester), lessThan(0.5));

    hideRail.value = false;
    await tester.pumpAndSettle();
    expect(slotWidth(tester), inInclusiveRange(90, 100));
    expect(find.byType(NavigationRail), findsOneWidget);
  });
}

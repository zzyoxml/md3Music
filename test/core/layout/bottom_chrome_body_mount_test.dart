import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/bottom_chrome_scope.dart';
import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/providers/theme_provider.dart';

/// body 子树的挂载探针：`initState` 每被叫一次就意味着 body 被卸载重建了一次。
///
/// 为什么要钉这个：常驻播放条挂在 `ResponsiveScaffold` 的 body 里（`app.dart`
/// 的 `_buildBody`）。body 槽位上的 widget 类型一旦在转场两端发生变化
/// （裸 body ↔ `MediaQuery(child: body)`），`Element.updateChild` 的 canUpdate
/// 判据不成立，整棵 body 会被 deactivate 再重新 inflate —— 播放条的 State 被销毁，
/// 封面 `Image` 从零重新解析：一帧空白 + 重播淡入。真机反馈的
/// 「进二级页底栏收起、播放条下沉/抬起时封面闪烁」就是这个。
class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.onMount, required this.onCollapse});

  final VoidCallback onMount;
  final ValueChanged<double> onCollapse;

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
  Widget build(BuildContext context) {
    widget.onCollapse(BottomChromeScope.chromeCollapseOf(context));
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

  Widget host({
    required bool hideNavigation,
    required Widget body,
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
          body: body,
        ),
      ),
    );
  }

  /// 竖屏 + 非 0 手势条净空：这是 `_withAnimatedBottomInset` 会介入的前提
  /// （inset 为 0 时它直接返回裸 body，两端也就没有类型可换）。
  void setPhoneViewportWithGestureBar(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.padding = const FakeViewPadding(bottom: 20);
    addTearDown(tester.view.reset);
  }

  testWidgets('底栏收起/展开全程 body 子树必须持续挂载（不重建播放条）', (tester) async {
    setPhoneViewportWithGestureBar(tester);

    var mounts = 0;
    var lastCollapse = -1.0;
    Widget tree(bool hideNavigation) => host(
      hideNavigation: hideNavigation,
      body: _MountProbe(
        onMount: () => mounts++,
        onCollapse: (double v) => lastCollapse = v,
      ),
    );

    await tester.pumpWidget(tree(false));
    await tester.pumpAndSettle();
    expect(mounts, 1, reason: '起手只挂载一次');
    expect(lastCollapse, 0.0);

    // 进二级页：底栏逐帧收起
    await tester.pumpWidget(tree(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(lastCollapse, greaterThan(0.0));
    expect(
      mounts,
      1,
      reason: '转场起步帧不能把 body 槽位从裸 body 换成 MediaQuery 包装（会重建整棵 body）',
    );

    await tester.pump(const Duration(milliseconds: 130));
    expect(mounts, 1, reason: '转场中途不能重建 body');

    await tester.pumpAndSettle();
    expect(lastCollapse, 1.0);
    expect(
      mounts,
      1,
      reason: '收起结束（槽位移除）这一端同样不能换回裸 body',
    );

    // 返回一级页：逐帧恢复，两端再来一次
    await tester.pumpWidget(tree(false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pumpAndSettle();
    expect(mounts, 1, reason: '恢复方向（抬起）也不能重建 body');
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

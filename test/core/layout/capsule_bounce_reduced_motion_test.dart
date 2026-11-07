import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 底部导航胶囊回弹 `_CapsuleBounce` 的 reduced-motion 代表性用例（计划 §1.3 矩阵）。
///
/// `_CapsuleBounce` 是 `responsive_layout.dart` 的私有 StatefulWidget，测试无法直接
/// pump 它，只能经**公开** [ResponsiveScaffold] 的竖屏 NavigationBar 路径触发
/// （每个 tab 的 icon 外包一枚 `_CapsuleBounce`）。
///
/// 可观测点：胶囊的水平缩放由 `Transform.scale(scaleX: _controller.value,
/// alignment: center)` 表达，是 NavigationBar 子树里唯一**横向拉宽**
/// （scaleX > scaleY，且冲过 1.0）的 Transform —— M3 自身的选中态用尺寸 / 平移 / 等比
/// 缩放，material_ui 的选中指示器只用「仅 X 轴的收窄到 0」，都不会把 scaleX 拉过 1.0。
/// 据此用「是否存在横向拉伸（scaleX > scaleY）的 Transform」判定 bounce 是否发生：
/// - 正常动效：点击已选中项走 _handleDestinationSelected → playBounce，
///   `_controller.value` 冲过 1.0（animateTo 1.2 / 80ms）→ 出现非等比拉伸；
/// - reduced-motion（disableAnimations=true）：playBounce 直接落终态 1.0、不播弹簧，
///   全程**不出现任何非等比拉伸**（瞬时落位、无中间帧）。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 竖屏（宽 400 < 600 → compact）用 NavigationBar，两个 tab 各包一枚胶囊。
  /// [disable] 决定祖先 [MediaQuery] 的 disableAnimations；[selected] 为初始选中项
  /// （用例点击该已选中项，走 _handleDestinationSelected → playBounce，选中态不变，
  /// 不触发 M3 选中指示器平移）。
  Widget scaffold({required int selected, required bool disable}) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: disable),
            child: ResponsiveScaffold(
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
              selectedIndex: selected,
              onDestinationSelected: (_) {},
              body: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  /// NavigationBar 子树里是否存在**横向拉伸**的 Transform（scaleX 明显大于 scaleY）。
  /// 只认「拉宽」（scaleX > scaleY）：material_ui 的 NavigationBar 自身会给每个目的
  /// 地的选中指示器套一层仅 X 轴的缩放（未选中时 `Matrix4.diagonal3Values(0, 1, 1)`
  /// 即 scaleX=0），那是「收窄到不可见」，与胶囊回弹的「冲过 1.0 的拉伸」无关，须排除。
  bool hasHorizontalStretch(WidgetTester tester) {
    final widgets = tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(Transform),
      ),
    );
    for (final t in widgets) {
      final s = t.transform.storage;
      if (s[0] - s[5] > 1e-3) return true;
    }
    return false;
  }

  testWidgets('正常动效（对照）：点击已选中项时胶囊出现水平回弹（scaleX 冲过 1.0）', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(scaffold(selected: 0, disable: false));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    // 点击**已选中**的 tab 0：走 _handleDestinationSelected → playBounce（选中态不变，
    // 不触发 M3 选中指示器平移；ink 涟漪是等比缩放，被非等比过滤排除）。
    await tester.tap(find.byIcon(Icons.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40)); // 拉伸段中途（animateTo 1.2/80ms）

    expect(
      hasHorizontalStretch(tester),
      isTrue,
      reason: '对照基线：正常动效下胶囊必须横向拉伸（scaleX 偏离 1.0），'
          '否则 reduced-motion 那条“无拉伸”断言就失去区分力',
    );

    // 点击会经 _hapticSelection → AppHaptics 起一个 300ms 兜底 watchdog；
    // 测试环境平台通道不响应，需推进过该时长让它自然落地，否则销毁时
    // 残留定时器会被框架判为 "A Timer is still pending"。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced-motion：点击已选中项时胶囊瞬时落终态，全程无水平回弹/无中间帧', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(scaffold(selected: 0, disable: true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.byIcon(Icons.home));
    await tester.pump();

    // 逐段推进 fake 时钟：reduced-motion 下 playBounce 直接落位（值本已 1.0 连赋值
    // 都不做），任何时刻都不该出现中间帧的横向拉伸。多档时长覆盖整条 bounce 时间轴。
    for (final ms in <int>[0, 40, 80, 120, 200]) {
      await tester.pump(Duration(milliseconds: ms));
      expect(
        hasHorizontalStretch(tester),
        isFalse,
        reason: 'disableAnimations 下胶囊跳过整段回弹，不应有任何横向拉伸帧（累计 ${ms}ms 处）',
      );
    }

    await tester.pumpWidget(const SizedBox());
  });
}

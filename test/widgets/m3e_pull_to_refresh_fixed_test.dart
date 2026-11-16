// 只导入 material_ui：`AxisDirection`(painting) / `DragStartDetails`(gestures) /
// `FixedScrollMetrics`(widgets) 等均由它转出的 widgets 层提供，无需再显式导入
// 这几个 flutter 子库（否则会触发 unnecessary_import）。
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/m3e_pull_to_refresh_fixed.dart';

void main() {
  testWidgets('dragDetails 为 null 的 Overscroll 不应提前结束拖拽', (tester) async {
    final controller = M3EPullToRefreshController();
    final childKey = GlobalKey();

    await tester.pumpWidget(MaterialApp(
      home: M3EPullToRefreshIndicator(
        controller: controller,
        onRefresh: () async {},
        child: SizedBox(key: childKey, height: 10),
      ),
    ));

    final ctx = childKey.currentContext!;
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0.0,
      maxScrollExtent: 100.0,
      pixels: 0.0,
      viewportDimension: 400.0,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1.0,
    );

    ScrollStartNotification(
      metrics: metrics,
      context: ctx,
      dragDetails: DragStartDetails(),
    ).dispatch(ctx);
    await tester.pump();

    OverscrollNotification(
      metrics: metrics,
      context: ctx,
      overscroll: -100.0,
      dragDetails: null,
    ).dispatch(ctx);
    await tester.pump();

    expect(
      controller.distanceFraction,
      greaterThan(0.0),
      reason: 'dragDetails 为 null 的 Overscroll 必须被忽略、拖拽距离继续累积；'
          '上游原实现会在此提前结束拖拽（distanceFraction 停在 0）',
    );
  });

  /// 用 TestPointer.scroll 派发鼠标滚轮事件（与 coverflow_wheel_test 同口径：
  /// sendEventToBinding 是 guarded API，必须 await）。
  Future<void> sendWheel(
    WidgetTester tester,
    Offset center,
    double dy,
  ) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(center);
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pump();
  }

  testWidgets('顶部滚轮向下应拉出指示器（鼠标滚轮路径）', (tester) async {
    final controller = M3EPullToRefreshController();

    await tester.pumpWidget(MaterialApp(
      home: M3EPullToRefreshIndicator(
        controller: controller,
        onRefresh: () async {},
        child: ListView.builder(
          itemCount: 50,
          itemBuilder: (_, i) => SizedBox(height: 56, child: Text('item $i')),
        ),
      ),
    ));

    await sendWheel(tester, tester.getCenter(find.byType(ListView)), -120.0);

    expect(
      controller.distanceFraction,
      greaterThan(0.0),
      reason: 'pointerScroll 在列表顶部不派发滚动通知且 dragDetails 恒为 null，'
          '必须由 Listener 拦截 PointerScrollEvent 才能拉出指示器',
    );
  });

  testWidgets('滚轮累积超阈值 + 空闲判停后应触发刷新', (tester) async {
    var refreshed = false;
    final controller = M3EPullToRefreshController();

    await tester.pumpWidget(MaterialApp(
      home: M3EPullToRefreshIndicator(
        controller: controller,
        onRefresh: () async => refreshed = true,
        child: ListView.builder(
          itemCount: 50,
          itemBuilder: (_, i) => SizedBox(height: 56, child: Text('item $i')),
        ),
      ),
    ));

    final center = tester.getCenter(find.byType(ListView));
    // 默认 triggerDistance 80、dragResistance 0.55：两格 120 足够超阈值。
    await sendWheel(tester, center, -120.0);
    await sendWheel(tester, center, -120.0);
    expect(controller.distanceFraction, greaterThanOrEqualTo(1.0));

    // 推过空闲判停（200ms）+ 回弹/刷新动画。
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 600));

    expect(refreshed, isTrue);
  });

  testWidgets('滚轮未达阈值 + 空闲判停后应回弹', (tester) async {
    var refreshed = false;
    final controller = M3EPullToRefreshController();

    await tester.pumpWidget(MaterialApp(
      home: M3EPullToRefreshIndicator(
        controller: controller,
        onRefresh: () async => refreshed = true,
        child: ListView.builder(
          itemCount: 50,
          itemBuilder: (_, i) => SizedBox(height: 56, child: Text('item $i')),
        ),
      ),
    ));

    final center = tester.getCenter(find.byType(ListView));
    // 一格 120 * 0.55 = 66 < 80（triggerDistance），不触发。
    await sendWheel(tester, center, -120.0);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 600));

    expect(refreshed, isFalse);
    // 弹簧收敛后可能有 1e-15 级浮点残差，用近零容差断言。
    expect(controller.distanceFraction, lessThan(0.001),
        reason: '未达阈值时停轮应回弹到 0');
  });
}

// 只导入 material_ui：`AxisDirection`(painting) / `DragStartDetails`(gestures) /
// `FixedScrollMetrics`(widgets) 等均由它转出的 widgets 层提供，无需再显式导入
// 这几个 flutter 子库（否则会触发 unnecessary_import）。
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
}

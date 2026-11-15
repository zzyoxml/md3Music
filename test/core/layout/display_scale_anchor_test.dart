import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/ui_density.dart';

/// DisplayScaleScope 锚点暴露单测（形变对齐修复 Task 1）。
///
/// 锚点空间 = 设计像素：s≠1 时探针/顶端一律变换到锚点而非根，
/// 否则量得窗口像素再画进设计空间会整体偏 s 倍。
void main() {
  testWidgets('DisplayScaleScope 暴露锚点：锚点空间矩形 = 设计像素', (
    tester,
  ) async {
    BuildContext? inner;
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayScaleScope(
          scale: 0.9,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 100,
              child: Builder(
                builder: (context) {
                  inner = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );
    // 首帧 build 时锚点 RenderObject 未 mount，锚点组件在 post-frame 回填并
    // setState 触发第二帧；再 pump 一次让 DisplayScaleReference 挂进子树。
    await tester.pump();
    final anchor = DisplayScaleReference.anchorOf(inner!);
    expect(anchor, isNotNull);
    final box = inner!.findRenderObject()! as RenderBox;
    // 锚点空间（设计像素）：不受 FittedBox ×0.9 影响，仍是 200×100。
    expect(
      MatrixUtils.transformRect(box.getTransformTo(anchor), Offset.zero & box.size),
      const Rect.fromLTWH(0, 0, 200, 100),
    );
    // 对照：变换到根（窗口空间）被 ×0.9 —— 证明锚点空间确实不同于根空间。
    final windowRect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    expect(windowRect.width, closeTo(180, 0.5));
  });

  testWidgets('无 DisplayScaleScope 时 anchorOf 返回 null（回退根空间）', (
    tester,
  ) async {
    BuildContext? inner;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            inner = context;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(DisplayScaleReference.anchorOf(inner!), isNull);
  });
}

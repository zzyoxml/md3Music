import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/display_space.dart';
import 'package:md3music/core/layout/ui_density.dart';

/// 拖拽手势坐标换算单测（形变对齐修复 Task 4 追加）。
///
/// Listener 原始指针事件 / DragUpdateDetails.globalPosition 是**窗口（根）
/// 坐标**，而距离分母（_miniTopY）、MediaQuery 屏高、路由位移都在
/// DisplayScaleScope 的**设计像素**空间；混用会让跟手进度偏 s²。
/// toDisplaySpace 把窗口坐标除以实测缩放比回到设计像素，无锚点时原样返回。
void main() {
  testWidgets('1.1 档：窗口坐标点换算到设计像素（除以 s）', (tester) async {
    late BuildContext inner;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => DisplayScaleScope(
          scale: 1.1,
          child: Builder(
            builder: (context) {
              inner = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    // 锚点 ≡ MediaQuery 空间：换算结果必须等于窗口值 ÷ 1.1
    final converted = toDisplaySpace(inner, const Offset(110, 220));
    expect(converted.dx, closeTo(100, 0.5));
    expect(converted.dy, closeTo(200, 0.5));
    expect(MediaQuery.sizeOf(inner).width, closeTo(800 / 1.1, 0.5));
  });

  testWidgets('无 DisplayScaleScope 时原样返回（回退根空间）', (tester) async {
    late BuildContext inner;
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
    expect(
      toDisplaySpace(inner, const Offset(110, 220)),
      const Offset(110, 220),
    );
    expect(
      toDisplaySpaceDelta(inner, const Offset(11, 22)),
      const Offset(11, 22),
    );
  });
}

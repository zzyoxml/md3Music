import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/bottom_chrome_sink.dart';

/// 底栏槽位的两条硬约束（问题 1 的观感全押在它们上）：
/// 1. 槽位高度随收起进度收缩 —— 这是 body（及其底部播放条）连续下移的唯一来源；
/// 2. 底栏本体**整体下沉、不被压扁** —— 高度不变，超出槽位的部分被裁掉。
void main() {
  Future<void> pumpSlot(WidgetTester tester, double collapse) {
    return tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            const Spacer(),
            BottomChromeSlot(
              collapse: collapse,
              slotHeight: 80,
              child: const SizedBox(key: Key('bar'), height: 80, width: 400),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('collapse = 0：槽位等于底栏完整高度，底栏顶边与槽位顶边重合', (WidgetTester tester) async {
    await pumpSlot(tester, 0.0);
    expect(tester.getSize(find.byType(BottomChromeSlot)).height, closeTo(80, 0.5));
    expect(
      tester.getTopLeft(find.byKey(const Key('bar'))).dy,
      closeTo(tester.getTopLeft(find.byType(BottomChromeSlot)).dy, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse = 0.5：槽位高度减半、底栏整体下移 40 且不被压扁', (WidgetTester tester) async {
    await pumpSlot(tester, 0.0);
    final double baseTop = tester.getTopLeft(find.byKey(const Key('bar'))).dy;

    await pumpSlot(tester, 0.5);
    expect(tester.getSize(find.byType(BottomChromeSlot)).height, closeTo(40, 0.5));
    expect(
      tester.getTopLeft(find.byKey(const Key('bar'))).dy,
      closeTo(baseTop + 40, 0.5),
      reason: '底栏必须跟着槽位顶边整体下沉',
    );
    expect(
      tester.getSize(find.byKey(const Key('bar'))).height,
      closeTo(80, 0.5),
      reason: '下沉而不是压扁：本体高度恒定，超出槽位的部分由屏幕底边裁掉',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse 越界被钳制：≥1 时槽位高度为 0，≤0 时等于完整高度', (WidgetTester tester) async {
    await pumpSlot(tester, 2.0);
    expect(tester.getSize(find.byType(BottomChromeSlot)).height, 0);

    await pumpSlot(tester, -1.0);
    expect(tester.getSize(find.byType(BottomChromeSlot)).height, closeTo(80, 0.5));
  });
}

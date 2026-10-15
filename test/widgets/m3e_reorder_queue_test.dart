import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('水平滑动超过阈值触发 onDismiss', (tester) async {
    final List<int> dismissed = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: M3EReorderableDismissibleList(
            itemCount: 3,
            keyBuilder: (index) => ValueKey('item_$index'),
            onReorder: (oldIndex, newIndex) {},
            onDismiss: (index, direction) async {
              dismissed.add(index);
              return true;
            },
            itemBuilder: (context, index) => SizedBox(
              height: 64,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Item $index'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 向右拖动远超阈值（默认 dismissThreshold = 0.2 × 卡片宽度）。
    // 先小幅越界移动触发 dragStart（该次移动不会被当作 update 派发），
    // 再继续位移，最后抬手触发 dismiss 判定。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Item 0')),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, <int>[0], reason: '滑过阈值后应以被滑项的索引回调 onDismiss');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('direction 为 none 时水平滑动不触发 onDismiss', (tester) async {
    final List<int> dismissed = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: M3EReorderableDismissibleList(
            itemCount: 3,
            keyBuilder: (index) => ValueKey('item_$index'),
            onReorder: (oldIndex, newIndex) {},
            // 刻意保留回调：用来证明「禁用与否」取决于 direction，而不是回调在不在
            onDismiss: (index, direction) async {
              dismissed.add(index);
              return true;
            },
            style: const M3EDismissibleCardStyle(
              // 上游实现是 onDismissCallback?.call(...) ?? true，
              // 不传回调等于默认放行；禁用滑动必须靠 direction
              direction: DismissDirection.none,
            ),
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

    // 沿水平方向大幅拖动并抬手（幅度远超默认阈值 0.2 × 宽度）
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Item 0')),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isEmpty, reason: 'direction 为 none 时滑动不得触发删除');
    expect(find.text('Item 0'), findsOneWidget, reason: '条目必须仍在列表中');
  });

  testWidgets('direction 为 startToEnd 时只有从左向右滑动才触发 onDismiss', (tester) async {
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
            style: const M3EDismissibleCardStyle(
              // 播放队列的配置：只允许从左向右滑删，反向不响应
              direction: DismissDirection.startToEnd,
            ),
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

    // ① 反向（从右向左）大幅滑动：不得删除
    var gesture = await tester.startGesture(
      tester.getCenter(find.text('Item 0')),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isEmpty, reason: 'startToEnd 下从右向左滑动不得删除');
    expect(find.text('Item 0'), findsOneWidget, reason: '反向滑动后条目必须仍在');

    // ② 正向（从左向右）大幅滑动：应删除
    gesture = await tester.startGesture(tester.getCenter(find.text('Item 0')));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, <int>[0], reason: 'startToEnd 下从左向右滑过阈值应删除');
  });
}

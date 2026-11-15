// 竖向邻居挤压按钮组测试。
//
// 覆盖两层：
// 1) applyVerticalSquish —— 挤压数学，必须**总高守恒**（组没有外层固定高度，
//    Column 高度由子项求和决定，漂一点弹窗就会随按压长高一截）；
// 2) M3EVerticalSquishGroup —— 渲染数量、选中回调、按下时邻项真的变矮。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import 'package:md3music/widgets/m3e_vertical_squish_group.dart';

void main() {
  group('applyVerticalSquish', () {
    test('未按下时原样返回', () {
      final heights = [40.0, 40.0, 40.0];
      expect(
        applyVerticalSquish(
          naturalHeights: heights,
          pressedIndex: null,
          progress: 1.0,
          expandedRatio: 0.15,
        ),
        heights,
      );
    });

    test('按下中间项：自己涨 6，上下各让 3，总高守恒', () {
      final sizes = applyVerticalSquish(
        naturalHeights: [40.0, 40.0, 40.0],
        pressedIndex: 1,
        progress: 1.0,
        expandedRatio: 0.15,
      );
      expect(sizes[0], closeTo(37.0, 1e-9));
      expect(sizes[1], closeTo(46.0, 1e-9));
      expect(sizes[2], closeTo(37.0, 1e-9));
      expect(sizes.reduce((a, b) => a + b), closeTo(120.0, 1e-9));
    });

    test('按下首项：全部增量让给下一项，总高守恒', () {
      final sizes = applyVerticalSquish(
        naturalHeights: [40.0, 40.0],
        pressedIndex: 0,
        progress: 1.0,
        expandedRatio: 0.15,
      );
      expect(sizes[0], closeTo(46.0, 1e-9));
      expect(sizes[1], closeTo(34.0, 1e-9));
      expect(sizes.reduce((a, b) => a + b), closeTo(80.0, 1e-9));
    });

    test('按下末项：全部增量让给上一项，总高守恒', () {
      final sizes = applyVerticalSquish(
        naturalHeights: [40.0, 40.0],
        pressedIndex: 1,
        progress: 1.0,
        expandedRatio: 0.15,
      );
      expect(sizes[0], closeTo(34.0, 1e-9));
      expect(sizes[1], closeTo(46.0, 1e-9));
      expect(sizes.reduce((a, b) => a + b), closeTo(80.0, 1e-9));
    });

    test('单项：只涨不挤', () {
      final sizes = applyVerticalSquish(
        naturalHeights: [40.0],
        pressedIndex: 0,
        progress: 1.0,
        expandedRatio: 0.15,
      );
      expect(sizes.single, closeTo(46.0, 1e-9));
    });

    test('progress=0 时不动', () {
      final sizes = applyVerticalSquish(
        naturalHeights: [40.0, 40.0, 40.0],
        pressedIndex: 1,
        progress: 0.0,
        expandedRatio: 0.15,
      );
      expect(sizes, [40.0, 40.0, 40.0]);
    });

    test('越界索引被忽略', () {
      expect(
        applyVerticalSquish(
          naturalHeights: [40.0, 40.0],
          pressedIndex: 5,
          progress: 1.0,
          expandedRatio: 0.15,
        ),
        [40.0, 40.0],
      );
    });
  });

  group('M3EVerticalSquishGroup', () {
    Widget host({
      required List<String> labels,
      int? selectedIndex,
      ValueChanged<int?>? onSelected,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: M3EVerticalSquishGroup(
                actions: [
                  for (final l in labels) M3EToggleButtonGroupAction(label: Text(l)),
                ],
                selectedIndex: selectedIndex,
                onSelectedIndexChanged: onSelected,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('按 label 数量渲染同样多的 m3e 按钮', (tester) async {
      await tester.pumpWidget(host(labels: ['标准', '高品质', '无损']));
      await tester.pumpAndSettle();

      expect(find.byType(M3EToggleButton), findsNWidgets(3));
      expect(find.text('标准'), findsOneWidget);
      expect(find.text('无损'), findsOneWidget);
    });

    testWidgets('点击某一项回调它的下标', (tester) async {
      final picked = <int?>[];
      await tester.pumpWidget(host(
        labels: ['标准', '高品质', '无损'],
        selectedIndex: 0,
        onSelected: picked.add,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('无损'));
      await tester.pumpAndSettle();

      expect(picked, [2]);
    });

    testWidgets('渲染后每一项都有一个可测量的高度槽位', (tester) async {
      await tester.pumpWidget(host(labels: ['标准', '高品质', '无损']));
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        expect(
          find.byKey(ValueKey('vsg-slot-$i')),
          findsOneWidget,
          reason: '第 $i 项应包在带 key 的高度槽位里（挤压与测试都靠它定位）',
        );
        expect(
          tester.getSize(find.byKey(ValueKey('vsg-slot-$i'))).height,
          greaterThan(0),
        );
      }
    });

    testWidgets('按下中间项时上下两项变矮', (tester) async {
      await tester.pumpWidget(host(labels: ['标准', '高品质', '无损']));
      await tester.pumpAndSettle();

      double slotHeight(int i) =>
          tester.getSize(find.byKey(ValueKey('vsg-slot-$i'))).height;

      final before = [slotHeight(0), slotHeight(1), slotHeight(2)];
      expect(before[0], greaterThan(0));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('高品质')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(
        slotHeight(0),
        lessThan(before[0]),
        reason: '被挤压的上邻居应当变矮',
      );
      expect(
        slotHeight(1),
        greaterThan(before[1]),
        reason: '被按下的项应当变高',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(slotHeight(0), closeTo(before[0], 0.5), reason: '松手后应回弹');
    });
  });
}

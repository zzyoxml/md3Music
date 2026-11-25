import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/player_top_bar_tab_dots.dart';

/// Windows 顶栏中段拖动区的布局契约。
///
/// 顶栏在 `Column` 里拿到的纵向约束是 unconstrained（0..∞）。拖动区若用
/// `SizedBox.expand`，会把高度撑成 Infinity，整页布局报
/// 「given an infinite size during layout」并停摆（Windows 播放页整页黑屏）。
void main() {
  setUp(() {
    kTopBarTabDotsEnabled.value = false;
  });

  tearDown(() {
    kTopBarTabDotsEnabled.value = false;
  });

  testWidgets('拖动区在无界高度约束下必须是有限尺寸', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 48, height: 48),
                playerTopBarTabMiddle(
                  wide: true,
                  segmentCount: 3,
                  strip: () => const SizedBox.shrink(),
                  onWindowDrag: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // 拖动区高度必须钉死（与同一行的 IconButton 一致），宽度吃满剩余空间。
    final dragArea = find.byType(GestureDetector);
    expect(dragArea, findsOneWidget);
    expect(tester.getSize(dragArea).height, 48);
    expect(tester.getSize(dragArea).width.isFinite, isTrue);
  });
}

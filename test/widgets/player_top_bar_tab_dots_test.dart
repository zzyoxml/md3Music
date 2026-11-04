// 顶栏中段页签圆点的让位规则：静止位在「见过的最宽可用段」（尾部收起态）里居中，
// **不跟随尾部宽度变化平移**；尾部真压到 8dp 那条线时才让位 —— 先左移、贴住返回键
// 后才压缩分段宽度，右缘始终不越过 8dp。
//
// 回归点：圆点原先是「整宽居中」的覆盖层，尾部加了睡眠定时那一格后就会被压上
// （360dp 竖屏实测重叠 38dp）。覆盖层改成 Row 里的 Expanded 之后，避让与压缩都
// 发生在 PlayerTopBarTabDots 内部，所以直接量它的盒子几何。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/player_top_bar_tab_dots.dart';

const Key _stripKey = Key('strip');

const double _back = 48;
const double _gap = PlayerTopBarTabDots.endGap;

/// 顶栏一行的简化版：返回键 · 圆点占中段 · 尾部胶囊当前宽度 [tailWidth]。
Widget _bar({
  required double screen,
  required double tailWidth,
  int segments = 4,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: screen,
        child: Row(
          children: [
            const SizedBox(width: _back, height: 48),
            Expanded(
              child: PlayerTopBarTabDots(
                segmentCount: segments,
                strip: const SizedBox(
                  key: _stripKey,
                  height: 48,
                  width: double.infinity,
                ),
              ),
            ),
            SizedBox(width: tailWidth, height: 36),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('PlayerTopBarTabDots', () {
    testWidgets('尾部收起：按基准宽（段数 × 48）居中', (tester) async {
      await tester.pumpWidget(_bar(screen: 600, tailWidth: 120));
      await tester.pump();

      final rect = tester.getRect(find.byKey(_stripKey));
      final box = 600 - _back - 120;
      expect(rect.width, closeTo(4 * 48, 0.5));
      expect(rect.left, closeTo(_back + (box - 192) / 2, 0.5));
    });

    testWidgets('尾部展开：圆点静止不动，只有与 ⋯ 的间距变小', (tester) async {
      await tester.pumpWidget(_bar(screen: 600, tailWidth: 120));
      await tester.pump();
      final rest = tester.getRect(find.byKey(_stripKey));
      final restGap = 600 - 120 - rest.right;

      // 尾部多出一段文案的宽度（+96）
      await tester.pumpWidget(_bar(screen: 600, tailWidth: 120 + 96));
      await tester.pump();
      final after = tester.getRect(find.byKey(_stripKey));

      expect(after.width, rest.width, reason: '还挤得下，不该压缩分段宽度');
      expect(
        after.left,
        closeTo(rest.left, 0.5),
        reason: '页签指示器是导航元素，不该被尾部宽度变化带着左右滑动',
      );
      expect(
        600 - (120 + 96) - after.right,
        closeTo(restGap - 96, 0.5),
        reason: '间距随尾部增长而变小 —— 让位的是间距，不是圆点的位置',
      );
      expect(
        600 - (120 + 96) - after.right,
        greaterThanOrEqualTo(_gap),
        reason: '但永不越过 8dp 那条线',
      );
    });

    testWidgets('左移到头：贴住返回键，改为压缩宽度，右缘仍留 8dp', (tester) async {
      await tester.pumpWidget(_bar(screen: 600, tailWidth: 420));
      await tester.pump();

      final rect = tester.getRect(find.byKey(_stripKey));
      final usable = 600 - 420 - _back - _gap;
      expect(rect.left, closeTo(_back, 0.5), reason: '已经贴到最左，没有再让的空间');
      expect(rect.width, closeTo(usable, 0.5), reason: '基准 192 放不下 → 压缩');
      expect(rect.width, lessThan(4 * 48));
      expect(rect.right, closeTo(600 - 420 - _gap, 0.5));
    });

    testWidgets('极端窄：压到可用宽为止，绝不与尾部重叠', (tester) async {
      await tester.pumpWidget(_bar(screen: 600, tailWidth: 500));
      await tester.pump();

      final rect = tester.getRect(find.byKey(_stripKey));
      // 可用只有 44，比 4 段 × 28 的触控地板还窄：宁可段小也不压上尾部
      expect(rect.width, closeTo(600 - 500 - _back - _gap, 0.5));
      expect(rect.right, closeTo(600 - 500 - _gap, 0.5));
      expect(tester.takeException(), isNull, reason: '不许出现 RenderFlex 溢出');
    });

    testWidgets('三段（Pad 无封面 tab）基准宽按实际段数算', (tester) async {
      await tester.pumpWidget(_bar(screen: 600, tailWidth: 120, segments: 3));
      await tester.pump();

      expect(tester.getRect(find.byKey(_stripKey)).width, closeTo(144, 0.5));
    });
  });

  group('playerBottomDesignInset：底部设计留白两态必须区分', () {
    tearDown(() => kTopBarTabDotsEnabled.value = false);

    test('关闭（默认）：竖屏 10、车机窄面板 16', () {
      kTopBarTabDotsEnabled.value = false;
      expect(playerBottomDesignInset(expanded: false), 10.0);
      expect(playerBottomDesignInset(expanded: true), 16.0);
    });

    test('开启：两态都抬到 40 —— 页签条已升到顶栏，传输行成了最底元素', () {
      kTopBarTabDotsEnabled.value = true;
      expect(playerBottomDesignInset(expanded: false), 40.0);
      expect(playerBottomDesignInset(expanded: true), 40.0);
    });

    test('开启态必须高于关闭态，否则页签条让出的那截会让按钮贴住屏底', () {
      kTopBarTabDotsEnabled.value = false;
      final off = playerBottomDesignInset(expanded: false);
      kTopBarTabDotsEnabled.value = true;
      expect(playerBottomDesignInset(expanded: false), greaterThan(off));
    });
  });
}

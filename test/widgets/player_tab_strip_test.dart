// 页签条的组件测试 —— 同一个控件的两种形态。
//
// 圆点形态（顶栏 / 宽屏右栏底部）没有图标可点，段与段只能按几何定位；这反过来正是
// 本组件的两条硬约定：① 每段都要有 Semantics.label（点径那么小，读不出来的话
// TalkBack 等于没有页签），② 命中高度守住 48dp 的 Android 基线。
// icon 形态（竖屏底部页签条，「顶栏页签圆点」关闭时的原形态）则是图标 + 指示线，
// 条高回到 34，切页手势与分段回传必须与圆点形态逐条等价。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_tab_strip.dart';

/// 承载 [PlayerTabStrip] 的宿主：自带 TabController，宽度固定 320。
class _Host extends StatefulWidget {
  const _Host({
    required this.itemCount,
    this.onLongPressCover,
    this.variant = PlayerTabStripVariant.dots,
  });

  final int itemCount;
  final VoidCallback? onLongPressCover;
  final PlayerTabStripVariant variant;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TabController controller = TabController(
    length: widget.itemCount,
    vsync: this,
    initialIndex: 1,
  );

  double? segmentWidth;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: PlayerTabStrip(
              controller: controller,
              activeColor: Colors.white,
              inactiveColor: Colors.white38,
              variant: widget.variant,
              onSegmentWidth: (w) => segmentWidth = w,
              items: [
                const PlayerTabItem(
                  icon: Icons.queue_music,
                  label: '播放列表',
                ),
                PlayerTabItem(
                  icon: Icons.album,
                  label: '封面',
                  onLongPress: widget.onLongPressCover,
                ),
                const PlayerTabItem(icon: Icons.lyrics, label: '歌词'),
                const PlayerTabItem(icon: Icons.comment_outlined, label: '评论'),
              ].take(widget.itemCount).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

PlayerTabStrip _strip(WidgetTester tester) =>
    tester.widget<PlayerTabStrip>(find.byType(PlayerTabStrip));

/// 第 [index] 段的中心：圆点没有图标可找，只能按等分宽度定位。
Offset _segmentCenter(WidgetTester tester, int index) {
  final rect = tester.getRect(find.byType(PlayerTabStrip));
  final width = rect.width / _strip(tester).items.length;
  return Offset(rect.left + width * (index + 0.5), rect.center.dy);
}

/// 圆点个数 = 段数：每段一颗 `AnimatedContainer`（点径的插值就挂在它身上）。
Finder _dots() => find.descendant(
  of: find.byType(PlayerTabStrip),
  matching: find.byType(AnimatedContainer),
);

void main() {
  group('PlayerTabStrip', () {
    testWidgets('命中高 48，一段一个圆点，回传分段宽度', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 4));

      expect(
        tester.getSize(find.byType(PlayerTabStrip)).height,
        48,
        reason: '视觉点径小，但命中高度必须守住 Android 48dp 基线',
      );

      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.segmentWidth, 80);
    });

    testWidgets('每段都带 Semantics.label（圆点自身不携带语义）', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const _Host(itemCount: 4));

      for (final label in ['播放列表', '封面', '歌词', '评论']) {
        expect(
          find.bySemanticsLabel(label),
          findsOneWidget,
          reason: '缺 label 时 TalkBack 只能念出「按钮」，页签等于不可用',
        );
      }
      handle.dispose();
    });

    testWidgets('当前段在语义上标成 selected（圆点没有图标可念）', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 4));

      // 直接读组件挂的 Semantics：flutter_test 的 isSemantics 在描述不匹配时
      // 自己会抛（describeMismatch 把 null 当 String 转），不值得依赖它。
      final selectedByLabel = {
        for (final w in tester.widgetList<Semantics>(
          find.descendant(
            of: find.byType(PlayerTabStrip),
            matching: find.byType(Semantics),
          ),
        ))
          w.properties.label: w.properties.selected,
      };
      // TabController initialIndex = 1 → 只有「封面」那颗是选中态
      expect(selectedByLabel['封面'], isTrue);
      expect(selectedByLabel['歌词'], isFalse);
      expect(selectedByLabel['评论'], isFalse);
    });

    testWidgets('点击某段切换到对应 tab，点当前段不动', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 4));
      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.controller.index, 1);

      await tester.tapAt(_segmentCenter(tester, 3));
      await tester.pumpAndSettle();
      expect(state.controller.index, 3);

      await tester.tapAt(_segmentCenter(tester, 3));
      await tester.pumpAndSettle();
      expect(state.controller.index, 3, reason: '点当前段不该再动');
    });

    testWidgets('长按封面段触发长按回调', (tester) async {
      int longPressed = 0;
      await tester.pumpWidget(
        _Host(itemCount: 4, onLongPressCover: () => longPressed++),
      );

      await tester.longPressAt(_segmentCenter(tester, 1));
      await tester.pumpAndSettle();

      expect(longPressed, 1);
    });

    testWidgets('三段（Pad 模式无封面 tab）时分段宽度按实际段数计算', (
      tester,
    ) async {
      await tester.pumpWidget(const _Host(itemCount: 3));

      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.segmentWidth, closeTo(320 / 3, 0.01));
      expect(_dots(), findsNWidgets(3));
    });
  });

  // 「顶栏页签圆点」关闭时，竖屏底部页签条用这套：与 HEAD 的原形态逐像素对齐。
  group('PlayerTabStrip icon 形态（竖屏底部原形态）', () {
    // 指示线是条内唯一被 IgnorePointer 包住的元素（圆点是 AnimatedContainer，
    // 里面也带 DecoratedBox，所以按 DecoratedBox 找会把四颗圆点一起算进来）。
    Finder _indicator() => find.descendant(
      of: find.byType(PlayerTabStrip),
      matching: find.byType(IgnorePointer),
    );

    testWidgets('一段一个图标，条高 34，没有圆点', (tester) async {
      await tester.pumpWidget(
        const _Host(itemCount: 4, variant: PlayerTabStripVariant.icons),
      );

      expect(
        tester.getSize(find.byType(PlayerTabStrip)).height,
        34,
        reason: '底部那条带不与传输控件抢视觉重量（HEAD 的原高度）',
      );
      expect(find.byIcon(Icons.queue_music), findsOneWidget);
      expect(find.byIcon(Icons.album), findsOneWidget);
      expect(find.byIcon(Icons.lyrics), findsOneWidget);
      expect(find.byIcon(Icons.comment_outlined), findsOneWidget);
      expect(_dots(), findsNothing, reason: 'icon 形态不该同时长出圆点');
    });

    testWidgets('指示线只有一条，挂在当前段下方', (tester) async {
      await tester.pumpWidget(
        const _Host(itemCount: 4, variant: PlayerTabStripVariant.icons),
      );
      final state = tester.state<_HostState>(find.byType(_Host));

      expect(_indicator(), findsOneWidget);
      // initialIndex = 1（封面段）：指示线中心应落在第 2 段。segmentWidth 是条内
      // 的局部宽度，所以要减掉条自身的左缘再换算段号，否则整条偏移一个屏幕宽度。
      final stripLeft = tester.getRect(find.byType(PlayerTabStrip)).left;
      final seg = state.segmentWidth!;
      final line = tester.getCenter(_indicator());
      expect((line.dx - stripLeft) / seg, closeTo(1.5, 0.01), reason: '指示线居中于当前段');

      await tester.tapAt(_segmentCenter(tester, 3));
      await tester.pumpAndSettle();
      final moved = tester.getCenter(_indicator());
      expect(
        (moved.dx - stripLeft) / seg,
        closeTo(3.5, 0.01),
        reason: '指示线跟着滑过去',
      );
    });

    testWidgets('切页与长按与圆点形态等价', (tester) async {
      int longPressed = 0;
      await tester.pumpWidget(
        _Host(
          itemCount: 4,
          variant: PlayerTabStripVariant.icons,
          onLongPressCover: () => longPressed++,
        ),
      );
      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.controller.index, 1);

      await tester.tapAt(_segmentCenter(tester, 3));
      await tester.pumpAndSettle();
      expect(state.controller.index, 3);

      await tester.longPressAt(_segmentCenter(tester, 1));
      await tester.pumpAndSettle();
      expect(longPressed, 1);
    });

    testWidgets('每段仍带 Semantics.label（图标也要念得出页名）', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const _Host(itemCount: 4, variant: PlayerTabStripVariant.icons),
      );

      for (final label in ['播放列表', '封面', '歌词', '评论']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }
      handle.dispose();
    });

    testWidgets('圆点形态不画指示线（两种形态互斥，不叠加）', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 4));

      expect(_indicator(), findsNothing);
      expect(find.byIcon(Icons.album), findsNothing);
      expect(_dots(), findsNWidgets(4));
    });
  });
}

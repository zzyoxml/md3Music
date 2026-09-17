import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_tab_strip.dart';

/// 承载 [PlayerTabStrip] 的宿主：自带 TabController，宽度固定 320。
class _Host extends StatefulWidget {
  const _Host({required this.itemCount, this.onLongPressCover});

  final int itemCount;
  final VoidCallback? onLongPressCover;

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
              onSegmentWidth: (w) => segmentWidth = w,
              items: [
                const PlayerTabItem(icon: Icons.queue_music),
                PlayerTabItem(
                  icon: Icons.album,
                  onLongPress: widget.onLongPressCover,
                ),
                const PlayerTabItem(icon: Icons.lyrics_outlined),
                const PlayerTabItem(icon: Icons.comment_outlined),
              ].take(widget.itemCount).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  group('PlayerTabStrip', () {
    testWidgets('高度 34，四个图标齐全，回传分段宽度', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 4));

      expect(tester.getSize(find.byType(PlayerTabStrip)).height, 34);
      expect(find.byIcon(Icons.queue_music), findsOneWidget);
      expect(find.byIcon(Icons.album), findsOneWidget);
      expect(find.byIcon(Icons.lyrics_outlined), findsOneWidget);
      expect(find.byIcon(Icons.comment_outlined), findsOneWidget);

      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.segmentWidth, 80);
    });

    testWidgets('点击某段切换到对应 tab，点当前段不动', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 4));
      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.controller.index, 1);

      await tester.tap(find.byIcon(Icons.comment_outlined));
      await tester.pumpAndSettle();
      expect(state.controller.index, 3);

      await tester.tap(find.byIcon(Icons.comment_outlined));
      await tester.pumpAndSettle();
      expect(state.controller.index, 3);
    });

    testWidgets('长按封面段触发长按回调', (tester) async {
      int longPressed = 0;
      await tester.pumpWidget(
        _Host(itemCount: 4, onLongPressCover: () => longPressed++),
      );

      await tester.longPress(find.byIcon(Icons.album));
      await tester.pumpAndSettle();

      expect(longPressed, 1);
    });

    testWidgets('三段（Pad 模式无封面 tab）时分段宽度按实际段数计算', (tester) async {
      await tester.pumpWidget(const _Host(itemCount: 3));

      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.segmentWidth, closeTo(320 / 3, 0.01));
      expect(find.byIcon(Icons.comment_outlined), findsNothing);
    });
  });
}

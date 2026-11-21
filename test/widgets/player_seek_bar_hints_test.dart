import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/playback_hint_pills.dart';
import 'package:md3music/widgets/player_seek_bar.dart';

/// 时间行中央提示插槽（[PlayerSeekBar.labelRowHints]）的几何与行高纪律。
///
/// 两件事必须守住：
/// 1. 提示与两个时间数字同一行，且居中于这两个数字之间（不是居中于整条进度条）；
/// 2. 提示出现/消失不改变进度条总高 —— 否则每首歌装载时底部 chrome 都会上下抖。

PlaybackHintState _state({bool buffering = false, bool fading = false}) =>
    PlaybackHintState.resolve(
      streamBuffering: buffering,
      hasError: false,
      crossfading: fading,
    );

Widget _wrap({
  Widget? hints,
  Widget? badge,
  PlaybackHintState? state,
}) {
  final hintWidget = hints ?? (state == null ? null : PlaybackHintPills(state: state));
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: PlayerSeekBar(
            position: const Duration(seconds: 30),
            duration: const Duration(minutes: 2),
            md3Style: true,
            activeColor: Colors.blue,
            inactiveColor: Colors.grey,
            labelColor: Colors.black,
            labelRowHints: hintWidget,
            labelRowBadge: badge,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('时间行提示插槽', () {
    testWidgets('提示出现不改变进度条总高', (tester) async {
      await tester.pumpWidget(_wrap());
      final plainHeight = tester.getSize(find.byType(PlayerSeekBar)).height;

      await tester.pumpWidget(_wrap(state: _state(buffering: true)));
      final hintHeight = tester.getSize(find.byType(PlayerSeekBar)).height;

      await tester.pumpWidget(
        _wrap(state: _state(buffering: true, fading: true)),
      );
      final bothHeight = tester.getSize(find.byType(PlayerSeekBar)).height;

      expect(plainHeight, 38);
      expect(hintHeight, plainHeight, reason: '提示胶囊与时间行等高，行高不得被撑开');
      expect(bothHeight, plainHeight, reason: '两条并排也不得撑开行高');
    });

    testWidgets('提示与两个时间数字同一行，且居中于二者之间', (tester) async {
      await tester.pumpWidget(_wrap(state: _state(buffering: true)));

      final left = tester.getRect(find.text('0:30'));
      final right = tester.getRect(find.text('-1:30'));
      final pill = tester.getRect(
        find.descendant(
          of: find.byType(PlaybackHintPills),
          matching: find.byType(Container),
        ),
      );

      // 同一行：垂直中心一致
      expect(pill.center.dy, closeTo(left.center.dy, 1.0));
      expect(pill.center.dy, closeTo(right.center.dy, 1.0));
      // 居中于两个数字之间：两端留白相等
      expect(
        pill.center.dx,
        closeTo((left.right + right.left) / 2, 1.0),
        reason: '应居中于两个时间数字之间，而不是居中于整条进度条',
      );
    });

    testWidgets('两条同时出现：分别包裹、整组居中', (tester) async {
      await tester.pumpWidget(
        _wrap(state: _state(buffering: true, fading: true)),
      );

      final left = tester.getRect(find.text('0:30'));
      final right = tester.getRect(find.text('-1:30'));
      final group = tester.getRect(find.byType(PlaybackHintPills));
      final first = tester.getRect(find.text(PlaybackHintPills.bufferingLabel));
      final second = tester.getRect(find.text(PlaybackHintPills.transitionLabel));

      expect(find.text(PlaybackHintPills.bufferingLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.transitionLabel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PlaybackHintPills),
          matching: find.byType(Container),
        ),
        findsNWidgets(2),
      );
      // 整组居中：两枚胶囊并排后的整体中点对齐两个数字之间的中点
      expect(
        group.center.dx,
        closeTo((left.right + right.left) / 2, 1.0),
      );
      expect(first.center.dx, lessThan(second.center.dx));
    });

    testWidgets('与车机音质徽章共存时，徽章仍点得动、行高按徽章走', (tester) async {
      int tapped = 0;
      await tester.pumpWidget(
        _wrap(
          state: _state(buffering: true),
          badge: GestureDetector(
            onTap: () => tapped++,
            child: const SizedBox(
              height: 32,
              child: Text('HQ'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('HQ'));
      await tester.pump();
      expect(tapped, 1, reason: '有徽章时这一行不套 IgnorePointer');
      expect(find.text(PlaybackHintPills.bufferingLabel), findsOneWidget);
      expect(
        tester.getSize(find.byType(PlayerSeekBar)).height,
        greaterThan(38),
        reason: '徽章比时间行高，整条按内容自然长高（既有行为）',
      );
    });
  });
}

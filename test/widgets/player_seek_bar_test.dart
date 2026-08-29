import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_seek_bar.dart';

/// 把 [PlayerSeekBar] 放进固定 300 宽的盒子里，方便按比例换算拖动位置。
Widget _wrap({
  required Duration position,
  required Duration duration,
  ValueChanged<Duration>? onSeekEnd,
  VoidCallback? onSeekStart,
  bool wavy = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: PlayerSeekBar(
            position: position,
            duration: duration,
            wavy: wavy,
            activeColor: Colors.blue,
            inactiveColor: Colors.grey,
            labelColor: Colors.black,
            onSeekStart: onSeekStart,
            onSeekEnd: onSeekEnd,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('PlayerSeekBar', () {
    testWidgets('常态高度只有 24，时间标签不可见', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        ),
      );

      expect(tester.getSize(find.byType(PlayerSeekBar)).height, 24);
      // 标签存在于树里但完全透明（拖动时才浮现）
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0);
    });

    testWidgets('拖到轨道中点：浮现时间标签并回报中点位置', (tester) async {
      Duration? seeked;
      bool started = false;
      await tester.pumpWidget(
        _wrap(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          onSeekStart: () => started = true,
          onSeekEnd: (v) => seeked = v,
        ),
      );

      final bar = find.byType(PlayerSeekBar);
      final topLeft = tester.getTopLeft(bar);
      final center = tester.getCenter(bar);
      // 从左端起手拖到水平中点
      final gesture = await tester.startGesture(
        Offset(topLeft.dx + 1, center.dy),
      );
      await tester.pump();
      await gesture.moveTo(center);
      await tester.pump(const Duration(milliseconds: 200));

      expect(started, isTrue);
      // 拖动中标签淡入
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 1);
      // 剩余时间用负号显示
      expect(find.text('1:00'), findsOneWidget);
      expect(find.text('-1:00'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(seeked, isNotNull);
      expect((seeked!.inSeconds - 60).abs() <= 1, isTrue);
    });

    testWidgets('时长未知时不响应拖动', (tester) async {
      Duration? seeked;
      await tester.pumpWidget(
        _wrap(
          position: Duration.zero,
          duration: Duration.zero,
          onSeekEnd: (v) => seeked = v,
        ),
      );

      final center = tester.getCenter(find.byType(PlayerSeekBar));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(seeked, isNull);
    });
  });
}

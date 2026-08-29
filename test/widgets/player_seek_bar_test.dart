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
  bool isPlaying = false,
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
            isPlaying: isPlaying,
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
    testWidgets('常态高度 38，时间常显但压暗', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        ),
      );

      expect(tester.getSize(find.byType(PlayerSeekBar)).height, 38);
      // 时间常显：左＝已播放，右＝剩余（负号）
      expect(find.text('0:30'), findsOneWidget);
      expect(find.text('-1:30'), findsOneWidget);
      // 静止时压暗到 50%
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0.5);
    });

    testWidgets('画布拿到完整宽高（回归：CustomPaint 默认 size 为 0 导致轨道不可见）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        ),
      );

      final canvas = find.descendant(
        of: find.byType(PlayerSeekBar),
        matching: find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              (w.painter?.runtimeType.toString().contains('SeekBar') ?? false),
        ),
      );
      expect(canvas, findsOneWidget);
      final size = tester.getSize(canvas);
      expect(size.width, 300, reason: '画布必须铺满可用宽度，否则整条轨道画不出来');
      expect(size.height, greaterThan(0));
    });

    testWidgets('拖到轨道中点：时间提亮并回报中点位置', (tester) async {
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
      // 拖动中时间提亮到全不透明
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

    testWidgets('暂停时波形收敛成直线并停住 ticker（pumpAndSettle 不应超时）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          isPlaying: false,
        ),
      );
      // 波形相位是 repeat() 的无限动画：若暂停后没停住，这里会超时失败
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSeekBar), findsOneWidget);
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

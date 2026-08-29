import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_seek_bar.dart';

/// 把 [PlayerSeekBar] 放进固定 300 宽的盒子里，方便按比例换算拖动位置。
Widget _wrap({
  required Duration position,
  required Duration duration,
  ValueChanged<Duration>? onSeekEnd,
  VoidCallback? onSeekStart,
  bool md3Style = true,
  bool isPlaying = false,
  double speed = 1.0,
  double? climaxStart,
  double? climaxEnd,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: PlayerSeekBar(
            position: position,
            duration: duration,
            md3Style: md3Style,
            isPlaying: isPlaying,
            speed: speed,
            climaxStart: climaxStart,
            climaxEnd: climaxEnd,
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

/// 轨道画布（挂着 _SeekBarPainter 的那个 CustomPaint）
Finder _canvas() => find.descendant(
  of: find.byType(PlayerSeekBar),
  matching: find.byWidgetPredicate(
    (w) =>
        w is CustomPaint &&
        (w.painter?.runtimeType.toString().contains('SeekBar') ?? false),
  ),
);

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

      final canvas = _canvas();
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

    testWidgets('暂停时停住 ticker（pumpAndSettle 不应超时）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          isPlaying: false,
        ),
      );
      // 自驱动 ticker 是无限动画：暂停后若没停住，这里会超时失败
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

    testWidgets('暂停时已播放段与未播放段同色', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          isPlaying: false,
        ),
      );

      // 绘制顺序：未播放段 → 已播放段；暂停时两段都是 inactiveColor
      expect(
        tester.renderObject(_canvas()),
        paints
          ..rrect(color: Colors.grey)
          ..rrect(color: Colors.grey),
      );
    });

    testWidgets('播放时已播放段用强调色', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          isPlaying: true,
        ),
      );
      // 上色动画 220ms 跑完
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.renderObject(_canvas()),
        paints
          ..rrect(color: Colors.grey)
          ..rrect(color: Colors.blue),
      );
    });

    testWidgets('高潮指示被已播放进度掠过后消失', (tester) async {
      // 高潮区间 30~60s，进度在区间之前 → 未播放段 + 高潮 + 已播放段 = 3 个 rrect
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 2),
          climaxStart: 30,
          climaxEnd: 60,
        ),
      );
      expect(
        tester.renderObject(_canvas()),
        paintsExactlyCountTimes(#drawRRect, 3),
      );

      // 进度越过高潮区间末端 → 高潮高亮整段被裁掉，只剩两段轨道
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 70),
          duration: const Duration(minutes: 2),
          climaxStart: 30,
          climaxEnd: 60,
        ),
      );
      expect(
        tester.renderObject(_canvas()),
        paintsExactlyCountTimes(#drawRRect, 2),
      );
    });

    testWidgets('自驱动：上报位置不变也会按 30fps 推进', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          isPlaying: true,
        ),
      );
      expect(find.text('0:30'), findsOneWidget);

      // 不更新 position，只让时间过去 2s：ticker 应自行把时间推到 0:32
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:32'), findsOneWidget);
      expect(find.text('-1:28'), findsOneWidget);
    });

    testWidgets('自驱动：倍速参与推算', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          isPlaying: true,
          speed: 2.0,
        ),
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      // 2 秒墙上时间 × 2 倍速 ≈ 4 秒音频
      expect(find.text('0:04'), findsOneWidget);
    });

    testWidgets('上报位置回退不到 1s 时不回跳（单调保护）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          isPlaying: true,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:32'), findsOneWidget);

      // 音频层把位置又报成 31.5s（抖动）：展示值不应回退
      await tester.pumpWidget(
        _wrap(
          position: const Duration(milliseconds: 31500),
          duration: const Duration(minutes: 2),
          isPlaying: true,
        ),
      );
      expect(find.text('0:32'), findsOneWidget);

      // 真正的 seek（差距 > 1s）则立即采用上报值
      await tester.pumpWidget(
        _wrap(
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 2),
          isPlaying: true,
        ),
      );
      expect(find.text('0:10'), findsOneWidget);
    });
  });
}

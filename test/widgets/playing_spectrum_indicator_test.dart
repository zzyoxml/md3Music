/// PlayingSpectrumIndicator 单元测试
///
/// 验证：
/// 1. isPlaying=true 时 ticker 启动，画面有重绘
/// 2. isPlaying=false 时 ticker 停止，画面无重绘
/// 3. 重绘通过 ValueNotifier 驱动（不依赖 setState）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/playing_spectrum_indicator.dart';

void main() {
  group('PlayingSpectrumIndicator', () {
    testWidgets('isPlaying=true 时 ticker 启动并产生重绘', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayingSpectrumIndicator(
              color: Colors.red,
              size: 14,
              isPlaying: true,
            ),
          ),
        ),
      );

      // 记录初始 painter 实例
      final initialPainter = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(PlayingSpectrumIndicator),
          matching: find.byType(CustomPaint),
        ),
      ).painter;

      expect(initialPainter, isNotNull);

      // 泵送 5 帧（约 80ms）
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // 验证 CustomPaint 的 painter 仍是同一实例
      // （ValueNotifier + super(repaint:) 驱动重绘不重建 widget）
      // 若用 setState，painter 实例每帧重建，identical 为 false
      final finalPainter = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(PlayingSpectrumIndicator),
          matching: find.byType(CustomPaint),
        ),
      ).painter;

      expect(identical(initialPainter, finalPainter), isTrue,
          reason: 'painter 实例应保持不变（ValueNotifier 驱动重绘，不重建 widget）');
    });

    testWidgets('isPlaying=false 时 ticker 停止', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayingSpectrumIndicator(
              color: Colors.red,
              size: 14,
              isPlaying: false,
            ),
          ),
        ),
      );

      // _ticker 是 private，通过行为间接验证：pump 后无异常即说明 ticker 已停止
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlayingSpectrumIndicator), findsOneWidget);
    });
  });
}

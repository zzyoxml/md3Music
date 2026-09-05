/// AppleLyricsView position 解耦测试：
/// 1. positionListenable 模式：位置经内部订阅生效（不依赖外层重建）
/// 2. adaptTimeMs 生效（在线歌词时间偏移扣减）
/// 3. 静态模式（无 positionListenable）行为不回归
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  final lines = <LyricLine>[
    LyricLine(startTime: 0, duration: 1000, text: 'A'),
    LyricLine(startTime: 1000, duration: 1000, text: 'B'),
  ];

  testWidgets('positionListenable 模式：notifier 更新后权威时间生效', (
    tester,
  ) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    await tester.pumpWidget(
      MaterialApp(
        home: AppleLyricsView(
          lines: lines,
          currentTimeMs: 0,
          positionListenable: position,
          isPlaying: false,
        ),
      ),
    );
    position.value = const Duration(milliseconds: 1500);
    // 内部订阅应立即吸收新位置（不需要外层 rebuild）
    await tester.pump();
    final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
    expect(state.authorityTimeMsForTest, 1500);
    expect(tester.takeException(), isNull);
    position.dispose();
  });

  testWidgets('adaptTimeMs：偏移被扣减', (tester) async {
    final position = ValueNotifier<Duration>(
      const Duration(milliseconds: 1500),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppleLyricsView(
          lines: lines,
          currentTimeMs: 0,
          positionListenable: position,
          adaptTimeMs: (raw) => raw.inMilliseconds - 1000,
          isPlaying: false,
        ),
      ),
    );
    await tester.pump();
    final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
    expect(state.authorityTimeMsForTest, 500);
    position.dispose();
  });

  testWidgets('静态模式不回归：currentTimeMs 直传仍生效', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppleLyricsView(
          lines: lines,
          currentTimeMs: 1500,
          isPlaying: false,
        ),
      ),
    );
    await tester.pump();
    final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
    expect(state.authorityTimeMsForTest, 1500);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大跳变（切歌/seek）不抛异常', (tester) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    await tester.pumpWidget(
      MaterialApp(
        home: AppleLyricsView(
          lines: lines,
          currentTimeMs: 0,
          positionListenable: position,
          isPlaying: true,
        ),
      ),
    );
    position.value = const Duration(milliseconds: 60000);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    position.dispose();
  });
}

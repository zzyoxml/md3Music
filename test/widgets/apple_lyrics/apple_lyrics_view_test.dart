/// AppleLyricsView 单元测试
///
/// 覆盖 spec.md "Requirement: 点击跳转" 与 tasks.md Task 17 各场景：
/// 1. 空 lines 列表 build 不崩溃
/// 2. findCurrentLineIndex 纯逻辑测试（currentTimeMs=0 → index=0 等）
/// 3. currentTimeMs 落在某行内：当前行正确切换
/// 4. 点击某行：触发 onSeek 回调，参数为该行 startTime
/// 5. hasWordTiming 切换：混合 KRC 行与 LRC 行时 build 不崩溃
/// 6. currentTimeMs 推进后 build 不崩溃（posY 变化由弹簧驱动，此处验证不崩溃）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

void main() {
  group('AppleLyricsView.findCurrentLineIndex', () {
    test('空列表返回 -1', () {
      expect(AppleLyricsView.findCurrentLineIndex(const [], 0), -1);
    });

    test('currentTimeMs=0 当前行 index=0', () {
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'A'),
        LyricLine(startTime: 1000, duration: 1000, text: 'B'),
      ];
      expect(AppleLyricsView.findCurrentLineIndex(lines, 0), 0);
    });

    test('currentTimeMs 落在某行内返回正确索引', () {
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'A'),
        LyricLine(startTime: 1000, duration: 1000, text: 'B'),
        LyricLine(startTime: 2000, duration: 1000, text: 'C'),
      ];
      expect(AppleLyricsView.findCurrentLineIndex(lines, 0), 0);
      expect(AppleLyricsView.findCurrentLineIndex(lines, 500), 0);
      expect(AppleLyricsView.findCurrentLineIndex(lines, 1000), 1);
      expect(AppleLyricsView.findCurrentLineIndex(lines, 1500), 1);
      expect(AppleLyricsView.findCurrentLineIndex(lines, 2000), 2);
      // 时间超过最后一行：返回最后一行
      expect(AppleLyricsView.findCurrentLineIndex(lines, 9999), 2);
    });

    test('时间早于第一行返回 0', () {
      final lines = <LyricLine>[
        LyricLine(startTime: 1000, duration: 1000, text: 'A'),
      ];
      expect(AppleLyricsView.findCurrentLineIndex(lines, 500), 0);
      expect(AppleLyricsView.findCurrentLineIndex(lines, 0), 0);
    });
  });

  group('AppleLyricsView.effectiveLineEndTime', () {
    test('无逐字行（LRC/纯文本）返回 endTime = startTime + duration', () {
      const line = LyricLine(startTime: 1000, duration: 0, text: 'A');
      expect(AppleLyricsView.effectiveLineEndTime(line), 1000);
      const line2 = LyricLine(startTime: 1000, duration: 500, text: 'A');
      expect(AppleLyricsView.effectiveLineEndTime(line2), 1500);
    });

    test('逐字行（KRC）：行 duration 覆盖空白时取最后一个字结束时间', () {
      const line = LyricLine(
        startTime: 12500,
        duration: 4200, // 行 duration 覆盖到 16700（含尾音/空白）
        text: '運命の華',
        words: [
          LyricWord(startTime: 12500, duration: 300, text: '運'),
          LyricWord(startTime: 12800, duration: 400, text: '命'),
          LyricWord(startTime: 13700, duration: 600, text: '華'), // 结束于 14300
        ],
      );
      // 最后一个字结束 14300 < 行 duration 结束 16700 → 取 14300
      expect(AppleLyricsView.effectiveLineEndTime(line), 14300);
    });

    test('逐字行（KRC）：行 duration 精确覆盖到最后字时不改变行为', () {
      const line = LyricLine(
        startTime: 12500,
        duration: 1800, // 恰好 = 最后字结束偏移（12500+1800=14300）
        text: '運命の華',
        words: [
          LyricWord(startTime: 12500, duration: 300, text: '運'),
          LyricWord(startTime: 13700, duration: 600, text: '華'),
        ],
      );
      expect(AppleLyricsView.effectiveLineEndTime(line), 14300);
    });
  });

  group('AppleLyricsView build', () {
    // 辅助：泵送多帧让弹簧动画推进
    Future<void> pumpFrames(WidgetTester tester, int frames) async {
      for (int i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('空 lines 列表 build 不崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: const [],
              currentTimeMs: 0,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 5);
      expect(find.byType(AppleLyricsView), findsOneWidget);
    });

    testWidgets('有 lines 但 currentTimeMs=0 build 不崩溃', (tester) async {
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'Line 1'),
        LyricLine(startTime: 1000, duration: 1000, text: 'Line 2'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: lines,
              currentTimeMs: 0,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 5);
      expect(find.byType(AppleLyricsView), findsOneWidget);
    });

    testWidgets('混合 KRC 与 LRC 行 build 不崩溃', (tester) async {
      final lines = <LyricLine>[
        // KRC 行（hasWordTiming=true）
        LyricLine(
          startTime: 0,
          duration: 1000,
          text: 'KRC行',
          words: [
            LyricWord(startTime: 0, duration: 500, text: 'KRC'),
            LyricWord(startTime: 500, duration: 500, text: '行'),
          ],
        ),
        // LRC 行（hasWordTiming=false）
        LyricLine(startTime: 1000, duration: 1000, text: 'LRC行'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: lines,
              currentTimeMs: 500,
              isPlaying: true,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 10);
      expect(find.byType(AppleLyricsView), findsOneWidget);
    });

    testWidgets('enableScale=false 时不崩溃', (tester) async {
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'A'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: lines,
              currentTimeMs: 0,
              enableScale: false,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 5);
      expect(find.byType(AppleLyricsView), findsOneWidget);
    });

    testWidgets('currentTimeMs 推进后 build 不崩溃（posY 变化）', (tester) async {
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'A'),
        LyricLine(startTime: 1000, duration: 1000, text: 'B'),
        LyricLine(startTime: 2000, duration: 1000, text: 'C'),
      ];
      // 初始构建：currentTimeMs=0
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: lines,
              currentTimeMs: 0,
              isPlaying: true,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 10);

      // 推进到第二行
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: lines,
              currentTimeMs: 1500,
              isPlaying: true,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 10);

      // 推进到第三行
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(
              lines: lines,
              currentTimeMs: 2500,
              isPlaying: true,
            ),
          ),
        ),
      );
      await pumpFrames(tester, 10);

      expect(find.byType(AppleLyricsView), findsOneWidget);
    });
  });

  group('AppleLyricsView 点击跳转', () {
    testWidgets('点击某行触发 onSeek 回调，参数为该行 startTime', (tester) async {
      int? seekTime;
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 2000, text: 'Line 1'),
      ];

      // 使用固定尺寸便于计算点击位置
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 0,
                isPlaying: true,
                onSeek: (t) => seekTime = t,
              ),
            ),
          ),
        ),
      );

      // 泵送足够帧让弹簧动画稳定（posY 接近 targetY）
      // 60帧 ≈ 1秒，足够弹簧收敛
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // 计算点击位置：
      // fontSize = max(800*0.08, 12) = 64
      // lineHeight = 64 * 1.2 = 76.8
      // targetY = -(0*76.8 + 38.4 - 600*0.35) = -(38.4 - 210) = 171.6
      // 第0行中心 y ≈ 171.6 + 38.4 = 210
      await tester.tapAt(const Offset(400, 210));
      await tester.pump();

      expect(seekTime, isNotNull);
      expect(seekTime, 0);
    });

    testWidgets('点击第二行触发 onSeek 回调，参数为第二行 startTime', (tester) async {
      int? seekTime;
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'Line 1'),
        LyricLine(startTime: 1000, duration: 1000, text: 'Line 2'),
      ];

      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 1000,
                isPlaying: true,
                onSeek: (t) => seekTime = t,
              ),
            ),
          ),
        ),
      );

      // 泵送足够帧让弹簧动画稳定
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // 第1行（index=1）中心 y：
      // posY = targetYForLine(1, 76.8) = -(1*76.8 + 38.4 - 600*0.35) = 94.8
      // 第1行顶部 y = 1 * lineHeight + posY = 76.8 + 94.8 = 171.6
      // 第1行中心 y = 171.6 + lineHeight/2 = 171.6 + 38.4 = 210
      await tester.tapAt(const Offset(400, 210));
      await tester.pump();

      expect(seekTime, isNotNull);
      expect(seekTime, 1000);
    });
  });
}

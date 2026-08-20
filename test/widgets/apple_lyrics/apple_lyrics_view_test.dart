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
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('AppleLyricsView P0-A Ticker 停止（非逐字省电）', () {
    testWidgets('非逐字歌词（LRC 逐行/纯文本）播放中收敛后停止 Ticker', (tester) async {
      // gap = 1000 - 0 = 1000 < 4000 → 无间奏，画面可完全静止
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 0, text: 'Line 1'),
        LyricLine(startTime: 1000, duration: 0, text: 'Line 2'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 0,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      // 推进足够帧：首帧动画 + posY 弹簧（过阻尼，0→targetY≈190px
      // 收敛到 settle 阈值需约 2s）全部收敛后触发 Ticker 停止
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.binding.transientCallbackCount, 0,
          reason: '非逐字歌词播放中画面静止后应停止 Ticker');
    });

    testWidgets('逐字歌词（KRC/字级 LRC，含本地/云盘 LRC 逐字）播放中保持 Ticker', (tester) async {
      // 本用例验证"eco 关闭时"的 P0-A 行为：逐字动画需 Ticker 满帧推进。
      // 省电模式现已默认开启（eco 开启时逐字动画改由 60fps Timer 推进、Ticker 停止），
      // 因此这里显式关闭，保持断言 Ticker 仍在运行的原始意图。
      SharedPreferences.setMockInitialValues({});
      await LyricPreferences.instance.setEcoMode(false);
      addTearDown(() => LyricPreferences.instance.reset());
      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 5000,
          text: '逐字歌词',
          words: const [
            LyricWord(startTime: 0, duration: 5000, text: '逐字歌词'),
          ],
        ),
        LyricLine(startTime: 5000, duration: 5000, text: '第二行'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 0,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      // 字内渐变/上浮动画推进中（5 帧 < 字时长），不应停止
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: '逐字歌词（含本地/云盘 LRC 逐字）播放中必须保持 Ticker');
    });
  });

  group('AppleLyricsView 省电模式：拖动歌词后立即锁回 60fps', () {
    testWidgets('松手后的等待回弹期歌词静止，应立即锁回（不得等满 3s 回弹倒计时）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await LyricPreferences.instance.setEcoMode(true);
      addTearDown(() => LyricPreferences.instance.reset());

      // 逐字歌词（hasWordTiming=true）播放中：Ticker 保持运行，
      // 便于直接读取 ecoUnlockedForTest 观测限帧状态。
      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 60000,
          text: '逐字歌词行',
          words: const [
            LyricWord(startTime: 0, duration: 60000, text: '逐字歌词行'),
          ],
        ),
        LyricLine(
          startTime: 60000,
          duration: 60000,
          text: '第二行',
          words: const [
            LyricWord(startTime: 60000, duration: 60000, text: '第二行'),
          ],
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 0,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      // 推进到初始收敛（弹簧回到当前行目标，视觉静止）
      const step = Duration(milliseconds: 16);
      for (int i = 0; i < 300; i++) {
        await tester.pump(step);
      }

      bool ecoUnlocked() =>
          (tester.state(find.byType(AppleLyricsView)) as dynamic)
              .ecoUnlockedForTest as bool;

      // 初始稳态应锁定
      expect(ecoUnlocked(), isFalse, reason: '初始收敛后省电模式应锁定');

      // 垂直拖动歌词（分步移动累计超过 18px slop 后 onVerticalDragUpdate 才回调）
      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(AppleLyricsView)));
      for (int i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, 10));
      }
      await tester.pump(step);
      expect(ecoUnlocked(), isTrue, reason: '拖动中应解锁以保持顺滑');

      // 松手：进入等待回弹期，但歌词已静止（弹簧停在拖拽位置）→ 应立即锁回
      await gesture.up();
      await tester.pump(step);
      expect(ecoUnlocked(), isFalse,
          reason: '松手后等待回弹期歌词静止，应立即锁回 60fps（不得等满 3s 倒计时）');

      // 推进过整个等待 + 自动回弹 + 回弹收敛，始终保持锁定
      for (int i = 0; i < 600; i++) {
        await tester.pump(step);
      }
      expect(ecoUnlocked(), isFalse,
          reason: '自动回弹结束后应保持锁定');
    });

    testWidgets('快速甩动松手后惯性滑行期间保持解锁，惯性停住后锁回 60fps',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await LyricPreferences.instance.setEcoMode(true);
      addTearDown(() => LyricPreferences.instance.reset());

      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 60000,
          text: '逐字歌词行',
          words: const [
            LyricWord(startTime: 0, duration: 60000, text: '逐字歌词行'),
          ],
        ),
        LyricLine(
          startTime: 60000,
          duration: 60000,
          text: '第二行',
          words: const [
            LyricWord(startTime: 60000, duration: 60000, text: '第二行'),
          ],
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 0,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      const step = Duration(milliseconds: 16);
      for (int i = 0; i < 300; i++) {
        await tester.pump(step);
      }

      bool ecoUnlocked() =>
          (tester.state(find.byType(AppleLyricsView)) as dynamic)
              .ecoUnlockedForTest as bool;

      // 快速甩动（velocity 1000px/s）→ 松手后产生惯性滑行
      await tester.fling(
        find.byType(AppleLyricsView),
        const Offset(0, -200),
        1000,
      );
      // 惯性初期弹簧未静止 → 必须保持解锁（60fps 滑行会明显发卡）
      int unlockedDuringInertia = 0;
      for (int i = 0; i < 40; i++) {
        await tester.pump(step);
        if (ecoUnlocked()) unlockedDuringInertia++;
      }
      expect(unlockedDuringInertia, greaterThan(0),
          reason: '松手后惯性滑行期间应保持解锁（否则滑动发卡）');

      // 推进足够久让惯性收敛（弹簧静止），应锁回 60fps
      for (int i = 0; i < 200; i++) {
        await tester.pump(step);
      }
      expect(ecoUnlocked(), isFalse,
          reason: '惯性停住后应锁回 60fps');
    });
  });
}

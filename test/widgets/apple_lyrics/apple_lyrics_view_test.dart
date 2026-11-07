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

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
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

      // 让 onTapUp 触发的 AppHaptics 300ms 兜底定时器自然到期，
      // 避免测试结束前仍有 pending Timer 触发 flutter_test 断言。
      await tester.pump(const Duration(milliseconds: 400));

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

      // 让 onTapUp 触发的 AppHaptics 300ms 兜底定时器自然到期，
      // 避免测试结束前仍有 pending Timer 触发 flutter_test 断言。
      await tester.pump(const Duration(milliseconds: 400));

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
      // 省电模式默认关闭；这里显式关闭，保持断言 Ticker 仍在运行的原始意图。
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
    testWidgets('挂载即建立 eco 限帧：不拨开关、不依赖 _onTick 自我纠正也应锁 60fps',
        (tester) async {
      // 复现「升级后经 headless 引擎（无 Surface / Ticker 被 mute）拉起」场景：
      // eco 偏好为开时，initState 必须直接起 60fps eco Timer，而不是等满帧 Ticker
      // 的第一帧 _onTick 才自我纠正——后者在无 vsync 时永不发生，导致页面停在 120Hz，
      // 必须拨动开关才恢复（正是本 bug）。
      SharedPreferences.setMockInitialValues({'lyric_eco_mode': true});
      await LyricPreferences.instance.setEcoMode(true);
      addTearDown(() => LyricPreferences.instance.reset());
      expect(LyricPreferences.instance.ecoMode, isTrue);

      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 60000,
          text: '逐字歌词行',
          words: const [
            LyricWord(startTime: 0, duration: 60000, text: '逐字歌词行'),
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

      // 关键：pumpWidget 仅推进到 t=0（eco Timer 尚未触发任何 tick，_onTick 从未运行），
      // 但驱动源已在 initState 内确定为 eco Timer、Ticker 未启动。
      // 旧实现（initState 裸起 Ticker）此刻 _isTickerRunning=true、_ecoTimer=null，
      // 本断言会失败——即本 bug 的回归护栏。
      final state = (tester.state(find.byType(AppleLyricsView)) as dynamic);
      expect(state.ecoDriverIsTimerForTest, isTrue,
          reason: '挂载即应以 60fps eco Timer 为驱动源，不依赖 _onTick 自我纠正');
      expect(state.ecoUnlockedForTest, isFalse,
          reason: '初始非滚动态应处于锁定');
    });

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

  group('AppleLyricsView 省电模式：可见性门控（P0-A）', () {
    // 背景：eco 开 + 播放逐字歌词时驱动源恒为 60fps Timer（逐字动画不收敛、
    // 不进停帧分支）。Ticker 由 TickerMode 自动 mute，但 eco Timer 不受任何
    // 可见性约束——切走 tab / 退后台后会以 60Hz 离屏驱动 _onTick 持续重绘。
    // P0-A：不可见时挂起 Timer，恢复可见后重建并做帧时钟 gap 对齐。
    LyricLine wordLine(int startMs) => LyricLine(
          startTime: startMs,
          duration: 60000,
          text: '逐字歌词行',
          words: [
            LyricWord(startTime: startMs, duration: 60000, text: '逐字歌词行'),
          ],
        );

    /// lines 传 null 模拟切歌 loading 占位（歌词视图被卸载，同
    /// full_player_am 的 _isLoadingLyrics 分支）。
    Widget host(List<LyricLine>? lines, {bool tickerMode = true}) =>
        MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: tickerMode,
              child: SizedBox(
                width: 400,
                height: 600,
                child: lines == null
                    ? const SizedBox.expand()
                    : AppleLyricsView(
                        lines: lines,
                        currentTimeMs: 0,
                        isPlaying: true,
                      ),
              ),
            ),
          ),
        );

    dynamic viewState(WidgetTester tester) =>
        tester.state(find.byType(AppleLyricsView)) as dynamic;

    Future<void> prepareEcoOn() async {
      SharedPreferences.setMockInitialValues({'lyric_eco_mode': true});
      await LyricPreferences.instance.setEcoMode(true);
      addTearDown(() => LyricPreferences.instance.reset());
    }

    testWidgets('TickerMode 关闭（tab 切走）挂起 eco Timer，恢复可见后重建',
        (tester) async {
      await prepareEcoOn();
      final lines = <LyricLine>[wordLine(0)];

      // 挂载时即不可见（后台 tab 预构建等场景）：不得建立 Timer
      await tester.pumpWidget(host(lines, tickerMode: false));
      expect(viewState(tester).ecoTimerActiveForTest, isFalse,
          reason: 'TickerMode 关闭时应挂起 eco Timer，不再离屏 60fps 驱动');

      // 恢复可见（切回歌词 tab）→ Timer 回到 60fps 驱动
      await tester.pumpWidget(host(lines, tickerMode: true));
      expect(viewState(tester).ecoTimerActiveForTest, isTrue,
          reason: '恢复可见后 eco Timer 应回到 60fps 驱动');
      expect(viewState(tester).ecoDriverIsTimerForTest, isTrue);
    });

    testWidgets('App 退后台挂起 eco Timer，回前台恢复', (tester) async {
      await prepareEcoOn();
      final lines = <LyricLine>[wordLine(0)];

      await tester.pumpWidget(host(lines));
      expect(viewState(tester).ecoTimerActiveForTest, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(viewState(tester).ecoTimerActiveForTest, isFalse,
          reason: '退后台应挂起 eco Timer（否则后台仍 60Hz 驱动 _onTick）');

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(viewState(tester).ecoTimerActiveForTest, isTrue,
          reason: '回前台应恢复 60fps Timer 驱动');
      expect(viewState(tester).ecoDriverIsTimerForTest, isTrue);
    });

    testWidgets('切歌卸载重挂后省电模式自动恢复（无需重新开关）', (tester) async {
      await prepareEcoOn();
      final songA = <LyricLine>[wordLine(0)];
      final songB = <LyricLine>[wordLine(0), wordLine(60000)];

      // 歌曲 A：挂载即 eco Timer 驱动
      await tester.pumpWidget(host(songA));
      expect(viewState(tester).ecoDriverIsTimerForTest, isTrue);

      // 切歌 loading：歌词视图卸载（dispose 应取消 Timer）
      await tester.pumpWidget(host(null));

      // 新歌重挂：应立即重建 60fps Timer，无需重新开关省电模式
      await tester.pumpWidget(host(songB));
      expect(viewState(tester).ecoDriverIsTimerForTest, isTrue,
          reason: '重挂载后应立即重建 60fps Timer（切歌后省电失效回归护栏）');
      expect(viewState(tester).ecoUnlockedForTest, isFalse);

      // 推进若干 Timer tick：驱动持续工作且保持锁定（不漂移回满帧 Ticker）
      const step = Duration(milliseconds: 16);
      for (int i = 0; i < 60; i++) {
        await tester.pump(step);
      }
      expect(viewState(tester).ecoDriverIsTimerForTest, isTrue,
          reason: '播放逐字歌词期间应持续锁定 60fps Timer 驱动');
    });
  });

  group('AppleLyricsView 间奏点：跳转离开时自动收起（穿帮回归）', () {
    // 行 0 结束于 1000ms，行 1 起始 30000ms → 间隔 29s ≥ 4000ms 阈值，
    // 存在间奏窗口 [1000, 29750)（间奏时长 28750ms，消失动画起点 = 28000ms）。
    List<LyricLine> interludeLines() => <LyricLine>[
          LyricLine(startTime: 0, duration: 1000, text: 'Line 1'),
          LyricLine(startTime: 30000, duration: 1000, text: 'Line 2'),
        ];

    const step = Duration(milliseconds: 16);

    Future<void> pumpFrames(WidgetTester tester, int n) async {
      for (int i = 0; i < n; i++) {
        await tester.pump(step);
      }
    }

    /// 挂载固定尺寸（800x600 → fontSize=64、lineHeight=76.8）的歌词视图。
    ///
    /// 位置由外部 [pos] 驱动（真实播放中为 playerProvider.positionNotifier）。
    Future<void> mount(
      WidgetTester tester,
      ValueNotifier<Duration> pos, {
      void Function(int ms)? onSeek,
    }) async {
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
                lines: interludeLines(),
                currentTimeMs: 0,
                positionListenable: pos,
                isPlaying: true,
                onSeek: onSeek,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('间奏点动画中点击其他行：间奏点立即清除，不再悬浮残留', (tester) async {
      int? seekTime;
      final pos = ValueNotifier<Duration>(Duration.zero);
      addTearDown(pos.dispose);
      await mount(tester, pos, onSeek: (ms) {
        seekTime = ms;
        pos.value = Duration(milliseconds: ms); // 模拟真实 seek 后的位置跳变
      });

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;

      // 播放推进到间奏早期（2s，处于窗口内且远早于消失阶段）
      pos.value = const Duration(milliseconds: 2000);
      await pumpFrames(tester, 60);

      expect(state.interludeDotsActiveForTest, isTrue,
          reason: '间奏窗口内应显示间奏点');
      expect(state.interludeDotsInExitPhaseForTest, isFalse,
          reason: '此时间奏点仍在入场/呼吸阶段，远早于消失阶段（末 750ms）');

      // 点击第 2 行（index=1）：posY ≈ 171.6（第 1 行居中），间奏占位高度 76.8，
      // 第 2 行 top = 76.8 + 76.8 + 171.6 = 325.2，中心 y ≈ 363.6
      await tester.tapAt(const Offset(400, 363));
      await tester.pump(step);

      expect(seekTime, 30000, reason: '点击应命中第 2 行并跳转到其 startTime');
      expect(state.interludeDotsActiveForTest, isFalse,
          reason: '跳转离开间奏后间奏点必须立即清除'
              '（旧实现会让满尺寸圆点悬浮在原 anchor 行 ~750ms → 穿帮）');

      // 占位仍由 progress 平滑收起，不会让下方行瞬间跳位
      await pumpFrames(tester, 80);
      expect(state.interludeExpandProgressForTest, 0);
      expect(state.interludeDotsActiveForTest, isFalse);

      // 排空 AppHaptics 兜底定时器
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('自然结束：时钟已进入消失阶段时保留同步收起动画（不硬切）', (tester) async {
      final pos = ValueNotifier<Duration>(Duration.zero);
      addTearDown(pos.dispose);
      await mount(tester, pos);
      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;

      pos.value = const Duration(milliseconds: 2000);
      await pumpFrames(tester, 30);
      expect(state.interludeDotsActiveForTest, isTrue);

      // 推进到间奏末尾：动画时钟按真实偏移对齐到消失阶段（28000ms）
      pos.value = const Duration(milliseconds: 29000);
      await pumpFrames(tester, 5);
      expect(state.interludeDotsInExitPhaseForTest, isTrue,
          reason: '间奏末尾时钟应对齐到消失阶段，而非仍停在早期');

      // 自然跨过窗口终点（next.startTime - 250 = 29750）
      pos.value = const Duration(milliseconds: 29900);
      await tester.pump(step);
      expect(state.interludeDotsActiveForTest, isTrue,
          reason: '自然结束应保留圆点消失动画与占位收起同步，而非立即清除');

      await pumpFrames(tester, 80);
      expect(state.interludeDotsActiveForTest, isFalse,
          reason: '占位收起完成后间奏点应清除');
      expect(state.interludeExpandProgressForTest, 0);
    });
  });

  // 回归：省电模式（eco）下 AM 歌词节奏点「最后收起」卡顿。
  //
  // 根因一（台阶卡顿，用例 1 直接护栏——曾实测该用例在旧的 30fps 累加器下失败）：
  // 间奏点时钟被「累加帧 dt、满 33ms 才推进一次」降频，而 eco 驱动按名义 16ms
  // 步进，`16 × 2 = 32ms` 不足 33.3ms 阈值 → 实际每 3 帧才推进一次（20fps）：
  // 收起 750ms 只剩 15 个缩放台阶，逐帧表现为"冻结-冻结-跳一大步"。
  //
  // 根因二（收尾瞬灭）：帧时钟被名义步长拖慢后系统性落后播放时钟，落后超过
  // 消失段时长（750ms）时 isInExitPhase 仍为 false，旧实现据此判定"用户跳转
  // 离开"立即 clear → 圆点没有缩小过程直接消失。该分支由
  // renderers/interlude_dots_test.dart 的 snapToExitPhase 组做确定性护栏
  // （可直接构造落后量，端到端里落后量受测试驱动步进影响、难以稳定复现）；
  // 本组用例 2/3 守护端到端语义：自然结束要播完消失动画，seek 离开仍要立即
  // 清除，两者不得被对方放宽。
  group('AppleLyricsView 节奏点收起（省电模式卡顿回归）', () {
    const step = Duration(milliseconds: 16);

    Future<void> pumpFrames(WidgetTester tester, int n) async {
      for (int i = 0; i < n; i++) {
        await tester.pump(step);
      }
    }

    Future<void> mountEco(
      WidgetTester tester,
      ValueNotifier<Duration> pos,
      List<LyricLine> lines,
    ) async {
      SharedPreferences.setMockInitialValues({'lyric_eco_mode': true});
      await LyricPreferences.instance.setEcoMode(true);
      addTearDown(() => LyricPreferences.instance.reset());
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
                positionListenable: pos,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('eco 锁定态下间奏点时钟逐帧推进（无冻结帧、无大台阶）',
        (tester) async {
      // 行 0 结束 1000ms、行 1 起始 11000ms → 间奏窗口 [1000, 10750)，时长 9750ms
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'Line 1'),
        LyricLine(startTime: 11000, duration: 1000, text: 'Line 2'),
      ];
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 5000));
      addTearDown(pos.dispose);
      await mountEco(tester, pos, lines);
      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;

      // 先推进到占位完全展开：此后 _updateInterlude 只在权威时间变化时运行，
      // 时钟只由帧 tick 推进，台阶可被干净观测。
      await pumpFrames(tester, 60);
      expect(state.ecoDriverIsTimerForTest, isTrue,
          reason: '前置条件：驱动源必须是 eco 限帧 Timer（名义 16ms 步长）');
      expect(state.interludeDotsActiveForTest, isTrue);
      expect(state.interludeExpandProgressForTest, greaterThan(0.99));

      int advancing = 0;
      double maxDelta = 0;
      double prev = state.interludeDotsAnimationMsForTest as double;
      for (int i = 0; i < 9; i++) {
        await tester.pump(step);
        final double now = state.interludeDotsAnimationMsForTest as double;
        final double delta = now - prev;
        if (delta > 0) advancing++;
        if (delta > maxDelta) maxDelta = delta;
        prev = now;
      }
      // 旧实现（3 帧一推进）：advancing≈3、maxDelta=48 → 两条断言都失败。
      expect(
        advancing,
        greaterThanOrEqualTo(7),
        reason: '间奏点时钟应逐帧推进；出现冻结帧即 30fps 降频在 eco 16ms '
            '步长下退化为 20fps 的台阶卡顿',
      );
      expect(maxDelta, lessThan(25.0),
          reason: '单次推进 $maxDelta ms 过大（冻结后一次性跳一大步）');
    });

    testWidgets('自然跨过窗口终点：圆点走完消失动画并在占位归零后清除',
        (tester) async {
      // 间奏窗口 [1000, 7000) → 时长 6000ms，消失段起点 = 6000-750 = 5250ms。
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'Line 1'),
        LyricLine(startTime: 7000, duration: 1000, text: 'Line 2'),
      ];
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 1000));
      addTearDown(pos.dispose);
      await mountEco(tester, pos, lines);
      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;

      // 激活间奏后，把权威时间推到窗口后段（>1000ms 滞后 → 触发一次性硬对齐，
      // 圆点落到消失段内），再以 positionStream 粒度（200ms）连续跨过终点。
      pos.value = const Duration(milliseconds: 6400);
      await tester.pump(step);
      expect(state.interludeDotsActiveForTest, isTrue);
      expect(state.interludeDotsInExitPhaseForTest, isTrue);

      pos.value = const Duration(milliseconds: 6900);
      await tester.pump(step);
      expect(state.interludeDotsActiveForTest, isTrue,
          reason: '仍在窗口 [1000,7000) 内');

      // 连续推进跨过终点（200ms 步长 = 非 seek）→ 自然结束：不得立即清除
      pos.value = const Duration(milliseconds: 7100);
      await tester.pump(step);
      expect(state.interludeDotsActiveForTest, isTrue,
          reason: '自然结束应保留消失动画，与占位收起同步播完');
      expect(
        state.interludeDotsAnimationMsForTest as double,
        greaterThanOrEqualTo(5250),
        reason: '时钟不得后退，也不得被拽回窗口前',
      );

      // 消失动画走完 + 占位收起归零后圆点才被释放
      await pumpFrames(tester, 120);
      expect(state.interludeDotsActiveForTest, isFalse,
          reason: '占位完全收起后间奏点应清除（不得长期悬空）');
      expect(state.interludeExpandProgressForTest, 0);
    });

    testWidgets('seek 大跳离开间奏：仍立即清除（不得被自然结束分支放宽）',
        (tester) async {
      final lines = <LyricLine>[
        LyricLine(startTime: 0, duration: 1000, text: 'Line 1'),
        LyricLine(startTime: 7000, duration: 1000, text: 'Line 2'),
      ];
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 2000));
      addTearDown(pos.dispose);
      await mountEco(tester, pos, lines);
      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;

      await pumpFrames(tester, 10);
      expect(state.interludeDotsActiveForTest, isTrue);

      // 时间一次跳变 >500ms（seek / 点击其他行）离开间奏窗口
      pos.value = const Duration(milliseconds: 20000);
      await tester.pump(step);

      expect(state.interludeDotsActiveForTest, isFalse,
          reason: '跳转离开必须立即清除，否则满尺寸圆点悬浮在已切换的歌词上');
      await pumpFrames(tester, 80);
      expect(state.interludeExpandProgressForTest, 0);
    });
  });

  group('AppleLyricsView 副行过长换行：行距预留自适应', () {
    testWidgets('长翻译副行按换行后的视觉行数预留，短副行仍为单行', (tester) async {
      SharedPreferences.setMockInitialValues({});
      LyricPreferences.instance.reset();
      addTearDown(() => LyricPreferences.instance.reset());

      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longTranslation =
          '这是一句非常长的翻译副行文本用来验证换行之后的行距预留是否跟随视觉行数调整' * 2;
      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 2000,
          text: 'Line 1',
          translation: longTranslation,
        ),
        LyricLine(
          startTime: 2000,
          duration: 2000,
          text: 'Line 2',
          translation: '短副行',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(lines: lines, currentTimeMs: 0),
            ),
          ),
        ),
      );

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      final double trans = LyricLayout.translationFontSize(
        LyricPreferences.instance.fontSize,
      );
      final double singleRow =
          trans * LyricLayout.translationLineHeight + trans * 0.3;

      expect(state.auxSubHeightForTest(1), closeTo(singleRow, 0.001),
          reason: '短副行仍按单行预留，不应引入额外行距');
      expect(state.auxSubHeightForTest(0), greaterThan(singleRow),
          reason: '过长副行必须按换行后的行数预留高度，否则会压到下一行歌词');
      expect(
        state.auxSubHeightForTest(0),
        greaterThanOrEqualTo(
            2 * trans * LyricLayout.translationLineHeight + trans * 0.3 - 0.001),
        reason: '至少预留 2 行副行高度',
      );
    });

    testWidgets('切到罗马音显示后按 roma 文本行数重算预留', (tester) async {
      SharedPreferences.setMockInitialValues({});
      LyricPreferences.instance.reset();
      addTearDown(() => LyricPreferences.instance.reset());

      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 2000,
          text: 'Line 1',
          translation: '短翻译',
          roma: 'kore wa totemo nagai romaji no fukugyou desu ' * 8,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(lines: lines, currentTimeMs: 0),
            ),
          ),
        ),
      );

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      final double trans = LyricLayout.translationFontSize(
        LyricPreferences.instance.fontSize,
      );
      final double singleRow =
          trans * LyricLayout.translationLineHeight + trans * 0.3;

      expect(state.auxSubHeightForTest(0), closeTo(singleRow, 0.001),
          reason: '翻译模式：短翻译按单行预留');

      await LyricPreferences.instance.setDisplayMode(LyricDisplayMode.roma);
      await tester.pump();

      expect(state.auxSubHeightForTest(0), greaterThan(singleRow),
          reason: '罗马音模式：过长 roma 必须按换行行数重新预留');
    });
  });

  group('AppleLyricsView sweep（扫光）字内渐变', () {
    testWidgets('sweep 模式下 sweepFrontDebug 非负且随进度推进', (tester) async {
      // 偏好置 sweep（现为默认，classic 分支断言见其它用例，互不影响）
      SharedPreferences.setMockInitialValues({'lyric_fill_mode': 'sweep'});
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      addTearDown(() => LyricPreferences.instance.reset());
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);

      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final lines = <LyricLine>[
        LyricLine(
          startTime: 0,
          duration: 4000,
          text: '扫光测试',
          words: const [
            LyricWord(startTime: 0, duration: 1000, text: '扫'),
            LyricWord(startTime: 1000, duration: 1000, text: '光'),
            LyricWord(startTime: 2000, duration: 1000, text: '测'),
            LyricWord(startTime: 3000, duration: 1000, text: '试'),
          ],
        ),
        // 第二行只为让 `hasTimestamps`（any startTime > 0）成立——
        // 全行 startTime=0 时 AppleLyricsView 视作纯文本、不启用 WordRenderer。
        const LyricLine(startTime: 4000, duration: 2000, text: '第二行'),
      ];

      Widget build(int timeMs) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: AppleLyricsView(
                  lines: lines,
                  currentTimeMs: timeMs,
                  isPlaying: true,
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(500));
      // 多泵几帧：Ticker 首帧 dt=0 不推进，且渲染器在 _onTick 的渲染循环里创建
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      final double early = state.sweepFrontForTest(0) as double;
      expect(early.isNaN, isFalse, reason: '当前行应已绘制并记录 sweep 前端');
      expect(early, greaterThanOrEqualTo(0));

      // 推进到第 3 个字（权威时间跳变 > 500ms 会吸附，相位随之前进）
      await tester.pumpWidget(build(2500));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final double later = state.sweepFrontForTest(0) as double;
      expect(later, greaterThanOrEqualTo(0));
      expect(later, greaterThan(early), reason: '扫光前端应随播放进度向右推进');
    });
  });

  group('AppleLyricsView 鼠标滚轮滚动（Windows 桌面）', () {
    // 滚轮事件不走拖拽手势竞技场，需模拟鼠标设备派发 PointerScrollEvent
    Future<void> sendWheel(WidgetTester tester, double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse)
        ..hover(tester.getCenter(find.byType(AppleLyricsView)));
      // sendEventToBinding 是 guarded API，必须 await
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    }

    testWidgets('滚轮向下：posY 减小（看后面的行），5s 后自动回弹', (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final lines = <LyricLine>[
        for (int i = 0; i < 10; i++)
          LyricLine(startTime: i * 2000, duration: 2000, text: '第 $i 行'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(lines: lines, currentTimeMs: 500),
          ),
        ),
      );
      // 泵若干帧让首次定位瞬移完成（弹簧就位）
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      final controller = state.scrollControllerForTest as dynamic;
      final double posBefore = controller.posY as double;

      // 滚轮向下 100（scrollDelta.dy=100）→ posY 减小
      await sendWheel(tester, 100);
      expect(controller.isWaitingForAutoReturn, isTrue,
          reason: '滚轮后应进入 5s 自动回弹倒计时');
      // 推进 500ms：弹簧向目标滚过去（500ms 内不能已回弹）
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect((controller.posY as double), lessThan(posBefore),
          reason: '滚轮向下应看到更靠后的行（posY 变小）');

      // 推过 5s 倒计时 + 回弹弹簧收敛：posY 回到滚轮前位置
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect((controller.posY as double), closeTo(posBefore, 2),
          reason: '5s 无操作后应自动回弹到当前行');
    });

    testWidgets('按住 Shift 滚轮：歌词不滚（让位给外层 PageView 横向切页）',
        (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final lines = <LyricLine>[
        for (int i = 0; i < 10; i++)
          LyricLine(startTime: i * 2000, duration: 2000, text: '第 $i 行'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppleLyricsView(lines: lines, currentTimeMs: 500),
          ),
        ),
      );
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      final controller = state.scrollControllerForTest as dynamic;
      final double posBefore = controller.posY as double;

      // 按住左 Shift 派发滚轮：歌词视图必须忽略（不进入回弹倒计时）
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await sendWheel(tester, 100);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(controller.isWaitingForAutoReturn, isFalse,
          reason: 'Shift+滚轮应让位给外层横向切页，歌词不进入滚动状态');
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect((controller.posY as double), closeTo(posBefore, 2),
          reason: 'Shift+滚轮后歌词位置不应变化');

      // 松开 Shift 后普通滚轮恢复正常
      await sendWheel(tester, 100);
      expect(controller.isWaitingForAutoReturn, isTrue,
          reason: '松开 Shift 后滚轮应恢复歌词滚动');
    });
  });
}

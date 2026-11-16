import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「提前换行」的门控测试。
///
/// 钉住三条契约：开关关闭零回归、仅 KRC 逐字行生效（LRC 保持原行为）、
/// 等待期视觉激活冻结并在真实音频边界解除。
/// 时间一律通过 [ValueNotifier] 位置通知器推进（与真实播放链路一致：
/// didUpdateWidget 不会因静态 currentTimeMs 变化而更新权威时间）。
const List<LyricLine> krcLines = <LyricLine>[
  LyricLine(
    startTime: 0,
    duration: 2000,
    text: '第一行',
    words: <LyricWord>[
      LyricWord(startTime: 100, duration: 1600, text: '第一行'),
    ],
  ),
  LyricLine(
    startTime: 3000,
    duration: 2000,
    text: '第二行',
    words: <LyricWord>[
      LyricWord(startTime: 3100, duration: 1600, text: '第二行'),
    ],
  ),
  LyricLine(
    startTime: 6000,
    duration: 2000,
    text: '第三行',
    words: <LyricWord>[
      LyricWord(startTime: 6100, duration: 1600, text: '第三行'),
    ],
  ),
];

/// 带间奏的两行歌词：人声 1700 结束、下一行 6000 开唱 → gap 4300ms，
/// 超过间奏阈值（4000），会生成间奏圆点与占位。
const List<LyricLine> krcLinesWithInterlude = <LyricLine>[
  LyricLine(
    startTime: 0,
    duration: 2000,
    text: '第一行',
    words: <LyricWord>[
      LyricWord(startTime: 100, duration: 1600, text: '第一行'),
    ],
  ),
  LyricLine(
    startTime: 6000,
    duration: 2000,
    text: '第二行',
    words: <LyricWord>[
      LyricWord(startTime: 6100, duration: 1600, text: '第二行'),
    ],
  ),
];

const List<LyricLine> lrcLines = <LyricLine>[
  LyricLine(startTime: 0, duration: 2000, text: '第一行'),
  LyricLine(startTime: 3000, duration: 2000, text: '第二行'),
  LyricLine(startTime: 6000, duration: 2000, text: '第三行'),
];

void main() {
  late ValueNotifier<Duration> position;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.setEarlyLineSwitch(false);
    position = ValueNotifier<Duration>(Duration.zero);
  });

  Future<dynamic> pumpAt(
    WidgetTester tester,
    List<LyricLine> lines,
    int timeMs, {
    bool fresh = false,
  }) async {
    position.value = Duration(milliseconds: timeMs);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: AppleLyricsView(
            key: ValueKey<String>('$fresh'),
            lines: lines,
            currentTimeMs: timeMs,
            positionListenable: position,
            isPlaying: true,
          ),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    return tester.state(find.byType(AppleLyricsView));
  }

  testWidgets('开关关闭：间奏末尾不进入预换行（零回归）', (tester) async {
    final state = await pumpAt(tester, krcLines, 2800);
    expect(state.earlySwitchTargetForTest, equals(-1));
    expect(state.visualHoldForTest, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('LRC 无逐字时间戳：开关开启也保持原行为', (tester) async {
    await LyricPreferences.instance.setEarlyLineSwitch(true);
    final state = await pumpAt(tester, lrcLines, 2800);
    expect(state.earlySwitchTargetForTest, equals(-1));
    expect(state.visualHoldForTest, isFalse);
    await LyricPreferences.instance.setEarlyLineSwitch(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('KRC：提前点进入等待、真实边界解除冻结', (tester) async {
    await LyricPreferences.instance.setEarlyLineSwitch(true);
    await LyricPreferences.instance.setUseGaussianBlur(true);

    // 提前点 = 该行逐字唱完时刻 1700（距下一行 3000 有 1300ms，够一次换行）
    final waiting = await pumpAt(tester, krcLines, 2800);
    expect(waiting.earlySwitchTargetForTest, equals(1),
        reason: '2800ms 应已把布局行提前到第 1 行');
    expect(waiting.visualHoldForTest, isTrue,
        reason: '等待期清晰层/缩放必须保持冻结');

    // 通过位置通知器推进到真实边界，走与播放时相同的权威时间更新链路。
    position.value = const Duration(milliseconds: 3000);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(waiting.authorityTimeMsForTest, equals(3000));
    expect(waiting.earlySwitchTargetForTest, equals(-1),
        reason: '真实音频边界到达后等待期必须结束');
    expect(waiting.visualHoldForTest, isFalse);

    // 激活帧必须把当前行从模糊等级缓存里移除，否则模糊图会与刚亮起的
    // 字内渐变叠成重影；同时用独立的短淡出把这张图收掉。
    expect(waiting.blurLevelsForTest.containsKey(1), isFalse,
        reason: '当前行不应再保留模糊等级');
    expect(waiting.entryBlurProgressForTest, lessThan(1.0),
        reason: '当前行模糊图应进入淡出，而不是硬切残留');
    // 淡出由「该行演唱进度」驱动（与字内渐变同一时间轴、与清晰层互补）：
    // 推进到行中段，模糊层应同步退到中间值，而不是按固定时长提前撤完。
    position.value = const Duration(milliseconds: 3800);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(waiting.entryBlurProgressForTest, greaterThan(0.1),
        reason: '行初段模糊层应已开始退去');
    expect(waiting.entryBlurProgressForTest, lessThan(0.9),
        reason: '字未亮满前模糊层不得撤完，否则整行会先暗一下再亮');

    await LyricPreferences.instance.setEarlyLineSwitch(false);
    await LyricPreferences.instance.setUseGaussianBlur(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长间奏：等待期多帧稳定，不闪回原行', (tester) async {
    await LyricPreferences.instance.setEarlyLineSwitch(true);
    // 人声结束 1700、下一行 3000 → 空档 1300ms，超过旧作废判据的 1s 阈值，
    // 正是「进入等待那一帧就作废 → 下一帧重建 → 逐帧闪烁」的复现场景。
    final state = await pumpAt(tester, krcLines, 1700);
    expect(state.earlySwitchTargetForTest, equals(1),
        reason: '人声一唱完就应进入等待');
    expect(state.currentLineIndexForTest, equals(1));

    // 按 positionStream 的 ~200ms 粒度逐次推进到开唱前。
    for (var t = 1900; t <= 2900; t += 200) {
      position.value = Duration(milliseconds: t);
      await tester.pump(const Duration(milliseconds: 16));
      expect(state.earlySwitchTargetForTest, equals(1),
          reason: 't=$t 长间奏不得作废等待（绝对距离判据会恒成立）');
      expect(state.currentLineIndexForTest, equals(1),
          reason: 't=$t 布局行必须停在目标行，不能来回闪烁');
      expect(state.visualHoldForTest, isTrue);
    }

    await LyricPreferences.instance.setEarlyLineSwitch(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('间奏点：提前换行后仍保持激活（不被撤销）', (tester) async {
    await LyricPreferences.instance.setEarlyLineSwitch(true);
    // 人声 1700 结束 → 进入等待并把布局提前到第 1 行；此时间奏窗口
    // [1700, 5750) 尚未结束，圆点与占位必须照常存在。
    final state = await pumpAt(tester, krcLinesWithInterlude, 2200, fresh: true);
    expect(state.earlySwitchTargetForTest, equals(1),
        reason: '应已提前换行到第 1 行');
    expect(state.interludeDotsActiveForTest, isTrue,
        reason: '提前换行不得撤销间奏圆点');
    expect(state.interludeExpandProgressForTest, greaterThan(0.0),
        reason: '间奏占位应保持展开（当前行随之下移一个占位高度）');

    await LyricPreferences.instance.setEarlyLineSwitch(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('偏好：模糊褪去时长', () {
    test('默认 600ms；setter clamp 到 100~1000；reset 复位', () async {
      final prefs = LyricPreferences.instance;
      await prefs.setEntryBlurFadeMs(LyricPreferences.defaultEntryBlurFadeMs);
      expect(prefs.entryBlurFadeMs, 600.0);

      await prefs.setEntryBlurFadeMs(10);
      expect(prefs.entryBlurFadeMs, LyricPreferences.minEntryBlurFadeMs,
          reason: '低于下限应 clamp 到 100ms');
      await prefs.setEntryBlurFadeMs(5000);
      expect(prefs.entryBlurFadeMs, LyricPreferences.maxEntryBlurFadeMs,
          reason: '高于上限应 clamp 到 1000ms');

      await prefs.reset();
      expect(prefs.entryBlurFadeMs, LyricPreferences.defaultEntryBlurFadeMs,
          reason: '「恢复本页默认值」必须一并复位');
    });
  });

  testWidgets('褪去时长滑块：上限生效（300ms 内退完）', (tester) async {
    await LyricPreferences.instance.setEarlyLineSwitch(true);
    await LyricPreferences.instance.setUseGaussianBlur(true);
    await LyricPreferences.instance.setEntryBlurFadeMs(300);

    // 先在人声结束时进入等待，再推进到真实边界触发激活（入场淡出起点）。
    final state = await pumpAt(tester, krcLines, 1700);
    expect(state.earlySwitchTargetForTest, equals(1));
    position.value = const Duration(milliseconds: 3000);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.entryBlurProgressForTest, lessThan(1.0),
        reason: '激活帧模糊层应重新出现（progress 归零后开始退）');

    // 22 帧 ≈ 352ms（加上前面 6 帧共约 450ms）：超过 300ms 上限必须退完。
    for (var i = 0; i < 22; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.entryBlurProgressForTest, equals(1.0),
        reason: '褪去时长 300ms 时应在此之内退完，不随该行演唱进度拖到行末');

    await LyricPreferences.instance
        .setEntryBlurFadeMs(LyricPreferences.defaultEntryBlurFadeMs);
    await LyricPreferences.instance.setEarlyLineSwitch(false);
    await LyricPreferences.instance.setUseGaussianBlur(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

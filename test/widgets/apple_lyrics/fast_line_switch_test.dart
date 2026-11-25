/// 快速连切兜底回归测试。
///
/// Bug 现象：AM 歌词页当前行连续快速切换（间隔 < 0.3s）时，级联错峰延迟
///（60~750ms）永远等不到释放，等待行被抵消量一直钉住，整块歌词视觉「卡住」。
///
/// 修复口径：两次当前行切换的帧时钟间隔 < 300ms 时跳过弹簧过渡，
/// posY / 缩放 / 级联偏移直接到位；间隔恢复后重新走弹簧路径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 每行 120ms 的逐字行（有 word timing → 播放中 Ticker 不会停帧省电）
  const int lineMs = 120;
  List<LyricLine> buildLines(int n) => List<LyricLine>.generate(n, (int i) {
        final int start = i * lineMs;
        return LyricLine(
          startTime: start,
          duration: lineMs,
          text: '第 $i 行',
          words: <LyricWord>[
            LyricWord(startTime: start, duration: lineMs, text: '第 $i 行'),
          ],
        );
      });

  Future<void> pumpFrames(WidgetTester tester, int frames) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LyricPreferences.instance.reset();
  });

  tearDown(() {
    LyricPreferences.instance.reset();
  });

  testWidgets('连续两次快速切行才走兜底，间隔恢复后弹簧重新参与', (tester) async {
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: AppleLyricsView(
              lines: buildLines(40),
              currentTimeMs: 0,
              isPlaying: true,
              positionListenable: position,
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, 5);
    final dynamic state = tester.state(find.byType(AppleLyricsView));

    // 第 1 次快速切行（第 0 → 1 行，间隔 < 300ms）：仅计数 1，仍走弹簧
    position.value = const Duration(milliseconds: 130);
    await pumpFrames(tester, 1);

    expect(state.lastSwitchWasFastForTest as bool, isFalse,
        reason: '单次快速切行不应触发兜底');
    expect(
      (state.scrollPosYForTest as double) -
          (state.scrollTargetForTest as double),
      isNot(closeTo(0, 1e-6)),
      reason: '单次快速切行应保留弹簧过渡',
    );

    // 第 2 次快速切行（第 1 → 2 行，间隔仍 < 300ms）：连续 2 次 → 兜底直接切行
    position.value = const Duration(milliseconds: 250);
    await pumpFrames(tester, 1);

    expect(state.lastSwitchWasFastForTest as bool, isTrue,
        reason: '连续两次切行间隔 < 300ms 应走快速兜底');
    expect(
      state.scrollPosYForTest as double,
      closeTo(state.scrollTargetForTest as double, 1e-6),
      reason: '快速兜底应直接切到新行位置，不产生弹簧过渡',
    );
    expect(
      state.lineScaleForTest(2) as double,
      closeTo(LyricLayout.activeScale, 0.001),
      reason: '快速兜底应直接把新当前行缩放到 activeScale',
    );

    // 间隔恢复到 > 300ms 后再切到第 3 行 → 计数清零，回到弹簧路径
    await pumpFrames(tester, 25);
    position.value = const Duration(milliseconds: 370);
    await pumpFrames(tester, 1);

    expect(state.lastSwitchWasFastForTest as bool, isFalse,
        reason: '切行间隔 >= 300ms 应清零计数，不触发快速兜底');
    expect(
      (state.scrollPosYForTest as double) -
          (state.scrollTargetForTest as double),
      isNot(closeTo(0, 1e-6)),
      reason: '正常切行应保留弹簧过渡（首帧尚未到位）',
    );

    // 弹簧继续推进后应收敛到新行目标
    await pumpFrames(tester, 200);
    expect(
      state.scrollPosYForTest as double,
      closeTo(state.scrollTargetForTest as double, 0.5),
      reason: '正常切行的弹簧应在若干帧内收敛到目标',
    );
  });
}

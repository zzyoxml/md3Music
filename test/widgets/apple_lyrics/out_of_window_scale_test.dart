/// AppleLyricsView「scale tick 窗口外的行钉稳态 inactive」回归测试。
///
/// Bug 根因:`_tickPerLineScales` 只推进/写入当前行 ± `_overscan` 窗口内的
/// 槽位,而 `_reusedPerLineScales` 建表时填的是 `activeScale`(1.0)。
/// 绘制循环按视口二分裁剪(`_LyricsPainter.paint`),与当前行无关——
/// 用户手动滚动到远离当前行的区域时,窗口外的行从未被写入,以 1.0 全尺寸
/// 显示,即"滚动查看歌词时底部出现没缩小的行"。
///
/// 修复口径:窗口外的行恒钉在稳态 inactive(`LyricLayout.inactiveScale`
/// 钳可读下限;enableScale=false 时为 activeScale),已存在的弹簧同时瞬移
/// 到稳态,防止该行重新进入窗口时从旧位置(如曾为当前行的 1.0)弹跳。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 辅助:泵送多帧让驱动源(Ticker/eco Timer)推进 _onTick。
  // 与 test/widgets/apple_lyrics/apple_lyrics_view_test.dart 的同名辅助同法。
  Future<void> pumpFrames(WidgetTester tester, int frames) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  // 每行 1s 的纯文本行(无 word timing,走 LineRenderer 整行模式),
  // 第 i 行时间区间 = [i*1000, (i+1)*1000) ms。
  List<LyricLine> buildLines(int n) => List<LyricLine>.generate(
        n,
        (int i) => LyricLine(
          startTime: i * 1000,
          duration: 1000,
          text: 'Lyric line $i',
        ),
      );

  Future<void> pumpView(
    WidgetTester tester, {
    required List<LyricLine> lines,
    int currentTimeMs = 0,
    bool enableScale = true,
    ValueListenable<Duration>? positionListenable,
    bool isPlaying = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: AppleLyricsView(
              lines: lines,
              currentTimeMs: currentTimeMs,
              isPlaying: isPlaying,
              enableScale: enableScale,
              positionListenable: positionListenable,
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LyricPreferences.instance.reset();
  });

  tearDown(() {
    LyricPreferences.instance.reset();
  });

  group('scale tick 窗口外的行钉稳态', () {
    testWidgets('窗口外行 scale = inactiveScale,不再是初始 1.0', (tester) async {
      // 60 行、当前行 0(默认 overscan=10)→ 第 30 行在窗口外。
      await pumpView(tester, lines: buildLines(60));
      await pumpFrames(tester, 30);

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      final double far = state.lineScaleForTest(30) as double;
      expect(far.isNaN, isFalse, reason: '至少应有一帧 tick 建立过 scale 列表');
      expect(
        far,
        closeTo(LyricLayout.inactiveScale, 0.01),
        reason: '窗口外非当前行必须钉在稳态 inactive,不能保持初始 1.0',
      );
      // 窗口内基线不回归:非当前行 inactive、当前行 1.0。
      expect(
        state.lineScaleForTest(5) as double,
        closeTo(LyricLayout.inactiveScale, 0.01),
      );
      expect(
        state.lineScaleForTest(0) as double,
        closeTo(LyricLayout.activeScale, 0.001),
      );
    });

    testWidgets('enableScale=false 时窗口外行不缩小(= 1.0)', (tester) async {
      // 修复前该用例即通过(窗口外恰好停留 1.0),属于修复口径护栏:
      // 防止钉稳态时漏掉 enableScale 分支把窗口外行错缩到 0.85。
      await pumpView(tester, lines: buildLines(60), enableScale: false);
      await pumpFrames(tester, 30);

      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      expect(
        state.lineScaleForTest(30) as double,
        closeTo(LyricLayout.activeScale, 0.001),
        reason: '关闭缩小开关后窗口外行必须保持 1.0,不得被钉到 inactive',
      );
    });

    testWidgets('远跳后旧行被钉稳态;跳回时从稳态起弹、无 1.0 硬切', (tester) async {
      final lines = buildLines(60);
      final position = ValueNotifier<Duration>(Duration.zero);
      addTearDown(position.dispose);

      // 真实页面(full_player_am)经 positionListenable 供时,isPlaying=true
      // 才能让 _onExternalPosition 在 seek 后唤醒驱动源,与线上路径一致。
      await pumpView(
        tester,
        lines: lines,
        positionListenable: position,
        isPlaying: true,
      );
      await pumpFrames(tester, 30);

      // 远跳到第 50 行(50.5s):第 0 行滑出窗口。
      position.value = const Duration(milliseconds: 50500);
      await pumpFrames(tester, 60);
      final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
      expect(
        state.lineScaleForTest(0) as double,
        closeTo(LyricLayout.inactiveScale, 0.01),
        reason: '曾作为当前行的第 0 行滑出窗口后必须钉到稳态,不能残留 1.0',
      );

      // 跳回第 0 行:重进窗口应从稳态 0.85 起弹(进场动画),
      // 首帧不得先硬切回 1.0 再缩(穿帮)。
      position.value = Duration.zero;
      await tester.pump();
      final double reentry = state.lineScaleForTest(0) as double;
      expect(reentry, lessThan(0.95), reason: '重进窗口首帧应从稳态 0.85 起弹');
      await pumpFrames(tester, 90);
      expect(
        state.lineScaleForTest(0) as double,
        closeTo(LyricLayout.activeScale, 0.02),
      );
    });
  });
}

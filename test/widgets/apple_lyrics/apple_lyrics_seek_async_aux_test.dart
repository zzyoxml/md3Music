/// 确定性回归：副行几何不变量的逐帧断言（pump 驱动，不依赖真机帧率）。
///
/// 针对「间歇性压行」的真机复现场景建模（《Summer Solstice》实测形态）：
/// - 过滤后**首行起唱很早**（< 间奏阈值，无头部间奏槽位）；
/// - 逐字英文主行（KRC words）+ 中文翻译；
/// - 翻译**异步晚到**（挂载时无翻译，行展开途中才合并）；
/// - 展开途中经历**连续 seek**（前进 / 后退）穿过多行。
///
/// 每帧计算「副行底边 vs 次行顶边」差值（同真机 PITCHDBG 公式），仅在画面
/// 收敛态（无副行动画 / 无间奏占位 / 滚动收敛 / 无级联窗口）计入违规：
/// 稳态下该差值的理论值恒为 −0.3em（副行字号，= 下方呼吸余量）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const step = Duration(milliseconds: 16);

  /// 真机《Summer Solstice》形状：标题块被隐藏作者信息滤掉后，首行在 ~800ms
  /// 起唱（无头部间奏）；含一处行间间奏；翻译文本足够长以折行。
  List<LyricLine> translatedLines() => <LyricLine>[
        LyricLine(
          startTime: 800,
          duration: 3200,
          text: 'Summer solstice fire',
          translation: '夏至的篝火与燃烧的记忆',
          words: [
          LyricWord(startTime: 800, duration: 350, text: 'Summer'),
            LyricWord(startTime: 1150, duration: 380, text: 'solstice'),
            LyricWord(startTime: 1530, duration: 420, text: 'fire'),
            LyricWord(startTime: 1950, duration: 1250, text: 'and more'),
        ],
        ),
        LyricLine(
          startTime: 5200,
          duration: 2800,
          text: 'Lights along the shore',
          translation: '海岸线上的灯火',
        ),
        LyricLine(
          startTime: 18000,
          duration: 3000,
          text: 'Dance until dawn',
          translation: '跳到晨光降临',
        ),
        LyricLine(
          startTime: 34000,
          duration: 2600,
          text: 'Heartbeats keep rhythm',
          translation: '心跳延续着节拍',
        ),
      ];

  /// 挂载时的「首包」歌词：无翻译（模拟云翻译异步晚到）。
  List<LyricLine> firstPacketLines() => translatedLines()
      .map((l) => l.copyWith(clearTranslation: true))
      .toList();

  Future<dynamic> mountHost(
    WidgetTester tester,
    ValueNotifier<Duration> pos,
    List<LyricLine> lines,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: _Host(
          pos: pos,
          lines: lines,
          childBuilder: (lines) => AppleLyricsView(
            key: const ValueKey('main'),
            lines: lines,
            currentTimeMs: 0,
            positionListenable: pos,
            isPlaying: true,
          ),
        ),
      ),
    );
    return tester.state(find.byType(AppleLyricsView));
  }

  /// 是否处于几何可判定的收敛态：副行动画 / 间奏占位 / 滚动弹簧 /
  /// 级联窗口全部静止。不满足时跳过判定（过渡期相对位移属设计行为）。
  bool settled(dynamic s) {
    final double py = s.scrollPosYForTest as double;
    final double ty = s.scrollTargetForTest as double;
    return s.auxAnimatingForTest == false &&
        s.interludeAnchorIndexForTest == -2 &&
        (py - ty).abs() < 0.05 &&
        s.cascadeRoundActiveForTest == false;
  }

  /// 第 i 行副行底边与第 i+1 行顶边的实际间距（正=越界）。
  /// 公式与真机 PITCHDBG 一致：y_i + h_i + gap + auxH_i(p−1) + modelRows_i − y_{i+1}。
  double pairDiff(dynamic s, int i, double fs) {
    final double transFs = LyricLayout.translationFontSize(fs);
    final double posY = s.scrollPosYForTest as double;
    final double y0Screen = s.lineScreenYForTest(i) as double;
    final double y1Screen = s.lineScreenYForTest(i + 1) as double;
    final double intOff0 = s.interludeOffsetBeforeForTest(i) as double;
    final double intOff1 = s.interludeOffsetBeforeForTest(i + 1) as double;
    final double dlt0 = s.auxDeltaBeforeForTest(i) as double;
    final double dlt1 = s.auxDeltaBeforeForTest(i + 1) as double;
    // 收敛态下无级联偏移，tops = 屏 y − 间奏偏移 − 副行累计 − posY
    final double tops0 = y0Screen - intOff0 - dlt0 - posY;
    final double tops1 = y1Screen - intOff1 - dlt1 - posY;
    // 单视觉行主文本：行高 = 字号 × lineHeight（与间奏占位同口径）
    final double mainH = s.interludePlaceholderHeightForTest as double;
    final double p = s.auxProgressForTest(i) as double;
    final double auxH = s.auxSubHeightForTest(i) as double;
    // 副行行内容高度：单行翻译（此处夹具翻译均单行）
    final double modelRows = transFs * LyricLayout.translationLineHeight;
    final double auxBottom =
        tops0 + mainH + transFs * 0.3 + auxH * (p - 1.0) + modelRows;
    return auxBottom - tops1;
  }

  group('副行几何不变量：早首行 + 异步翻译 + 连续 seek（确定性）', () {
    testWidgets('全程收敛帧不得越界（差值恒 ≈ −0.3em）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 200));
      addTearDown(pos.dispose);
      final s = await mountHost(tester, pos, firstPacketLines()) as dynamic;

      final List<String> violations = <String>[];
      void scan(String tag) {
        if (!settled(s)) return;
        final double fs = LyricPreferences.instance.fontSize;
        for (var i = 0; i + 1 < 4; i++) {
          final double d = pairDiff(s, i, fs);
          if (d > 0.5) {
            violations.add(
                '$tag li=$i diff=${d.toStringAsFixed(2)} '
                'p=${s.auxProgressForTest(i)} '
                'cur=${s.currentLineIndexForTest}');
          }
        }
      }

      // —— 阶段 1：首包（无翻译）播放到首行稳定
      for (var n = 0; n < 60; n++) {
        await tester.pump(step);
        scan('phase1');
      }
      expect(s.auxTargetForTest(0), 0.0,
          reason: '无翻译时目标必须为 0');

      // —— 阶段 2：翻译异步合并（模拟第二包到达），首行开始展开
      await tester.pumpWidget(
        MaterialApp(
          home: _Host(
            pos: pos,
            lines: translatedLines(),
            childBuilder: (lines) => AppleLyricsView(
              key: const ValueKey('main'),
              lines: lines,
              currentTimeMs: 0,
              positionListenable: pos,
              isPlaying: true,
            ),
          ),
        ),
      );
      for (var n = 0; n < 90; n++) {
        await tester.pump(step);
        scan('phase2');
      }
      expect(s.auxTargetForTest(0), 1.0,
          reason: '翻译合并后首行目标必须立即变为 1');

      // —— 阶段 3：前进 seek 穿过行间间奏再回来（连续跳）
      for (final target in <int>[12000, 36000, 6000]) {
        pos.value = Duration(milliseconds: target);
        for (var n = 0; n < 80; n++) {
          await tester.pump(step);
          scan('seek$target');
        }
      }

      // —— 阶段 4：回退 seek 到首行展开中途，观察收起/再展开交接
      pos.value = const Duration(milliseconds: 1500);
      for (var n = 0; n < 120; n++) {
        await tester.pump(step);
        scan('phase4');
      }

      expect(
        violations,
        isEmpty,
        reason: violations.isEmpty
            ? '所有收敛帧的副行底边均在次行顶上方 ≥0.7em 处'
            : '以下帧出现副行越过次行顶部：${violations.take(12).join(" | ")}',
      );

      // —— 阶段 5：最大堆叠压力（allLines：所有行同时展开副行）
      violations.clear();
      await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
      for (final target in <int>[2000, 22000, 500]) {
        pos.value = Duration(milliseconds: target);
        for (var n = 0; n < 100; n++) {
          await tester.pump(step);
          scan('all$target');
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'allLines 全行同时展开副行时，任何收敛帧均不得越界',
      );
    });
  });
}

/// 测试宿主：持有可变 lines 列表，模拟宿主页异步更新歌词后重建视图。
class _Host extends StatefulWidget {
  const _Host({
    required this.pos,
    required this.lines,
    required this.childBuilder,
  });

  final ValueNotifier<Duration> pos;
  final List<LyricLine> lines;
  final Widget Function(List<LyricLine>) childBuilder;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: widget.childBuilder(widget.lines),
      ),
    );
  }
}
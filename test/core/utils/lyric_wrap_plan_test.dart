/// 歌词换行计划层测试。
///
/// 覆盖三件事：
/// 1) 计划是唯一断点来源——同一输入两次取计划必须拿到**同一个实例**（缓存）；
/// 2) 关闭平衡时，纯文本行的计划必须与旧的 TextPainter 自动换行逐字一致；
/// 3) KRC 行的计划是 word 空间（`rowIndexOfUnit` 能把 word 映射到视觉行）。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/lyric_wrap_plan.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

TextStyle styleOf(double fontSize) =>
    TextStyle(fontSize: fontSize, height: 1.0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(LyricWrapPlanner.clearCache);
  tearDown(LyricWrapPlanner.clearCache);

  group('forUnits', () {
    test('rowTexts 拼接无损，每行宽度为正', () {
      final plan = LyricWrapPlanner.forUnits(
        <String>['aaa', ' ', 'bbb'],
        styleOf(15),
        50,
        balanced: true,
        space: LyricUnitSpace.segments,
      );
      expect(plan.rowTexts.join(), 'aaa bbb');
      expect(plan.rowWidths.every((w) => w > 0), isTrue);
    });

    test('关闭平衡 = 旧贪心：与手动累加结果一致', () {
      // Ahem 15/字符：'aaaa'(60) 'b'(15) 'c'(15)，maxWidth=75
      // 旧规则：60 → +15=75 不 > 75 同行；再 +15 > 75 → 换行到第 3 个单元
      final plan = LyricWrapPlanner.forUnits(
        <String>['aaaa', 'b', 'c'],
        styleOf(15),
        75,
        balanced: false,
        space: LyricUnitSpace.segments,
      );
      expect(plan.rowStarts, <int>[0, 2]);
      expect(plan.rowTexts, <String>['aaaab', 'c']);
    });

    test('开平衡的行宽方差不高于贪心', () {
      double variance(List<double> ws) {
        final mean = ws.reduce((a, b) => a + b) / ws.length;
        return ws.map((w) => (w - mean) * (w - mean)).reduce((a, b) => a + b);
      }

      final balanced = LyricWrapPlanner.forUnits(
        <String>['aa', 'bb', 'cc', 'd'],
        styleOf(15),
        45,
        balanced: true,
        space: LyricUnitSpace.segments,
      );
      final greedy = LyricWrapPlanner.forUnits(
        <String>['aa', 'bb', 'cc', 'd'],
        styleOf(15),
        45,
        balanced: false,
        space: LyricUnitSpace.segments,
      );
      expect(
        variance(balanced.rowWidths),
        lessThanOrEqualTo(variance(greedy.rowWidths) + 1e-6),
        reason: '平衡版的行宽方差不得高于贪心版',
      );
    });
  });

  group('forText', () {
    test('关闭平衡：行数与 TextPainter 自动换行完全一致', () {
      const text = 'abcdefgh';
      final tp = TextPainter(
        text: TextSpan(text: text, style: styleOf(15)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 60);
      final tpRows = tp.computeLineMetrics().length;
      tp.dispose();

      final plan = LyricWrapPlanner.forText(
        text,
        styleOf(15),
        60,
        balanced: false,
      );
      expect(plan.unitSpace, LyricUnitSpace.painterWrap);
      expect(plan.rowCount, tpRows);
      expect(plan.rowTexts.join(), text);
    });

    test('开平衡：放得下的短文本仍为单行', () {
      final plan = LyricWrapPlanner.forText(
        '短句子',
        styleOf(15),
        400,
        balanced: true,
      );
      expect(plan.rowCount, 1);
      expect(plan.rowTexts, <String>['短句子']);
    });
  });

  group('forLine', () {
    test('KRC 行走 word 空间：rowIndexOfUnit 把 word 映射到视觉行', () {
      const line = LyricLine(
        startTime: 0,
        duration: 4000,
        text: 'I love you',
        words: [
          LyricWord(startTime: 0, duration: 100, text: 'I '),
          LyricWord(startTime: 100, duration: 100, text: 'love'),
          LyricWord(startTime: 200, duration: 100, text: ' you'),
        ],
      );
      // Ahem：'I '=30 'love'=60 ' you'=60，maxWidth=90 → 旧贪心 [I love] / [ you]
      final plan = LyricWrapPlanner.forLine(
        line,
        styleOf(15),
        90,
        balanced: false,
      );
      expect(plan.unitSpace, LyricUnitSpace.words);
      expect(plan.rowCount, 2);
      expect(plan.rowIndexOfUnit(0), 0);
      expect(plan.rowIndexOfUnit(1), 0);
      expect(plan.rowIndexOfUnit(2), 1);
      expect(plan.rowTexts, <String>['I love', ' you']);
    });

    test('无 word 的行：开平衡走 segments，关平衡走 painterWrap', () {
      const line = LyricLine(startTime: 0, duration: 100, text: '你好世界');
      final balanced = LyricWrapPlanner.forLine(
        line,
        styleOf(15),
        45,
        balanced: true,
      );
      final fallback = LyricWrapPlanner.forLine(
        line,
        styleOf(15),
        45,
        balanced: false,
      );
      expect(balanced.unitSpace, LyricUnitSpace.segments);
      expect(fallback.unitSpace, LyricUnitSpace.painterWrap);
      expect(balanced.rowTexts.join(), '你好世界');
      expect(balanced.rowWidths, <double>[30, 30], reason: '四字段落应均衡成两行');
    });

    test('可用宽无穷 → 单行', () {
      const line = LyricLine(
        startTime: 0,
        duration: 100,
        text: '很长的句子很长的句子',
      );
      final plan = LyricWrapPlanner.forLine(
        line,
        styleOf(15),
        double.infinity,
        balanced: true,
      );
      expect(plan.rowCount, 1);
    });
  });

  group('缓存', () {
    test('同一输入两次取计划是同一实例', () {
      final a = LyricWrapPlanner.forText(
        '缓存测试',
        styleOf(15),
        45,
        balanced: true,
      );
      final b = LyricWrapPlanner.forText(
        '缓存测试',
        styleOf(15),
        45,
        balanced: true,
      );
      expect(identical(a, b), isTrue);
    });

    test('开关状态变化必须产生不同计划（缓存键含 balanced）', () {
      final a = LyricWrapPlanner.forText(
        '平衡开关',
        styleOf(15),
        30,
        balanced: true,
      );
      final b = LyricWrapPlanner.forText(
        '平衡开关',
        styleOf(15),
        30,
        balanced: false,
      );
      expect(identical(a, b), isFalse);
      expect(a.unitSpace == b.unitSpace, isFalse);
    });

    test('LRU：插入 300 个计划后最早的计划仍在缓存（不整表清空）', () {
      // 旧实现上限 256 且满即整表 clear()：长歌（主行 + 副行 >256 项）会 0% 命中。
      // 新实现上限 1024 且只逐出最旧，故 300 项时最早的仍应命中同一实例。
      final first = LyricWrapPlanner.forText(
        '缓存保留',
        styleOf(15),
        30,
        balanced: true,
      );
      for (int i = 0; i < 300; i++) {
        LyricWrapPlanner.forText('填充$i', styleOf(15), 30, balanced: true);
      }
      final again = LyricWrapPlanner.forText(
        '缓存保留',
        styleOf(15),
        30,
        balanced: true,
      );
      expect(
        identical(first, again),
        isTrue,
        reason: 'LRU 上限 1024 > 300，最早计划不应被逐出（旧实现会整表清空）',
      );
    });

    test('单元宽度 memo：同文本同字体的计划跨宽度复用测宽', () {
      // 同一单元文本在不同可用宽下多次求计划，断行结果应与逐单元测宽一致。
      // Ahem 15/字：6 字在宽 45 → 3 字/行（2 行）；在宽 30 → 2 字/行（3 行）。
      final a = LyricWrapPlanner.forText(
        '你好世界你好',
        styleOf(15),
        45,
        balanced: true,
      );
      final b = LyricWrapPlanner.forText(
        '你好世界你好',
        styleOf(15),
        30,
        balanced: true,
      );
      expect(a.rowTexts.join(), '你好世界你好');
      expect(b.rowTexts.join(), '你好世界你好');
      expect(a.rowCount, 2);
      expect(b.rowCount, 3);
    });
  });
}

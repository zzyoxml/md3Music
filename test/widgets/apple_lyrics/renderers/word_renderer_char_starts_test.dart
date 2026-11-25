// 回归测试：逐字符绘制路径的字符起点必须与整词 shaped 布局同源。
//
// 背景（docs/2026-11-13-am-glow-char-spacing-jump-analysis.md）：
// 强调字拆成独立 TextPainter 后，逐字符 advance 累加会丢掉整词 kerning，
// 累加值系统性大于整词宽度 → 辉光触发瞬间整词被"摊宽"（英文明显、中文为 0）。
// 修复方式：字符起点取整词 painter 的 shaped caret（[WordRenderer.shapedCharStarts]）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';

TextPainter _wordPainter(String text, double fontSize, String? family) {
  return TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        height: 1.2,
        fontFamily: family,
        fontWeight: FontWeight.w600,
      ),
    ),
  )..layout();
}

double _isolatedAdvance(String char, double fontSize, String? family) =>
    _wordPainter(char, fontSize, family).width;

/// 独立 advance 累加（改造前的字符起点算法，用作对照）。
List<double> _advanceStarts(
  String text,
  double fontSize,
  String? family,
) {
  final List<int> runes = text.runes.toList();
  final List<double> starts = List<double>.filled(runes.length, 0);
  double accum = 0;
  for (int k = 0; k < runes.length; k++) {
    starts[k] = accum;
    accum += _isolatedAdvance(String.fromCharCode(runes[k]), fontSize, family);
  }
  return starts;
}

void main() {
  const String fontFamily = 'CharStartsProbe';
  const double fontSize = 40;
  bool fontReady = false;

  setUpAll(() async {
    // 真实字体才能复现 kerning：默认测试字体等宽无字偶距，差值恒为 0。
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (!font.existsSync()) return;
    final loader = FontLoader(fontFamily)
      ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await loader.load();
    fontReady = true;
  });

  test('含 kerning 的英文词：起点取 shaped caret，末沿与整词宽度自洽', () {
    if (!fontReady) {
      // ignore: avoid_print
      print('[skip] 系统缺少 msyh.ttc，无法复现 kerning');
      return;
    }
    for (final text in <String>['STAY', 'To', 'WAVE', 'Time', 'together']) {
      final TextPainter word = _wordPainter(text, fontSize, fontFamily);
      final List<int> runes = text.runes.toList();
      final List<double>? starts = WordRenderer.shapedCharStarts(
        wordPainter: word,
        text: text,
        runes: runes,
      );
      expect(starts, isNotNull, reason: '$text 的 shaped caret 应可用');
      final List<double> shaped = starts!;
      expect(shaped.length, runes.length);
      expect(shaped.first.abs(), lessThan(0.01), reason: '$text 首字符应贴左');
      for (int k = 1; k < shaped.length; k++) {
        expect(shaped[k], greaterThanOrEqualTo(shaped[k - 1]),
            reason: '$text caret 必须单调不减');
      }
      // 末字符起点不得越过整词宽度（改造前累加值会越界）
      expect(shaped.last, lessThanOrEqualTo(word.width + 0.01),
          reason: '$text 末字符起点越界');
    }
  });

  test('shaped 起点与独立 advance 累加在含 kerning 词上必须不同', () {
    if (!fontReady) return;
    var differing = 0;
    for (final text in <String>['STAY', 'To', 'WAVE']) {
      final TextPainter word = _wordPainter(text, fontSize, fontFamily);
      final List<double> shaped = WordRenderer.shapedCharStarts(
        wordPainter: word,
        text: text,
        runes: text.runes.toList(),
      )!;
      final List<double> advance = _advanceStarts(text, fontSize, fontFamily);
      final double shapedEnd = shaped.last;
      final double advanceEnd = advance.last;
      expect(shapedEnd, lessThan(advanceEnd - 0.5),
          reason: '$text 若与累加值一致说明没走 shaped（kerning 未生效）');
      differing++;
    }
    expect(differing, 3);
  });

  test('中文单字/多字：shaped 起点与 advance 累加一致（不得引入回归）', () {
    if (!fontReady) return;
    for (final text in <String>['你', '世界', '我们']) {
      final TextPainter word = _wordPainter(text, fontSize, fontFamily);
      final List<double> shaped = WordRenderer.shapedCharStarts(
        wordPainter: word,
        text: text,
        runes: text.runes.toList(),
      )!;
      final List<double> advance = _advanceStarts(text, fontSize, fontFamily);
      expect(shaped.length, advance.length);
      for (int k = 0; k < shaped.length; k++) {
        expect((shaped[k] - advance[k]).abs(), lessThan(0.05),
            reason: '$text[$k] 中文无 kerning，两条路径应一致');
      }
    }
  });

  test('度量不可用时返回 null，调用方回退 advance 累加', () {
    final TextPainter word = _wordPainter('STAY', fontSize, null);
    // 空文本 / 空 runes
    expect(
      WordRenderer.shapedCharStarts(
        wordPainter: word,
        text: '',
        runes: const <int>[],
      ),
      isNull,
    );
    // text 与 runes 不匹配（越界）必须拒绝，避免取到错误 caret
    expect(
      WordRenderer.shapedCharStarts(
        wordPainter: word,
        text: 'S',
        runes: 'STAY'.runes.toList(),
      ),
      isNull,
    );
  });
}

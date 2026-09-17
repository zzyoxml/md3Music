/// LyricLayout 副行（翻译/罗马音）高度口径单元测试
///
/// 覆盖：副行高度必须随**实际视觉行数**增长（副行过长换行时若不调整，
/// 多出来的视觉行会压到下一行歌词上）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LyricPreferences.instance.reset();
  });
  tearDown(() => LyricPreferences.instance.reset());

  group('LyricLayout.auxSubHeight', () {
    const double fontSize = 20; // transFontSize = max(20*0.7, 12) = 14

    test('rows <= 0 表示无副行 → 0', () {
      expect(LyricLayout.auxSubHeight(fontSize, 0), 0);
      expect(LyricLayout.auxSubHeight(fontSize, -1), 0);
    });

    test('单行副行高度 = 副行行高 + 0.3em 间隙（与旧口径一致）', () {
      final double trans = LyricLayout.translationFontSize(fontSize);
      expect(
        LyricLayout.auxSubHeight(fontSize, 1),
        closeTo(trans * LyricLayout.translationLineHeight + trans * 0.3, 0.0001),
      );
    });

    test('换行副行高度按行数递增（间隔恒为 1 个副行行高）', () {
      final double one = LyricLayout.auxSubHeight(fontSize, 1);
      final double two = LyricLayout.auxSubHeight(fontSize, 2);
      final double three = LyricLayout.auxSubHeight(fontSize, 3);
      final double trans = LyricLayout.translationFontSize(fontSize);
      final double rowHeight = trans * LyricLayout.translationLineHeight;

      expect(two - one, closeTo(rowHeight, 0.0001));
      expect(three - two, closeTo(rowHeight, 0.0001));
      expect(three, greaterThan(two));
      // 字号越大，副行越高（跟随 fontSize 缩放）
      expect(LyricLayout.auxSubHeight(40, 2),
          greaterThan(LyricLayout.auxSubHeight(20, 2)));
    });
  });

  group('LyricLayout.measureAuxRows', () {
    test('无副行文本 → 0 行', () {
      expect(LyricLayout.measureAuxRows(null, 20, 400), 0);
      expect(LyricLayout.measureAuxRows('', 20, 400), 0);
    });

    test('短副行 → 1 行', () {
      expect(LyricLayout.measureAuxRows('短句', 20, 400), 1);
    });

    test('过长副行 → 多行（换行）', () {
      final long = '这是一句非常长的翻译副行文本用来验证换行之后的行距预留是否会调整' * 3;
      final rows = LyricLayout.measureAuxRows(long, 20, 400);
      expect(rows, greaterThan(1));
      // 行数越多，预留高度越大（换行必须反映到高度上）
      expect(LyricLayout.auxSubHeight(20, rows),
          greaterThan(LyricLayout.auxSubHeight(20, 1)));
    });

    test('宽度越窄行数不小于宽度越宽（单调）', () {
      final text = '这是一句比较长的翻译文本用于验证窄宽度下的换行行为';
      final narrow = LyricLayout.measureAuxRows(text, 20, 120);
      final wide = LyricLayout.measureAuxRows(text, 20, 1200);
      expect(narrow, greaterThanOrEqualTo(wide));
      expect(wide, 1);
    });
  });
}

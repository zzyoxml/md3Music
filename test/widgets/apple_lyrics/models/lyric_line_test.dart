import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// LyricWord / LyricLine 模型单元测试
/// 覆盖：构造与字段访问、hasWordTiming、endTime、相等性判定
void main() {
  group('LyricWord', () {
    test('构造与字段访问', () {
      const word = LyricWord(
        startTime: 12500,
        duration: 300,
        text: '运',
      );
      expect(word.startTime, 12500);
      expect(word.duration, 300);
      expect(word.text, '运');
    });

    test('相等性：相同字段相等', () {
      const a = LyricWord(startTime: 100, duration: 200, text: 'a');
      const b = LyricWord(startTime: 100, duration: 200, text: 'a');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('不等性：任一字段不同不相等', () {
      const base = LyricWord(startTime: 100, duration: 200, text: 'a');
      expect(
        base == const LyricWord(startTime: 999, duration: 200, text: 'a'),
        isFalse,
      );
      expect(
        base == const LyricWord(startTime: 100, duration: 999, text: 'a'),
        isFalse,
      );
      expect(
        base == const LyricWord(startTime: 100, duration: 200, text: 'b'),
        isFalse,
      );
    });

    test('toString 包含字段信息', () {
      const word = LyricWord(startTime: 1, duration: 2, text: 'X');
      final s = word.toString();
      expect(s, contains('startTime: 1'));
      expect(s, contains('duration: 2'));
      expect(s, contains("'X'"));
    });
  });

  group('LyricLine', () {
    test('构造与字段访问', () {
      const line = LyricLine(
        startTime: 12500,
        duration: 4200,
        text: '运命的华',
        translation: '命运之花',
      );
      expect(line.startTime, 12500);
      expect(line.duration, 4200);
      expect(line.text, '运命的华');
      expect(line.translation, '命运之花');
      expect(line.words, isEmpty);
    });

    test('words 字段默认空列表', () {
      const line = LyricLine(startTime: 0, duration: 0, text: '');
      expect(line.words, isEmpty);
    });

    test('hasWordTiming：words 为空时返回 false', () {
      const line = LyricLine(startTime: 0, duration: 1000, text: 'hi');
      expect(line.hasWordTiming, isFalse);
    });

    test('hasWordTiming：words 非空时返回 true', () {
      const line = LyricLine(
        startTime: 0,
        duration: 1000,
        text: 'hi',
        words: [
          LyricWord(startTime: 0, duration: 500, text: 'h'),
          LyricWord(startTime: 500, duration: 500, text: 'i'),
        ],
      );
      expect(line.hasWordTiming, isTrue);
    });

    test('endTime getter 计算正确：startTime + duration', () {
      const line = LyricLine(startTime: 12500, duration: 4200, text: '');
      expect(line.endTime, 16700);
    });

    test('相等性：所有字段相同（含 words 列表）相等', () {
      const a = LyricLine(
        startTime: 100,
        duration: 200,
        text: 'abc',
        words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
        translation: 't',
      );
      const b = LyricLine(
        startTime: 100,
        duration: 200,
        text: 'abc',
        words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
        translation: 't',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('不等性：任一字段不同不相等', () {
      const base = LyricLine(
        startTime: 100,
        duration: 200,
        text: 'abc',
        words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
        translation: 't',
      );
      // startTime 不同
      expect(
        base ==
            const LyricLine(
              startTime: 999,
              duration: 200,
              text: 'abc',
              words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
              translation: 't',
            ),
        isFalse,
      );
      // duration 不同
      expect(
        base ==
            const LyricLine(
              startTime: 100,
              duration: 999,
              text: 'abc',
              words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
              translation: 't',
            ),
        isFalse,
      );
      // text 不同
      expect(
        base ==
            const LyricLine(
              startTime: 100,
              duration: 200,
              text: 'XXX',
              words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
              translation: 't',
            ),
        isFalse,
      );
      // translation 不同
      expect(
        base ==
            const LyricLine(
              startTime: 100,
              duration: 200,
              text: 'abc',
              words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
              translation: 'other',
            ),
        isFalse,
      );
      // words 数量不同
      expect(
        base ==
            const LyricLine(
              startTime: 100,
              duration: 200,
              text: 'abc',
              words: [
                LyricWord(startTime: 100, duration: 50, text: 'a'),
                LyricWord(startTime: 150, duration: 50, text: 'b'),
              ],
              translation: 't',
            ),
        isFalse,
      );
      // words 内容不同
      expect(
        base ==
            const LyricLine(
              startTime: 100,
              duration: 200,
              text: 'abc',
              words: [LyricWord(startTime: 100, duration: 50, text: 'z')],
              translation: 't',
            ),
        isFalse,
      );
    });

    test('相等性：translation 一个为 null 一个为非 null 不相等', () {
      const withTranslation = LyricLine(
        startTime: 100,
        duration: 200,
        text: 'abc',
        translation: 't',
      );
      const withoutTranslation = LyricLine(
        startTime: 100,
        duration: 200,
        text: 'abc',
      );
      expect(withTranslation == withoutTranslation, isFalse);
    });

    test('toString 包含关键信息', () {
      const line = LyricLine(
        startTime: 100,
        duration: 200,
        text: 'abc',
        words: [LyricWord(startTime: 100, duration: 50, text: 'a')],
      );
      final s = line.toString();
      expect(s, contains('startTime: 100'));
      expect(s, contains('duration: 200'));
      expect(s, contains("'abc'"));
      expect(s, contains('words: 1'));
    });
  });
}

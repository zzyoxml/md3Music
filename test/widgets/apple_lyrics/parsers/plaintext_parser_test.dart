import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/plaintext_parser.dart';

/// PlainTextParser 单元测试
/// 覆盖：单行、多行、空输入、仅空白行、trim、UTF-8 中文、
/// words 为空、duration 为 0、混合空行
void main() {
  group('PlainTextParser.parse', () {
    test('1. 单行：Hello → 1 个 LyricLine，text="Hello"，startTime=0', () {
      final result = PlainTextParser.parse('Hello');
      expect(result.length, 1);
      expect(result.first.text, 'Hello');
      expect(result.first.startTime, 0);
    });

    test('2. 多行：Hello\\nWorld\\nFoo → 3 个 LyricLine，按顺序', () {
      final result = PlainTextParser.parse('Hello\nWorld\nFoo');
      expect(result.length, 3);
      expect(result[0].text, 'Hello');
      expect(result[1].text, 'World');
      expect(result[2].text, 'Foo');
    });

    test('3. 空字符串："" → []', () {
      final result = PlainTextParser.parse('');
      expect(result, isEmpty);
    });

    test('4. 仅空白行："  \\n\\n  " → []', () {
      final result = PlainTextParser.parse('  \n\n  ');
      expect(result, isEmpty);
    });

    test('5. 行首尾空格 trim："  Hello  \\n  World  " → 2 个 LyricLine', () {
      final result = PlainTextParser.parse('  Hello  \n  World  ');
      expect(result.length, 2);
      expect(result[0].text, 'Hello');
      expect(result[1].text, 'World');
    });

    test('6. UTF-8 中文：你好\\n世界 → 2 个 LyricLine', () {
      final result = PlainTextParser.parse('你好\n世界');
      expect(result.length, 2);
      expect(result[0].text, '你好');
      expect(result[1].text, '世界');
    });

    test('7. words 为空：所有 LyricLine.words == const []，hasWordTiming == false', () {
      final result = PlainTextParser.parse('Hello\nWorld');
      expect(result.length, 2);
      for (final line in result) {
        expect(line.words, isEmpty);
        // 引用相等进行 const <LyricWord>[]（类型必须一致才能 identical）
        expect(identical(line.words, const <LyricWord>[]), isTrue);
        expect(line.hasWordTiming, isFalse);
      }
    });

    test('8. duration 为 0：所有 LyricLine.duration == 0', () {
      final result = PlainTextParser.parse('Hello\nWorld\nFoo');
      expect(result.length, 3);
      for (final line in result) {
        expect(line.duration, 0);
      }
    });

    test('9. 混合空行与非空行：Hello\\n\\n\\nWorld → 2 个 LyricLine（空行被跳过）', () {
      final result = PlainTextParser.parse('Hello\n\n\nWorld');
      expect(result.length, 2);
      expect(result[0].text, 'Hello');
      expect(result[1].text, 'World');
    });
  });

  group('PlainTextParser.parse 附加验证', () {
    test('所有 LyricLine 的 translation 为 null', () {
      final result = PlainTextParser.parse('Hello\nWorld');
      for (final line in result) {
        expect(line.translation, isNull);
      }
    });

    test('所有 LyricLine 的 startTime 为 0', () {
      final result = PlainTextParser.parse('A\nB\nC\nD');
      for (final line in result) {
        expect(line.startTime, 0);
      }
    });

    test('CRLF 换行兼容性："Hello\\r\\nWorld" → 2 个 LyricLine', () {
      final result = PlainTextParser.parse('Hello\r\nWorld');
      expect(result.length, 2);
      expect(result[0].text, 'Hello');
      expect(result[1].text, 'World');
    });

    test('tab 与全角空格 trim', () {
      // 制表符与全角空格（U+3000）也应在 trim 后被去除
      final result = PlainTextParser.parse('\tHello\t\n\u3000World\u3000');
      expect(result.length, 2);
      expect(result[0].text, 'Hello');
      expect(result[1].text, 'World');
    });
  });

  // 验证 PlainTextParser.parse 输出的 LyricLine 与模型构造器一致
  test('LyricLine 模型一致性：与手动构造的 LyricLine 相等', () {
    final result = PlainTextParser.parse('Hello');
    const expected = LyricLine(
      startTime: 0,
      duration: 0,
      text: 'Hello',
      words: [],
      translation: null,
    );
    expect(result.first, equals(expected));
  });
}

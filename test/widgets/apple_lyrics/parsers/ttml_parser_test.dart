import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/ttml_parser.dart';

/// TtmlParser 单元测试
///
/// 覆盖：行级 TTML、逐字 <span begin/end>、metadata 翻译（itunes:key）、
/// 内联 x-translation、非法 XML 兜底、空输入。
/// 参照 Lyrico-master TtmlParser 行为移植。
void main() {
  group('TtmlParser.parse', () {
    test('T1. 行级 TTML：<p begin/end> 无逐字 → 单行整行渲染', () {
      const input = '''<?xml version="1.0" encoding="utf-8"?>
<tt xmlns="http://www.w3.org/ns/ttml">
  <body>
    <div>
      <p begin="1.000" end="2.000">Hello world</p>
    </div>
  </body>
</tt>''';
      final result = TtmlParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.startTime, 1000);
      expect(line.duration, 1000);
      expect(line.text, 'Hello world');
      // 无字级时间戳：整行作为一个字
      expect(line.words, hasLength(1));
      expect(line.words.first.startTime, 1000);
      expect(line.words.first.text, 'Hello world');
    });

    test('T2. 逐字 TTML：嵌套 <span begin/end> → words 逐字', () {
      const input = '''<?xml version="1.0" encoding="utf-8"?>
<tt xmlns="http://www.w3.org/ns/ttml"
    xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="1.000" end="2.000" itunes:key="L1">
        <span begin="1.000" end="1.200">I</span><span begin="1.200" end="1.300"> </span><span begin="1.300" end="2.000">had</span>
      </p>
    </div>
  </body>
</tt>''';
      final result = TtmlParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.text, 'I had');
      expect(line.words, hasLength(3));
      expect(line.words[0].startTime, 1000);
      expect(line.words[0].duration, 200);
      expect(line.words[0].text, 'I');
      expect(line.words[1].startTime, 1200);
      expect(line.words[1].text, ' ');
      expect(line.words[2].startTime, 1300);
      expect(line.words[2].text, 'had');
    });

    test('T3. metadata 翻译：itunes:key 关联 → translation 合并', () {
      const input = '''<?xml version="1.0" encoding="utf-8"?>
<tt xmlns="http://www.w3.org/ns/ttml"
    xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <head>
    <metadata>
      <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
        <translations>
          <translation type="subtitle" xml:lang="zh-Hans">
            <text for="L1">我曾拥有</text>
          </translation>
        </translations>
      </iTunesMetadata>
    </metadata>
  </head>
  <body>
    <div>
      <p begin="1.000" end="2.000" itunes:key="L1">
        <span begin="1.000" end="1.200">I</span><span begin="1.200" end="1.300"> </span><span begin="1.300" end="2.000">had</span>
      </p>
    </div>
  </body>
</tt>''';
      final result = TtmlParser.parse(input);

      expect(result, hasLength(1));
      expect(result.first.translation, '我曾拥有');
      expect(result.first.text, 'I had');
    });

    test('T4. 内联翻译：<span ttm:role="x-translation"> → translation 合并', () {
      const input = '''<?xml version="1.0" encoding="utf-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="1.000" end="2.000">
        <span begin="1.000" end="2.000">I had</span><span ttm:role="x-translation">我曾拥有</span>
      </p>
    </div>
  </body>
</tt>''';
      final result = TtmlParser.parse(input);

      expect(result, hasLength(1));
      expect(result.first.translation, '我曾拥有');
      expect(result.first.text, 'I had');
    });

    test('T5. 非 XML / 非法 XML → 空列表（不抛异常）', () {
      expect(TtmlParser.parse('just plain text'), isEmpty);
      expect(TtmlParser.parse('<tt><unclosed>'), isEmpty);
    });

    test('T6. 空输入 → 空列表', () {
      expect(TtmlParser.parse(''), isEmpty);
    });
  });
}

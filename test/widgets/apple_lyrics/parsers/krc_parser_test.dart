import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/krc_parser.dart';

/// KrcParser 单元测试
///
/// 覆盖：标准行解析、多行解析、元数据过滤、空输入、损坏行跳过、
/// property 非 0、整行文本拼接、UTF-8 中日字符、字标签紧密相连等场景。
/// 参照 spec.md 附录 B 真实样本「運命の華」。
void main() {
  group('KrcParser.parse', () {
    test('1. 标准单行解析：1 个 LyricLine + 2 个 LyricWord', () {
      const input = '[12500,4200]<0,300,0>運<300,400,0>命';
      final result = KrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.startTime, 12500);
      expect(line.duration, 4200);
      expect(line.text, '運命');
      expect(line.hasWordTiming, isTrue);

      expect(line.words, hasLength(2));
      // 第一个字：行 startTime(12500) + offset(0) = 12500
      expect(line.words[0].startTime, 12500);
      expect(line.words[0].duration, 300);
      expect(line.words[0].text, '運');
      // 第二个字：行 startTime(12500) + offset(300) = 12800
      expect(line.words[1].startTime, 12800);
      expect(line.words[1].duration, 400);
      expect(line.words[1].text, '命');
    });

    test('2. 多行解析：3 行歌词，按 startTime 升序', () {
      const input = '''
[12500,4200]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華
[16700,3800]<0,350,0>泣<350,450,0>き
[20500,4000]<0,400,0>新<400,500,0>しい
''';
      final result = KrcParser.parse(input);

      expect(result, hasLength(3));
      // 按输入顺序，startTime 升序
      expect(result[0].startTime, 12500);
      expect(result[1].startTime, 16700);
      expect(result[2].startTime, 20500);
      // 每行都有逐字数据
      expect(result[0].words, hasLength(4));
      expect(result[1].words, hasLength(2));
      expect(result[2].words, hasLength(2));
      // 文本拼接正确
      expect(result[0].text, '運命の華');
      expect(result[1].text, '泣き');
      expect(result[2].text, '新しい');
    });

    test('3. 元数据过滤：仅产出歌词行', () {
      const input = '''
[id:\$00000000]
[ar:トゲナシトゲアリ]
[ti:運命の華]
[by:]
[hash:0dc65949d510244b1ade85a97602649c]
[al:]
[sign:]
[qq:]
[total:195735]
[offset:0]
[language: ShoreiGo]
[12500,4200]<0,300,0>運<300,400,0>命
''';
      final result = KrcParser.parse(input);

      // 只有一行歌词
      expect(result, hasLength(1));
      expect(result.first.startTime, 12500);
      expect(result.first.text, '運命');
    });

    test('4. 空输入：返回空列表', () {
      expect(KrcParser.parse(''), isEmpty);
    });

    test('5. 仅元数据无歌词：返回空列表', () {
      const input = '''
[id:\$00000000]
[ar:トゲナシトゲアリ]
[ti:運命の華]
[total:195735]
[offset:0]
[language:ShoreiGo]
''';
      expect(KrcParser.parse(input), isEmpty);
    });

    test('6. 损坏行跳过：不影响其他正常行', () {
      const input = '''
[12500,4200]<0,300,0>運<300,400,0>命
[abc,def]garbage
random text
[16700,3800]<0,350,0>泣<350,450,0>き
''';
      final result = KrcParser.parse(input);

      // 仅解析出两行正常歌词，损坏行被跳过
      expect(result, hasLength(2));
      expect(result[0].startTime, 12500);
      expect(result[0].text, '運命');
      expect(result[1].startTime, 16700);
      expect(result[1].text, '泣き');
    });

    test('7. 字标签 property 非 0：property 字段被忽略', () {
      const input = '[1000,2000]<0,300,5>字<300,400,9>文';
      final result = KrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.words, hasLength(2));
      // 第一个字 property=5，被忽略
      expect(line.words[0].startTime, 1000);
      expect(line.words[0].duration, 300);
      expect(line.words[0].text, '字');
      // 第二个字 property=9，被忽略
      expect(line.words[1].startTime, 1300);
      expect(line.words[1].duration, 400);
      expect(line.words[1].text, '文');
    });

    test('8. 整行文本拼接：LyricLine.text 等于所有字文本拼接', () {
      const input = '[0,5000]<0,500,0>Hel<500,500,0>lo<1000,1000,0>, <2000,2000,0>World!';
      final result = KrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.text, 'Hello, World!');
      // 验证拼接 = 所有字 text 顺序连接
      final concat = line.words.map((w) => w.text).join();
      expect(line.text, concat);
    });

    test('9. UTF-8 中日字符：「運命の華」完整解析', () {
      const input =
          '[12500,4200]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華';
      final result = KrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.text, '運命の華');
      expect(line.words, hasLength(4));
      expect(line.words[0].text, '運');
      expect(line.words[1].text, '命');
      expect(line.words[2].text, 'の');
      expect(line.words[3].text, '華');
      // 时间戳正确：行 start 12500 + 字 offset
      expect(line.words[0].startTime, 12500);
      expect(line.words[1].startTime, 12800);
      expect(line.words[2].startTime, 13200);
      expect(line.words[3].startTime, 13700);
    });

    test('10. 多字标签紧密相连无文本间隙：产出 2 个 word', () {
      const input = '[0,200]<0,100,0>A<100,100,0>B';
      final result = KrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.words, hasLength(2));
      expect(line.words[0].text, 'A');
      expect(line.words[1].text, 'B');
      expect(line.text, 'AB');
    });

    test('完整真实样本：運命の華首行 + 元数据头', () {
      // 模拟 spec.md 附录 B 真实样本前几行
      const input = '''
[id:\$00000000]
[ar:トゲナシトゲアリ]
[ti:運命の華]
[by:]
[hash:0dc65949d510244b1ade85a97602649c]
[al:]
[sign:]
[qq:]
[total:195735]
[offset:0]
[language:ShoreiGo]
[12500,4200]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華
[16700,3800]<0,350,0>泣<350,450,0>き<800,500,0>出<1300,500,0>し<1800,500,0>た<2300,500,0>ま<2800,500,0>い
''';
      final result = KrcParser.parse(input);

      // 元数据全部过滤，只保留 2 行歌词
      expect(result, hasLength(2));
      expect(result[0].startTime, 12500);
      expect(result[0].duration, 4200);
      expect(result[0].text, '運命の華');
      expect(result[0].words, hasLength(4));
      expect(result[1].startTime, 16700);
      expect(result[1].duration, 3800);
      expect(result[1].text, '泣き出したまい');
      // 输入字符串含 7 个字标签：泣/き/出/し/た/ま/い
      expect(result[1].words, hasLength(7));
    });

    test('字标签无 property 字段（仅 offset,duration）：能正确解析', () {
      // 部分变体 KRC 格式省略 property
      const input = '[0,500]<0,250>A<250,250>B';
      final result = KrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.words, hasLength(2));
      expect(line.words[0].startTime, 0);
      expect(line.words[0].duration, 250);
      expect(line.words[0].text, 'A');
      expect(line.words[1].startTime, 250);
      expect(line.words[1].duration, 250);
      expect(line.words[1].text, 'B');
    });

    test('只有行首时间戳但无字标签：跳过此行（无逐字信息）', () {
      const input = '[0,1000]no word tags here';
      final result = KrcParser.parse(input);
      expect(result, isEmpty);
    });

    test('\\r\\n 行尾：trim 后正确解析', () {
      const input = '[0,500]<0,250,0>A<250,250,0>B\r\n[500,500]<0,250,0>C<250,250,0>D';
      final result = KrcParser.parse(input);

      expect(result, hasLength(2));
      expect(result[0].text, 'AB');
      expect(result[1].text, 'CD');
    });
  });
}

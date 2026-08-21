import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/lyric_parser_chain.dart';

/// LyricParserChain 单元测试
///
/// 覆盖：KRC/LRC/纯文本自动检测、空输入、仅元数据降级、
/// KRC 元数据头不影响检测、parseAs 显式调用、混合格式边界等场景。
/// 参照 spec.md "Requirement: 统一歌词模型" 与 tasks.md Task 5.4。
void main() {
  group('LyricParserChain.parse - 自动检测', () {
    test('1. KRC 自动检测：含元数据头 + 歌词行 → hasWordTiming=true', () {
      // KRC 真实样本片段（参照 spec.md 附录 B「運命の華」）
      // 首行是元数据 [id:$...]，第二行才是 [12500,4200]<0,300,0>運...
      const input = '''[id:\$00000000]
[ar:トゲナシトゲアリ]
[ti:運命の華]
[by:foo]
[hash:0DC65949D510244B1ADE85A97602649C]
[al:傷つきつつも、美しく]
[language:ja]
[total:267000]
[offset:0]
[12500,4200]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華
[16700,3800]<0,350,0>泣<350,450,0>き
[20500,4000]<0,400,0>新<400,500,0>しい
''';
      final result = LyricParserChain.parse(input);

      expect(result, isNotEmpty);
      // KRC 解析结果应携带逐字时间戳
      expect(result.first.hasWordTiming, isTrue);
      // 第一行歌词文本应为「運命の華」
      expect(result.first.text, '運命の華');
      expect(result.first.startTime, 12500);
      expect(result.first.duration, 4200);
      // 字数：運/命/の/華 = 4
      expect(result.first.words, hasLength(4));
    });

    test('1b. KRC 检测：含 manualoffset 元数据头也应识别为 KRC 并保留逐字', () {
      // 部分歌曲的 KRC 带 [manualoffset:0] 头，旧实现枚举遗漏导致误判 plaintext，
      // 逐字信息全丢。回归用例（参照真实样本 Light of Love）。
      const input = '''[id:\$00000000]
[ar:ARForest]
[ti:Light of Love]
[manualoffset:0]
[total:151000]
[12500,4200]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華
[16700,3800]<0,350,0>泣
''';
      // 自动检测应识别为 KRC（而非 plaintext）
      expect(LyricParserChain.detectFormat(input), LyricFormat.krc);
      final result = LyricParserChain.parse(input);

      expect(result, isNotEmpty);
      expect(result.first.hasWordTiming, isTrue);
      expect(result.first.text, '運命の華');
      expect(result.first.words, hasLength(4));
      // [manualoffset:0] 头本身不应进入歌词列表
      expect(result.any((l) => l.text.contains('manualoffset')), isFalse);
    });

    test('2. LRC 自动检测：返回非空列表且 hasWordTiming=false', () {
      const input = '''[ti:Sample Song]
[ar:Artist]
[00:01.00]First line
[00:05.50]Second line
[00:10.00]Third line
''';
      final result = LyricParserChain.parse(input);

      expect(result, isNotEmpty);
      expect(result.length, 3);
      // LRC 不携带逐字时间戳
      for (final line in result) {
        expect(line.hasWordTiming, isFalse);
        expect(line.words, isEmpty);
      }
      // 时间戳解析正确：[00:01.00] → 1000ms
      expect(result[0].startTime, 1000);
      expect(result[0].text, 'First line');
      // [00:05.50] → 5*1000 + 50*10 = 5500ms（2 位毫秒按厘秒处理）
      expect(result[1].startTime, 5500);
      // [00:10.00] → 10000ms
      expect(result[2].startTime, 10000);
    });

    test('3. 纯文本自动检测：无时间戳纯文本 → 返回非空列表', () {
      const input = '''Hello World
This is a plain text lyric
No timestamps here
''';
      final result = LyricParserChain.parse(input);

      expect(result, isNotEmpty);
      expect(result.length, 3);
      // 纯文本所有行 startTime=0、duration=0、words=[]
      for (final line in result) {
        expect(line.startTime, 0);
        expect(line.duration, 0);
        expect(line.hasWordTiming, isFalse);
      }
      expect(result[0].text, 'Hello World');
      expect(result[1].text, 'This is a plain text lyric');
      expect(result[2].text, 'No timestamps here');
    });

    test('4. 空输入："" → []', () {
      expect(LyricParserChain.parse(''), isEmpty);
    });

    test('5. 仅元数据无歌词：降级纯文本，元数据被当作普通文本行', () {
      // 仅 KRC 元数据头，无任何歌词行
      // 检测器找不到非空非元数据行 → 降级纯文本
      // 纯文本解析器不识别 [id:...] 为时间戳，会当作普通文本行输出
      const input = '''[id:\$00000000]
[ar:Artist]
[ti:Title]
''';
      final result = LyricParserChain.parse(input);

      // 元数据行被 PlainTextParser 当作普通文本，所以非空
      expect(result, hasLength(3));
      expect(result[0].text, '[id:\$00000000]');
      expect(result[1].text, '[ar:Artist]');
      expect(result[2].text, '[ti:Title]');
      for (final line in result) {
        expect(line.hasWordTiming, isFalse);
        expect(line.startTime, 0);
      }
    });

    test('6. KRC 元数据头不影响检测：首行 [id:\$...] 仍走 KRC 路径', () {
      // 首行是元数据 [id:$00000000]，第二行才是 KRC 歌词行
      const input = '''[id:\$00000000]
[12500,4200]<0,300,0>運<300,400,0>命
''';
      final result = LyricParserChain.parse(input);

      // 必须走 KRC 路径（hasWordTiming=true），而非纯文本
      expect(result, hasLength(1));
      expect(result.first.hasWordTiming, isTrue);
      expect(result.first.text, '運命');
      expect(result.first.startTime, 12500);
      expect(result.first.words, hasLength(2));
    });
  });

  group('LyricParserChain.parseAs - 显式调用', () {
    test('7. parseAs(krc) 强制走 KRC，即使内容是 LRC', () {
      // 内容实际是 LRC，但强制指定为 KRC
      // KrcParser 解析 LRC 文本时，找不到 [start_ms,duration_ms] 行格式，
      // 会返回空列表（不抛异常）
      const lrcInput = '''[00:01.00]First line
[00:05.50]Second line
''';
      final result =
          LyricParserChain.parseAs(lrcInput, LyricFormat.krc);

      // KRC 解析器无法识别 LRC 时间戳格式，返回空列表
      expect(result, isEmpty);
    });

    test('7b. parseAs(lrc) 强制走 LRC，即使内容是 KRC', () {
      // 内容实际是 KRC，但强制指定为 LRC
      // LrcParser 不识别 [12500,4200] 格式，会返回空列表
      const krcInput = '[12500,4200]<0,300,0>運<300,400,0>命';
      final result =
          LyricParserChain.parseAs(krcInput, LyricFormat.lrc);

      expect(result, isEmpty);
    });

    test('7c. parseAs(plaintext) 强制走纯文本，即使内容是 KRC', () {
      // 内容是 KRC，但强制按纯文本解析
      const krcInput = '[12500,4200]<0,300,0>運<300,400,0>命';
      final result =
          LyricParserChain.parseAs(krcInput, LyricFormat.plaintext);

      // 纯文本解析器把整行当作一个 LyricLine，不做时间戳解析
      expect(result, hasLength(1));
      expect(result.first.text, '[12500,4200]<0,300,0>運<300,400,0>命');
      expect(result.first.startTime, 0);
      expect(result.first.hasWordTiming, isFalse);
    });
  });

  group('LyricParserChain.parse - 混合格式边界', () {
    test('8. 混合格式边界：首行 KRC + 后续 LRC 行 → 整体走 KRC 路径', () {
      // 首行是 KRC 格式，后续插入一行 LRC 格式
      // 调度器按首行格式判断 → 整体走 KRC，不混搭
      const input = '''[12500,4200]<0,300,0>運<300,400,0>命
[00:01.00]LRC行不应被识别
[16700,3800]<0,350,0>泣<350,450,0>き
''';
      final result = LyricParserChain.parse(input);

      // 整体走 KRC 路径：LRC 行 `[00:01.00]...` 不匹配 KRC 行格式被跳过
      // 结果应包含 2 个 KRC LyricLine（運命 / 泣き），LRC 行被丢弃
      expect(result, hasLength(2));
      expect(result[0].hasWordTiming, isTrue);
      expect(result[0].text, '運命');
      expect(result[1].hasWordTiming, isTrue);
      expect(result[1].text, '泣き');
      // 确认没有 LRC 解析出的 startTime=1000 行混入
      for (final line in result) {
        expect(line.startTime, isNot(1000));
      }
    });

    test('8b. 首行 LRC + 后续 KRC 行 → 整体走 LRC 路径', () {
      // 首行是 LRC，后续插入 KRC 行
      // 调度器按首行判断 → 整体走 LRC，KRC 行被 LRC 解析器跳过
      const input = '''[00:01.00]LRC line
[12500,4200]<0,300,0>運<300,400,0>命
[00:05.00]Another LRC
''';
      final result = LyricParserChain.parse(input);

      // 整体走 LRC：KRC 行 `[12500,4200]...` 不匹配 LRC 时间戳，被跳过
      expect(result, hasLength(2));
      for (final line in result) {
        expect(line.hasWordTiming, isFalse);
      }
      expect(result[0].text, 'LRC line');
      expect(result[0].startTime, 1000);
      expect(result[1].text, 'Another LRC');
      expect(result[1].startTime, 5000);
    });

    test('8c. 首行纯文本 + 后续 LRC 行 → 整体走纯文本路径', () {
      // 首行是无时间戳文本，后续插入 LRC 行
      // 调度器按首行判断 → 整体走纯文本，所有行被当作普通文本
      const input = '''This is plain
[00:01.00]Not parsed as LRC
Plain again
''';
      final result = LyricParserChain.parse(input);

      // 纯文本解析器把每行当作普通文本，不做时间戳解析
      expect(result, hasLength(3));
      for (final line in result) {
        expect(line.hasWordTiming, isFalse);
        expect(line.startTime, 0);
      }
      expect(result[0].text, 'This is plain');
      expect(result[1].text, '[00:01.00]Not parsed as LRC');
      expect(result[2].text, 'Plain again');
    });
  });

  group('LyricParserChain.parse - 边界场景补充', () {
    test('9. 仅空行与空白 → 降级纯文本，返回空列表', () {
      const input = '   \n\n\t\n  ';
      final result = LyricParserChain.parse(input);

      // 纯文本解析器跳过所有空行 → 空列表
      expect(result, isEmpty);
    });

    test('10. 单行 KRC 无元数据头 → 直接走 KRC', () {
      const input = '[12500,4200]<0,300,0>運<300,400,0>命';
      final result = LyricParserChain.parse(input);

      expect(result, hasLength(1));
      expect(result.first.hasWordTiming, isTrue);
      expect(result.first.text, '運命');
    });

    test('11. 单行 LRC 无元数据头 → 直接走 LRC', () {
      const input = '[00:01.50]Hello';
      final result = LyricParserChain.parse(input);

      expect(result, hasLength(1));
      expect(result.first.hasWordTiming, isFalse);
      expect(result.first.startTime, 1500);
      expect(result.first.text, 'Hello');
    });

    test('12. KRC 元数据前缀与时间戳行混合：3 位毫秒 LRC 也能正确识别', () {
      // 验证 LRC 3 位毫秒格式 [mm:ss.xxx] 也能被正确识别为 LRC
      const input = '''[ti:Test]
[00:01.500]Three digit ms
''';
      final result = LyricParserChain.parse(input);

      expect(result, hasLength(1));
      expect(result.first.hasWordTiming, isFalse);
      expect(result.first.startTime, 1500);
    });

    test('13. 字级 LRC 自动检测：每行多时间戳 + 字间文本 → hasWordTiming=true', () {
      // 验证字级 LRC（用户提供的实际格式）能正确走 LRC 解析路径
      // 且 LyricLine.words 携带逐字时间戳
      const input = '''[ti:湘女多情]
[00:01.000]湘[00:01.242]女[00:02.233]多[00:03.225]情[00:04.216] - [00:05.208]周[00:06.199]杰[00:07.191]伦[00:08.181]
[00:17.973]湘[00:18.373]女[00:18.838]多[00:19.237]情[00:20.725] [00:21.605]暮[00:21.982]色[00:22.793]已[00:22.963]落[00:23.437]地[00:24.477]
''';
      final result = LyricParserChain.parse(input);

      expect(result, hasLength(2));
      // 两条都是字级 LRC
      for (final line in result) {
        expect(line.hasWordTiming, isTrue);
      }
      // 第 1 行：标题行
      expect(result[0].text, '湘女多情 - 周杰伦');
      expect(result[0].startTime, 1000);
      expect(result[0].words, hasLength(8));
      // 第 2 行：实际歌词
      expect(result[1].text, '湘女多情 暮色已落地');
      expect(result[1].startTime, 17973);
    });
  });
}

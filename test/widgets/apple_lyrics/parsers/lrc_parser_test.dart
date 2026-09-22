import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/lrc_parser.dart';

/// LrcParser 单元测试
/// 覆盖：标准行、两位/三位毫秒、一行多时间戳、元数据过滤、空输入、
/// 仅元数据、纯文本跳过、UTF-8 中文、多行混合排序、duration 字段
void main() {
  group('LrcParser.parse', () {
    test('标准单行：[01:23.45]Hello → 1 行，startTime=83450', () {
      final result = LrcParser.parse('[01:23.45]Hello');
      expect(result, hasLength(1));
      final line = result.first;
      expect(line.startTime, 83450);
      expect(line.text, 'Hello');
      expect(line.words, isEmpty);
      expect(line.hasWordTiming, isFalse);
    });

    test('两位毫秒：[00:05.45]World → startTime=5450', () {
      final result = LrcParser.parse('[00:05.45]World');
      expect(result, hasLength(1));
      expect(result.first.startTime, 5450);
      expect(result.first.text, 'World');
    });

    test('三位毫秒：[00:05.456]World → startTime=5456', () {
      final result = LrcParser.parse('[00:05.456]World');
      expect(result, hasLength(1));
      expect(result.first.startTime, 5456);
      expect(result.first.text, 'World');
    });

    test('一行多时间戳：[00:10.00][00:30.00]Chorus → 2 行按 startTime 升序', () {
      final result = LrcParser.parse('[00:10.00][00:30.00]Chorus');
      expect(result, hasLength(2));
      expect(result[0].startTime, 10000);
      expect(result[0].text, 'Chorus');
      expect(result[1].startTime, 30000);
      expect(result[1].text, 'Chorus');
      // 确认升序
      expect(result[0].startTime <= result[1].startTime, isTrue);
    });

    test('元数据过滤：[ar:]/[ti:] 跳过，仅保留歌词行', () {
      final result = LrcParser.parse(
        '[ar:Artist]\n[ti:Title]\n[00:01.00]Lyric',
      );
      expect(result, hasLength(1));
      expect(result.first.startTime, 1000);
      expect(result.first.text, 'Lyric');
    });

    test('空输入返回空列表', () {
      expect(LrcParser.parse(''), isEmpty);
    });

    test('仅元数据返回空列表', () {
      final result = LrcParser.parse(
        '[ar:Artist]\n[ti:Title]\n[al:Album]\n[by:Author]',
      );
      expect(result, isEmpty);
    });

    test('无时间戳的纯文本跳过，返回空列表', () {
      expect(LrcParser.parse('just text'), isEmpty);
    });

    test('UTF-8 中文正确解析', () {
      final result = LrcParser.parse('[00:30.00]你好世界');
      expect(result, hasLength(1));
      expect(result.first.startTime, 30000);
      expect(result.first.text, '你好世界');
    });

    test('多行混合：3 行歌词 + 2 行元数据 → 3 行按时间排序', () {
      final lrc = '''
[ar:Artist]
[ti:Title]
[00:20.00]Third
[00:05.00]First
[00:10.00]Second
''';
      final result = LrcParser.parse(lrc);
      expect(result, hasLength(3));
      expect(result[0].startTime, 5000);
      expect(result[0].text, 'First');
      expect(result[1].startTime, 10000);
      expect(result[1].text, 'Second');
      expect(result[2].startTime, 20000);
      expect(result[2].text, 'Third');
    });

    test('duration 字段为 0（所有 LyricLine）', () {
      final result = LrcParser.parse('[00:01.00]A\n[00:02.00]B');
      expect(result, hasLength(2));
      for (final line in result) {
        expect(line.duration, 0);
      }
    });

    test('translation 字段为 null', () {
      final result = LrcParser.parse('[00:01.00]Hello');
      expect(result, hasLength(1));
      expect(result.first.translation, isNull);
    });

    test('空行跳过', () {
      final result = LrcParser.parse('\n\n[00:01.00]Hello\n\n');
      expect(result, hasLength(1));
      expect(result.first.text, 'Hello');
    });

    test('有时间戳但无文字：保留不可见占位行', () {
      final result = LrcParser.parse('[00:02.000]');
      expect(result, hasLength(1));
      expect(result.first.startTime, 2000);
      expect(result.first.text, '\u00A0');
      expect(result.first.hasWordTiming, isFalse);
    });

    test('全部元数据标签均被过滤', () {
      final lrc = '''
[offset:+100]
[id:123]
[hash:abc]
[total:180]
[language:zh]
[sign:署名]
[qq:123456]
[00:01.00]Lyric
''';
      final result = LrcParser.parse(lrc);
      expect(result, hasLength(1));
      expect(result.first.text, 'Lyric');
    });

    test('损坏输入不抛异常，返回空列表', () {
      expect(LrcParser.parse('[[[broken'), isEmpty);
    });

    test('无时间戳但有方括号的行跳过', () {
      expect(LrcParser.parse('[not a timestamp]text'), isEmpty);
    });

    test('一行多时间戳乱序输入也会按 startTime 升序输出', () {
      final result = LrcParser.parse('[00:30.00][00:10.00]Chorus');
      expect(result, hasLength(2));
      expect(result[0].startTime, 10000);
      expect(result[1].startTime, 30000);
    });

    test('LyricLine 相等性：相同时间戳与文本相等', () {
      final a = LrcParser.parse('[00:01.00]Hello');
      const b = LyricLine(startTime: 1000, duration: 0, text: 'Hello');
      expect(a.first, equals(b));
    });
  });

  group('LrcParser 字级 LRC 解析', () {
    test('单行字级 LRC：每个字独立 startTime，hasWordTiming=true', () {
      final result = LrcParser.parse(
        '[00:01.000]湘[00:01.242]女[00:02.233]多[00:03.225]情[00:04.216] - [00:05.208]周[00:06.199]杰[00:07.191]伦[00:08.181]',
      );
      // 一行多时间戳 + 字间文本 → 单条 LyricLine
      expect(result, hasLength(1));
      final line = result.first;
      expect(line.startTime, 1000);
      expect(line.hasWordTiming, isTrue);
      // 文本拼接：8 个字
      expect(line.text, '湘女多情 - 周杰伦');
      // 8 个字
      expect(line.words, hasLength(8));
      // 第 1 个字：湘 @ 1000ms
      expect(line.words[0].text, '湘');
      expect(line.words[0].startTime, 1000);
      // 第 2 个字：女 @ 1242ms
      expect(line.words[1].text, '女');
      expect(line.words[1].startTime, 1242);
      // " - " 中间有空格，文本保留
      expect(line.words[4].text, ' - ');
      expect(line.words[4].startTime, 4216);
      // 最后一个字：伦 @ 7191ms
      expect(line.words[7].text, '伦');
      expect(line.words[7].startTime, 7191);
    });

    test('字级 LRC：word duration = 下一字 startTime - 当前字 startTime', () {
      final result = LrcParser.parse('[00:01.000]A[00:01.500]B[00:02.000]C');
      expect(result, hasLength(1));
      expect(result.first.hasWordTiming, isTrue);
      expect(result.first.words, hasLength(3));
      expect(result.first.words[0].duration, 500); // 1500-1000
      expect(result.first.words[1].duration, 500); // 2000-1500
      expect(result.first.words[2].duration, 0); // 末位字 duration=0
    });

    test('字级 LRC：行尾的纯结束时间戳（无文本）会被跳过', () {
      // 最后一个时间戳 [00:08.181] 后面是换行，无字文本，应被跳过
      final result = LrcParser.parse('[00:01.000]湘[00:01.242]女[00:08.181]');
      expect(result, hasLength(1));
      expect(result.first.hasWordTiming, isTrue);
      // 只保留 2 个有效字（湘、女），跳过空字
      expect(result.first.words, hasLength(2));
      expect(result.first.words[0].text, '湘');
      expect(result.first.words[1].text, '女');
    });

    test('字级 LRC：行 duration = 末字 startTime + duration - 行 startTime', () {
      final result = LrcParser.parse('[00:01.000]A[00:02.000]B[00:03.000]C');
      expect(result, hasLength(1));
      // 行 startTime = 1000
      expect(result.first.startTime, 1000);
      // 末字 C duration=0, 但 lineDuration = (3000+0) - 1000 = 2000
      expect(result.first.duration, 2000);
    });

    test('字级 LRC：与一行多时间戳区分（后者时间戳间无文本）', () {
      // 一行多时间戳（无字间文本）应展开为多条 LyricLine
      final multi = LrcParser.parse('[00:10.00][00:30.00]Chorus');
      expect(multi, hasLength(2));
      expect(multi[0].hasWordTiming, isFalse);
      expect(multi[1].hasWordTiming, isFalse);
      expect(multi[0].text, 'Chorus');
      expect(multi[1].text, 'Chorus');
    });

    test('字级 LRC：保留词/曲等内容行', () {
      final lrc = '''
[00:01.000]词[00:01.500]：[00:02.000]方[00:02.500]文[00:03.000]山
[00:05.000]湘[00:05.500]女[00:06.000]多[00:06.500]情
''';
      final result = LrcParser.parse(lrc);
      expect(result, hasLength(2));
      expect(result.first.text, '词：方文山');
      expect(result.first.hasWordTiming, isTrue);
      expect(result.last.text, '湘女多情');
    });

    test('字级 LRC：保留标题行（用户主动加了字级时间戳）', () {
      final lrc =
          '[00:01.000]湘[00:01.242]女[00:02.233]多[00:03.225]情[00:04.216] - [00:05.208]周[00:06.199]杰[00:07.191]伦[00:08.181]';
      final result = LrcParser.parse(lrc);
      expect(result, hasLength(1));
      // 标题行保留（因有字级时间戳）
      expect(result.first.text, '湘女多情 - 周杰伦');
    });

    test('字级 LRC 与普通 LRC 混合解析', () {
      final lrc = '''
[00:01.000]湘[00:01.242]女[00:02.233]多[00:03.225]情
[00:05.000]Plain LRC Line
''';
      final result = LrcParser.parse(lrc);
      expect(result, hasLength(2));
      // 第 1 行：字级
      expect(result[0].hasWordTiming, isTrue);
      expect(result[0].text, '湘女多情');
      // 第 2 行：普通 LRC
      expect(result[1].hasWordTiming, isFalse);
      expect(result[1].text, 'Plain LRC Line');
    });

    test('字级 LRC：offset 偏移生效', () {
      final result = LrcParser.parse('[offset:+500]\n[00:01.000]A[00:02.000]B');
      expect(result, hasLength(1));
      expect(result.first.startTime, 500); // 1000 - 500
      expect(result.first.words[0].startTime, 500);
      expect(result.first.words[1].startTime, 1500); // 2000 - 500
    });
  });

  group('LrcParser.parse - 增强型 LRC（尖括号逐字）', () {
    test('E1. 行首 [..] 标记 + 尖括号 <..> 逐字 → hasWordTiming=true', () {
      // 参考 Lyrico EnhancedLrcWriter 输出：字时间戳与行首同时间轴（绝对时间）
      const input = '[02:04.818]<02:04.818>Wait <02:09.158>and <02:09.517>pretend<02:11.436>';
      final result = LrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.hasWordTiming, isTrue);
      expect(line.startTime, 124818); // 02:04.818
      expect(line.text, 'Wait and pretend');
      expect(line.words, hasLength(3));
      // 字 1：Wait（含空格）
      expect(line.words[0].startTime, 124818);
      expect(line.words[0].duration, 129158 - 124818); // 02:09.158 - 02:04.818
      expect(line.words[0].text, 'Wait ');
      // 字 3：pretend
      expect(line.words[2].startTime, 129517); // 02:09.517
      expect(line.words[2].text, 'pretend');
      // 行 duration = 最后一字 end - 行 start
      expect(line.duration, (129517 + (131436 - 129517)) - 124818);
    });

    test('E2. 行首时间戳不生成字，行尾结束时间戳被跳过', () {
      // 行首 [00:10.00] 是行标记；<00:10.00> 开始逐字；行尾 <00:10.90> 是结束标记（无文本，不生成字）
      const input = '[00:10.00]<00:10.00>湘<00:10.30>女<00:10.60>多<00:10.90>';
      final result = LrcParser.parse(input);

      expect(result, hasLength(1));
      final line = result.first;
      expect(line.startTime, 10000);
      expect(line.text, '湘女多');
      expect(line.words, hasLength(3));
      expect(line.words[0].startTime, 10000);
      expect(line.words[0].duration, 300);
      expect(line.words[0].text, '湘');
      expect(line.words[2].startTime, 10600);
      // 行尾 <00:10.90> 作为"多"的结束时间参与 duration（与 E1 中 pretend 行为一致）
      expect(line.words[2].duration, 300);
    });

    test('E3. 带 [offset:+] 的增强型 LRC：全局偏移应用到行与字', () {
      const input = '[offset:500]\n[00:10.00]<00:10.00>湘<00:10.30>女';
      final result = LrcParser.parse(input);

      expect(result, hasLength(1));
      expect(result.first.startTime, 9500); // 10000 - 500
      expect(result.first.words.first.startTime, 9500);
      expect(result.first.words.first.text, '湘');
    });

    test('E4. 普通 LRC 回归：无尖括号时行为不变', () {
      const input = '[00:10.00][00:30.00]Chorus';
      final result = LrcParser.parse(input);
      expect(result, hasLength(2));
      expect(result[0].text, 'Chorus');
      expect(result[0].hasWordTiming, isFalse);
      expect(result[1].startTime, 30000);
    });
  });
}

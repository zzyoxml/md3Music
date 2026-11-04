import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/lyric_info_json_builder.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'dart:convert';

void main() {
  // 带逐字 + 翻译的第一行；无逐字无翻译的第二行
  const line1 = LyricLine(
    startTime: 16440,
    duration: 2000,
    text: '歌词',
    words: [
      LyricWord(startTime: 16440, duration: 360, text: '歌'),
      LyricWord(startTime: 16800, duration: 400, text: '词'),
    ],
    translation: '翻译',
  );
  const line2 = LyricLine(startTime: 20000, duration: 1500, text: '第二行');
  // 同时带翻译与罗马音的第三行（用于独立 lane 用例）
  const line3 = LyricLine(
    startTime: 24000,
    duration: 1200,
    text: '日文原文',
    translation: '中文翻译',
    roma: 'romaji',
  );
  const inlineMain1 = LyricLine(
    startTime: 1000,
    duration: 800,
    text: 'First line',
    words: [LyricWord(startTime: 1000, duration: 800, text: 'First line')],
  );
  const inlineTranslation1 = LyricLine(
    startTime: 1000,
    duration: 0,
    text: '第一行',
  );
  const inlineMain2 = LyricLine(
    startTime: 3000,
    duration: 800,
    text: 'Second line',
    words: [LyricWord(startTime: 3000, duration: 800, text: 'Second line')],
  );
  const inlineTranslation2 = LyricLine(
    startTime: 3000,
    duration: 0,
    text: '第二行翻译',
  );
  const lineTimedMain1 = LyricLine(
    startTime: 5000,
    duration: 0,
    text: 'Line timed one',
  );
  const lineTimedTranslation1 = LyricLine(
    startTime: 5000,
    duration: 0,
    text: '行级翻译一',
  );
  const lineTimedMain2 = LyricLine(
    startTime: 7000,
    duration: 0,
    text: 'Line timed two',
  );
  const lineTimedTranslation2 = LyricLine(
    startTime: 7000,
    duration: 0,
    text: '行级翻译二',
  );

  group('buildElrcLyric', () {
    test('主行逐字 + 翻译行同时间戳', () {
      expect(
        buildElrcLyric(const [line1, line2], includeTranslation: true),
        '[00:16.440]<00:16.440>歌<00:16.800>词\n'
        '[00:16.440]翻译\n'
        '[00:20.000]<00:20.000>第二行',
      );
    });

    test('includeTranslation=false 时省略翻译行', () {
      expect(
        buildElrcLyric(const [line1], includeTranslation: false),
        '[00:16.440]<00:16.440>歌<00:16.800>词',
      );
    });

    test('无逐字行整行作一个词', () {
      expect(
        buildElrcLyric(const [line2], includeTranslation: true),
        '[00:20.000]<00:20.000>第二行',
      );
    });

    test('includeTrailingEndTag=true 时逐字行末补末尾结束标签', () {
      expect(
        buildElrcLyric(
          const [line1],
          includeTranslation: false,
          includeTrailingEndTag: true,
        ),
        '[00:16.440]<00:16.440>歌<00:16.800>词<00:17.200>',
      );
    });

    test('includeTrailingEndTag=true 时无逐字行用行 duration 作末尾标签', () {
      expect(
        buildElrcLyric(
          const [line2],
          includeTranslation: false,
          includeTrailingEndTag: true,
        ),
        '[00:20.000]<00:20.000>第二行<00:21.500>',
      );
    });

    test('includeTrailingEndTag 默认 false 保持原输出（非 colorOs 模式不受影响）', () {
      expect(
        buildElrcLyric(const [line1], includeTranslation: true),
        '[00:16.440]<00:16.440>歌<00:16.800>词\n[00:16.440]翻译',
      );
    });
  });

  group('buildPlainLrc', () {
    test('行级纯 LRC，翻译行同时间戳', () {
      expect(
        buildPlainLrc(const [line1, line2], includeTranslation: true),
        '[00:16.440]歌词\n'
        '[00:16.440]翻译\n'
        '[00:20.000]第二行',
      );
    });

    test('空文本行被跳过', () {
      const emptyLine = LyricLine(startTime: 0, duration: 0, text: '');
      expect(
        buildPlainLrc(const [emptyLine, line2], includeTranslation: true),
        '[00:20.000]第二行',
      );
    });
  });

  group('buildPlainTranslationLrc', () {
    test('只输出翻译行（同时间戳）', () {
      expect(buildPlainTranslationLrc(const [line1, line2]), '[00:16.440]翻译');
    });

    test('无翻译时返回空串', () {
      expect(buildPlainTranslationLrc(const [line2]), '');
    });
  });

  group('buildPlainRomaLrc', () {
    test('只输出罗马音行（与主行同时间戳）', () {
      expect(buildPlainRomaLrc(const [line3]), '[00:24.000]romaji');
    });

    test('无罗马音时返回空串', () {
      expect(buildPlainRomaLrc(const [line1, line2]), '');
    });

    test('罗马音与翻译互不合并，各自独立成行', () {
      expect(buildPlainRomaLrc(const [line3]), isNot(contains('中文翻译')));
      expect(buildPlainTranslationLrc(const [line3]), isNot(contains('romaji')));
    });
  });

  group('buildRawLyricLane', () {
    test('逐字行输出词级标签，不补末尾结束标签', () {
      expect(
        buildRawLyricLane(const [line1]),
        '[00:16.440]<00:16.440>歌<00:16.800>词',
      );
    });

    test('仅行级时间的行保持普通 LRC，不伪造逐字标签', () {
      expect(buildRawLyricLane(const [line2]), '[00:20.000]第二行');
    });

    test('逐字行与行级行混排时保持行对齐', () {
      expect(
        buildRawLyricLane(const [line1, line2]),
        '[00:16.440]<00:16.440>歌<00:16.800>词\n[00:20.000]第二行',
      );
    });

    test('includeTrailingEndTag=true 时逐字行末补末尾结束标签', () {
      expect(
        buildRawLyricLane(const [line1], includeTrailingEndTag: true),
        '[00:16.440]<00:16.440>歌<00:16.800>词<00:17.200>',
      );
    });

    test('includeTrailingEndTag=true 对行级行无效（不伪造词级标签）', () {
      expect(
        buildRawLyricLane(const [line2], includeTrailingEndTag: true),
        '[00:20.000]第二行',
      );
    });

    test('buildColorOsRawLyric 委托并保留末尾标签（colorOs 行为不变）', () {
      expect(
        buildColorOsRawLyric(const [line1]),
        '[00:16.440]<00:16.440>歌<00:16.800>词<00:17.200>',
      );
      expect(buildColorOsRawLyric(const [line2]), '[00:20.000]第二行');
    });
  });

  group('hasPushableTranslation', () {
    test('翻译开关开启且模型含翻译时返回 true', () {
      expect(
        hasPushableTranslation(const [line1, line2], includeTranslation: true),
        isTrue,
      );
    });

    test('翻译开关关闭时即使模型含翻译也返回 false', () {
      expect(
        hasPushableTranslation(const [line1], includeTranslation: false),
        isFalse,
      );
    });

    test('识别本地内嵌增强 LRC 的重复时间戳翻译行', () {
      expect(
        hasPushableTranslation(const [
          inlineMain1,
          inlineTranslation1,
          inlineMain2,
          inlineTranslation2,
        ], includeTranslation: true),
        isTrue,
      );
    });

    test('识别主行与翻译都无逐字信息的内嵌行级 LRC', () {
      expect(
        hasPushableTranslation(const [
          lineTimedMain1,
          lineTimedTranslation1,
          lineTimedMain2,
          lineTimedTranslation2,
        ], includeTranslation: true),
        isTrue,
      );
    });

    test('关闭翻译时内嵌重复翻译行也不会进入 payload', () {
      expect(
        hasPushableTranslation(const [
          lineTimedMain1,
          lineTimedTranslation1,
          lineTimedMain2,
          lineTimedTranslation2,
        ], includeTranslation: false),
        isFalse,
      );
    });

    test('单个标题或版权重复时间戳不误判为整首翻译', () {
      expect(
        hasPushableTranslation(const [
          inlineMain1,
          inlineTranslation1,
          line2,
        ], includeTranslation: true),
        isFalse,
      );
    });

    test('罗马音与翻译可同时存在于归一化结果（两条 lane 独立）', () {
      expect(
        hasPushableTranslation(const [line3], includeTranslation: true),
        isTrue,
      );
      expect(buildPlainRomaLrc(const [line3]), '[00:24.000]romaji');
      expect(buildPlainTranslationLrc(const [line3]), '[00:24.000]中文翻译');
    });
  });

  group('buildLyricInfoJson', () {
    test('colorOsMode=false：规范 lane 结构（lyric 纯原文 + rawLyric 逐字 + translation 独立）', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line1, line2],
        includeTranslation: true,
        colorOsMode: false,
      );
      expect(json['songName'], '测试');
      expect(json['artist'], '歌手');
      expect(json['songId'], '123');
      // lyric 只含原文主行，翻译不合并进来
      expect(json['lyric'], '[00:16.440]歌词\n[00:20.000]第二行');
      expect(json['lyric'], isNot(contains('翻译')));
      // rawLyric：逐字行保留增强标签，行级行保持普通 LRC，不补末尾标签
      expect(
        json['rawLyric'],
        '[00:16.440]<00:16.440>歌<00:16.800>词\n[00:20.000]第二行',
      );
      // 翻译为独立 lane（内容本体，不是格式标记）
      expect(json['translation'], '[00:16.440]翻译');
      // 旧格式标记已移除
      expect(json.containsKey('format'), isFalse);
      // ColorOS 专有字段不出现在规范模式
      expect(json.containsKey('lyricType'), isFalse);
      expect(json.containsKey('translationLyric'), isFalse);
      expect(json.containsKey('provider'), isFalse);
    });

    test('colorOsMode=false 无逐字时省略 rawLyric（不伪造逐字扫光）', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line2],
        includeTranslation: true,
        colorOsMode: false,
      );
      expect(json['lyric'], '[00:20.000]第二行');
      expect(json.containsKey('rawLyric'), isFalse);
      expect(json.containsKey('translation'), isFalse);
      expect(json.containsKey('format'), isFalse);
    });

    test('colorOsMode=false 关闭翻译开关时不输出 translation', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line1],
        includeTranslation: false,
        colorOsMode: false,
      );
      expect(json.containsKey('translation'), isFalse);
      expect(json['lyric'], '[00:16.440]歌词');
      expect(
        json['rawLyric'],
        '[00:16.440]<00:16.440>歌<00:16.800>词',
      );
    });

    test('colorOsMode=false 输出 roma 独立 lane（includeRoma=true）', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line3],
        includeTranslation: true,
        includeRoma: true,
        colorOsMode: false,
      );
      expect(json['lyric'], '[00:24.000]日文原文');
      expect(json['translation'], '[00:24.000]中文翻译');
      expect(json['roma'], '[00:24.000]romaji');
      // 三条 lane 互不合并
      expect(json['lyric'], isNot(contains('romaji')));
      expect(json['translation'], isNot(contains('romaji')));
      expect(json['roma'], isNot(contains('中文翻译')));
    });

    test('colorOsMode=false 默认不输出 roma（includeRoma 缺省 false）', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line3],
        includeTranslation: true,
        colorOsMode: false,
      );
      expect(json.containsKey('roma'), isFalse);
    });

    test('colorOsMode=false 输出 album，songId 为空时省略 songId', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '   ',
        album: '专辑',
        lines: const [line2],
        includeTranslation: true,
        colorOsMode: false,
      );
      expect(json['album'], '专辑');
      expect(json.containsKey('songId'), isFalse);
      expect(json.containsKey('album'), isTrue);
    });

    test('colorOsMode=false 无 album 时不写 album 字段', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line2],
        includeTranslation: true,
        colorOsMode: false,
      );
      expect(json.containsKey('album'), isFalse);
    });

    test('colorOsMode=false 曲名或歌手为空时不产出 payload', () {
      expect(
        buildLyricInfoJson(
          songName: '',
          artist: '歌手',
          songId: '123',
          lines: const [line2],
          includeTranslation: true,
          colorOsMode: false,
        ),
        isEmpty,
      );
      expect(
        buildLyricInfoJson(
          songName: '测试',
          artist: '   ',
          songId: '123',
          lines: const [line2],
          includeTranslation: true,
          colorOsMode: false,
        ),
        isEmpty,
      );
    });

    test('colorOsMode=false 内嵌行级双语拆成主 lyric 与独立 translation', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [
          lineTimedMain1,
          lineTimedTranslation1,
          lineTimedMain2,
          lineTimedTranslation2,
        ],
        includeTranslation: true,
        colorOsMode: false,
      );
      expect(json['lyric'], '[00:05.000]Line timed one\n[00:07.000]Line timed two');
      expect(
        json['translation'],
        '[00:05.000]行级翻译一\n[00:07.000]行级翻译二',
      );
      expect(json.containsKey('rawLyric'), isFalse);
    });

    test(
      'colorOsMode=true：4.0 字段集（lyric 主行纯 LRC + rawLyric 带末尾标签 + translationLyric 独立）',
      () {
        final json = buildLyricInfoJson(
          songName: '测试',
          artist: '歌手',
          songId: '123',
          lines: const [line1, line2],
          includeTranslation: true,
          colorOsMode: true,
        );
        expect(json['songName'], '测试');
        expect(json['artist'], '歌手');
        expect(json['songId'], '123');
        // 4.0 建议字段
        expect(json['lyricType'], 0);
        expect(json['noLyric'], isFalse);
        expect(json['provider'], 'com.md3music.md3music');
        expect(json['source'], 'com.md3music.md3music-v5');
        // lyric 只含主行（翻译不再合并进 lyric）
        expect(json['lyric'], '[00:16.440]歌词\n[00:20.000]第二行');
        // rawLyric：逐字行保留增强标签，逐行歌词只写普通 LRC，不伪造逐字扫光。
        expect(
          json['rawLyric'],
          '[00:16.440]<00:16.440>歌<00:16.800>词<00:17.200>\n'
          '[00:20.000]第二行',
        );
        // 翻译独立 lane
        expect(json['translationLyric'], '[00:16.440]翻译');
        expect(json.containsKey('format'), isFalse);
        expect(json.containsKey('translation'), isFalse);
      },
    );

    test('colorOsMode=true 无翻译时省略 translationLyric', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line2],
        includeTranslation: true,
        colorOsMode: true,
      );
      expect(json.containsKey('translationLyric'), isFalse);
      expect(json['lyric'], '[00:20.000]第二行');
      expect(json['rawLyric'], '[00:20.000]第二行');
    });

    test('显式空白占位行会同时保留在 lyric 与 rawLyric', () {
      const placeholder = LyricLine(
        startTime: 18000,
        duration: 1000,
        text: '\u00A0',
      );
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line1, placeholder, line2],
        includeTranslation: true,
        colorOsMode: true,
      );
      expect(json['lyric'], contains('[00:18.000]\u00A0'));
      expect(json['rawLyric'], contains('[00:18.000]\u00A0'));
    });

    test('内嵌行级双语拆成主 lyric 与独立 translationLyric', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [
          lineTimedMain1,
          lineTimedTranslation1,
          lineTimedMain2,
          lineTimedTranslation2,
        ],
        includeTranslation: true,
        colorOsMode: true,
      );
      expect(
        json['lyric'],
        '[00:05.000]Line timed one\n[00:07.000]Line timed two',
      );
      expect(json['translationLyric'], '[00:05.000]行级翻译一\n[00:07.000]行级翻译二');
      expect(
        json['rawLyric'],
        '[00:05.000]Line timed one\n[00:07.000]Line timed two',
      );
    });

    test('无逐字双语组即使翻译在前也按整首主导脚本选择主行', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [
          inlineMain1,
          inlineMain2,
          lineTimedTranslation1,
          lineTimedMain1,
          lineTimedTranslation2,
          lineTimedMain2,
        ],
        includeTranslation: true,
        colorOsMode: true,
      );
      expect(json['lyric'], contains('[00:05.000]Line timed one'));
      expect(json['lyric'], isNot(contains('[00:05.000]行级翻译一')));
      expect(json['translationLyric'], contains('[00:05.000]行级翻译一'));
    });

    test('发布边界保留版权和制作人员行并携带稳定身份字段', () {
      const copyright = LyricLine(
        startTime: 0,
        duration: 0,
        text: 'TME 享有本翻译作品的著作权',
      );
      const credit = LyricLine(
        startTime: 1000,
        duration: 0,
        text: 'Composed by: Someone',
      );
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        album: '专辑',
        trackKey: '123|测试|歌手|180',
        sessionGeneration: 7,
        lines: const [copyright, credit, line2],
        includeTranslation: true,
        colorOsMode: true,
      );
      expect(
        json['lyric'],
        '[00:00.000]TME 享有本翻译作品的著作权\n'
        '[00:01.000]Composed by: Someone\n'
        '[00:20.000]第二行',
      );
      expect(json['album'], '专辑');
      expect(json['trackKey'], '123|测试|歌手|180');
      expect(json['sessionGeneration'], 7);
    });

    test('colorOsMode=true 关闭翻译推送时即使源数据有翻译也省略 translationLyric', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line1],
        includeTranslation: false,
        colorOsMode: true,
      );
      expect(json.containsKey('translationLyric'), isFalse);
      expect(json['lyric'], '[00:16.440]歌词');
      expect(
        json['rawLyric'],
        '[00:16.440]<00:16.440>歌<00:16.800>词<00:17.200>',
      );
    });

    test('完整 JSON 可被 jsonEncode 后再解码', () {
      final json = buildLyricInfoJson(
        songName: '测试',
        artist: '歌手',
        songId: '123',
        lines: const [line1],
        includeTranslation: true,
        colorOsMode: true,
      );
      final decoded = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      expect(decoded['rawLyric'], contains('<00:16.440>'));
    });
  });
}

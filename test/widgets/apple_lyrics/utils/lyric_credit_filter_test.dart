/// 「屏蔽歌词作者信息」过滤（移植 EchoMusic 歌词过滤）单元测试。
///
/// 覆盖三层：
/// 1. 默认正则命中/不误伤（EchoMusic DEFAULT_LYRIC_FILTER_PATTERN 口径）；
/// 2. 开关门控与引用恒等语义（关闭或无命中必须返回原列表引用，
///    否则 AM 播放页的行高/模糊缓存会被无谓打穿）；
/// 3. 偏好读写与持久化（`lyric_hide_credits` / `lyric_credit_pattern`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/utils/lyric_credit_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

LyricLine _line(String text, {int start = 0}) =>
    LyricLine(startTime: start, duration: 1000, text: text);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LyricPreferences.instance.reset();
  });
  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  group('默认正则命中', () {
    setUp(() => LyricPreferences.instance.setHideLyricCredits(true));
    test('中文制作名单（作词/作曲/编曲/词：/曲:/制作人/鼓：）被过滤', () {
      const credits = [
        '作词：林夕',
        '作曲：周杰伦',
        '编曲：蔡科俊',
        '词：张三',
        '曲: 李四',
        '制作人：XXX',
        '鼓：王师傅',
        '和声：XYZ',
        'OP：XXX',
        '原唱：陈奕迅',
      ];
      for (final text in credits) {
        expect(
          LyricCreditFilter.isFilteredLine(text),
          isTrue,
          reason: '「$text」应判定为制作名单行',
        );
      }
    });

    test('英文 Lyrics by / Composed by 等被过滤', () {
      for (final text in const [
        'Lyrics by: Ed Sheeran',
        'Composed by: Taylor Swift',
        'Produced by：XXX',
        'Arranged by: ABC',
        'Mastered by: XYZ',
      ]) {
        expect(
          LyricCreditFilter.isFilteredLine(text),
          isTrue,
          reason: '「$text」应判定为英文名单行',
        );
      }
    });

    test('包装行与版权声明被过滤', () {
      for (final text in const [
        '【专辑：XXX】',
        '「制作人：YYY」',
        '『版权信息』',
        '本曲未经著作权人许可不得翻唱',
        '严禁翻录或使用',
        '听歌就在酷狗音乐',
      ]) {
        expect(
          LyricCreditFilter.isFilteredLine(text),
          isTrue,
          reason: '「$text」应判定为版权/包装行',
        );
      }
    });

    test('正常歌词不误伤（关键词不在行首、或行首但无冒号）', () {
      for (final text in const [
        '我的歌词里有词',
        '曲子真好听',
        '鼓声响起的时候',
        '词不达意也没关系',
        '编个理由骗骗自己',
        'And I love you so',
        '纯白的雪落下',
      ]) {
        expect(
          LyricCreditFilter.isFilteredLine(text),
          isFalse,
          reason: '「$text」是正常歌词，不该被过滤',
        );
      }
    });
  });

  group('开关门控与引用恒等', () {
    // 本组多数用例考察「开启后的引用语义」，统一先开启；
    // 两个「关闭」用例各自显式关掉。
    setUp(() => LyricPreferences.instance.setHideLyricCredits(true));

    test('开关关闭时不过滤任何行', () async {
      await LyricPreferences.instance.setHideLyricCredits(false);
      expect(LyricCreditFilter.isFilteredLine('作词：林夕'), isFalse);
    });

    test('开关关闭时 filterLines 返回原列表引用', () async {
      await LyricPreferences.instance.setHideLyricCredits(false);
      final lines = [_line('作词：林夕'), _line('第一句')];
      expect(identical(LyricCreditFilter.filterLines(lines), lines), isTrue);
    });

    test('开启但无命中时仍返回原列表引用', () {
      final lines = [_line('第一句'), _line('第二句')];
      expect(identical(LyricCreditFilter.filterLines(lines), lines), isTrue);
    });

    test('开启且有命中时剔除名单行并保留时间轴顺序', () {
      final lines = [
        _line('作词：林夕', start: 0),
        _line('第一句', start: 1000),
        _line('作曲：周杰伦', start: 2000),
        _line('第二句', start: 3000),
      ];
      final filtered = LyricCreditFilter.filterLines(lines);
      expect(filtered.map((l) => l.text), ['第一句', '第二句']);
      // 保留原行对象引用（时间戳/逐字数据不动）
      expect(identical(filtered[0], lines[1]), isTrue);
    });

    test('整首只有名单行时返回空列表', () {
      final lines = [_line('作词：林夕'), _line('作曲：周杰伦')];
      expect(LyricCreditFilter.filterLines(lines), isEmpty);
    });

    test('空行不滤（去留由解析器/视图既有行为决定）', () {
      final lines = [_line(''), _line('第一句')];
      final filtered = LyricCreditFilter.filterLines(lines);
      expect(filtered, hasLength(2));
    });

    test('空列表直接返回原引用', () {
      const List<LyricLine> empty = [];
      expect(identical(LyricCreditFilter.filterLines(empty), empty), isTrue);
    });
  });

  group('自定义正则', () {
    test('自定义 pattern 覆盖默认规则', () async {
      await LyricPreferences.instance.setHideLyricCredits(true);
      await LyricPreferences.instance.setCreditPattern(r'^吉他');
      expect(LyricCreditFilter.isFilteredLine('吉他：XXX'), isTrue);
      // 默认规则里的「作词：」被自定义规则取代，不再命中
      expect(LyricCreditFilter.isFilteredLine('作词：林夕'), isFalse);
    });

    test('非法自定义正则回退默认规则（不崩溃、不误滤）', () async {
      await LyricPreferences.instance.setHideLyricCredits(true);
      await LyricPreferences.instance.setCreditPattern(r'^(作词[：:]');
      expect(LyricCreditFilter.isValidPattern(r'^(作词[：:]'), isFalse);
      // 过滤器侧兜底：非法 → 用默认模式，仍命中名单行
      expect(LyricCreditFilter.isFilteredLine('作词：林夕'), isTrue);
    });

    test('isValidPattern：空串与合法正则为 true', () {
      expect(LyricCreditFilter.isValidPattern(''), isTrue);
      expect(LyricCreditFilter.isValidPattern(r'^作词'), isTrue);
      expect(LyricCreditFilter.isValidPattern('^(a'), isFalse);
    });

    test('pattern 变化后正则缓存随之更新', () async {
      await LyricPreferences.instance.setHideLyricCredits(true);
      await LyricPreferences.instance.setCreditPattern(r'^AAA');
      expect(LyricCreditFilter.isFilteredLine('AAA'), isTrue);
      expect(LyricCreditFilter.isFilteredLine('BBB'), isFalse);
      await LyricPreferences.instance.setCreditPattern(r'^BBB');
      expect(LyricCreditFilter.isFilteredLine('AAA'), isFalse);
      expect(LyricCreditFilter.isFilteredLine('BBB'), isTrue);
    });
  });

  group('偏好读写与持久化', () {
    test('默认关闭、默认为空 pattern', () {
      expect(LyricPreferences.instance.hideLyricCredits, isFalse);
      expect(LyricPreferences.instance.creditPattern, isEmpty);
    });

    test('开关 setter 落盘并通知（视图据此即时重过滤）', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      await LyricPreferences.instance.setHideLyricCredits(true);
      expect(notified, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_hide_credits'), isTrue);
    });

    test('pattern setter 落盘；传空串清除该键', () async {
      await LyricPreferences.instance.setCreditPattern(r'^吉他');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_credit_pattern'), r'^吉他');

      await LyricPreferences.instance.setCreditPattern('   ');
      expect(LyricPreferences.instance.creditPattern, isEmpty);
      expect(prefs.getString('lyric_credit_pattern'), isNull);
    });

    test('reset 恢复默认关闭与空 pattern 并清除持久化键', () async {
      await LyricPreferences.instance.setHideLyricCredits(true);
      await LyricPreferences.instance.setCreditPattern(r'^吉他');
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.hideLyricCredits, isFalse);
      expect(LyricPreferences.instance.creditPattern, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_hide_credits'), isNull);
      expect(prefs.getString('lyric_credit_pattern'), isNull);
    });
  });
}

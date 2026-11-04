/// 歌词制作名单过滤（移植自 EchoMusic `stores/lyric.ts` 的歌词过滤）。
///
/// 参考实现：EchoMusic `DEFAULT_LYRIC_FILTER_PATTERN` + `testLyricFilter`
/// （src/renderer/stores/lyric.ts:716-734）。开启后播放页 / 桌面歌词等显示面
/// 隐藏「作词：XXX」「Lyrics by: XXX」「【…】包装行」「版权声明」等元信息行，
/// 只显示纯歌词内容。
///
/// ## 判定口径（与 EchoMusic 一致）
///
/// 1. 只看主行 [LyricLine.text]（trim 后），不检查翻译/罗马音副行；
/// 2. 默认模式行首锚定（`^(作词|…)[：:]`），正常歌词句中出现的「词」「曲」
///    等字不在行首，不会误伤；
/// 3. 自定义正则留空 = 使用默认模式；自定义正则编译失败 = 回退默认模式
///    （EchoMusic `catch { return false }` 的改良：宁可漏滤也不整屏空白）；
/// 4. 空行不滤——空行去留由各解析器/视图既有行为决定，本过滤器不越权。
///
/// ## 性能约定
///
/// RegExp 按 pattern 字符串缓存，偏好未变化时每次匹配只付正则成本；
/// [filterLines] 在无命中或开关关闭时**返回原列表引用**（恒等），保护
/// `AppleLyricsView` 依赖 `identical(lines, …)` 的行高/模糊缓存不被无谓打穿。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

import '../layout/lyric_preferences.dart';

/// 歌词制作名单过滤工具（纯静态）。
class LyricCreditFilter {
  LyricCreditFilter._();

  /// 默认过滤正则（移植 EchoMusic DEFAULT_LYRIC_FILTER_PATTERN，
  /// Dart 正则语法等价：全角/半角冒号用字符类 `[：:]` 替代）。
  ///
  /// 覆盖三类：
  /// - 中文制作名单行首 + 冒号：作词/作曲/编曲/制作人/录音/混音/母带/出品/
  ///   发行/OP/SP 等（词、曲、编单字必须带冒号才命中）；
  /// - 英文名单：`Lyrics by:` / `Composed by:` / `Produced by:` 等；
  /// - 版权声明与包装行：`【…】`「…」『…』整行包裹、未经著作权人许可、
  ///   不得翻唱、翻录或使用、听歌就在。
  static const String defaultPattern =
      '^(作词|作曲|编曲|制作人|录音|混音|母带|出品|发行|企划|监制|和声|'
      '吉他|贝斯|鼓|键盘|弦乐|词|曲|编|唱片|OP|SP|原唱|翻唱|许可|音乐人|'
      '纯音乐|宣推|协作推广|策划|统筹|营销|推广|制作|配唱|和音|弦乐编写|'
      '人声录音|人声编辑)[：:]'
      '|^(Lyrics|Composed|Produced|Written|Arranged|Mixed|Mastered|'
      'Recorded|Performed) by[：:]'
      '|^[『「【].*[』」】]\$'
      '|未经著作权人许可|不得翻唱|翻录或使用|听歌就在';

  // ============== 正则缓存 ==============

  /// 缓存的 pattern 来源（含空串 = 默认）。
  static String? _cachedPatternSource;
  /// 缓存的编译结果；编译失败时回退 [_fallbackRegex]。
  static RegExp? _cachedRegex;

  /// 默认模式编译缓存（进程级一次）。
  static RegExp? _fallbackRegex;

  /// 按 pattern 字符串取编译缓存的正则。
  ///
  /// [pattern] 为空串/空白时使用 [defaultPattern]；自定义编译失败同样回退默认。
  static RegExp _regexFor(String pattern) {
    final source = pattern.trim();
    if (_cachedPatternSource == source && _cachedRegex != null) {
      return _cachedRegex!;
    }
    RegExp compiled;
    try {
      // caseSensitive: false —— OP/SP 与英文名单大小写不敏感，中文不受影响
      compiled = RegExp(source.isEmpty ? defaultPattern : source,
          caseSensitive: false);
    } catch (_) {
      compiled = _fallbackRegex ??= RegExp(defaultPattern,
          caseSensitive: false);
    }
    _cachedPatternSource = source;
    _cachedRegex = compiled;
    return compiled;
  }

  // ============== 公开 API ==============

  /// 当前过滤开关是否开启（真值源 = [LyricPreferences.hideLyricCredits]）。
  static bool get enabled => LyricPreferences.instance.hideLyricCredits;

  /// 判断一行歌词文本是否属于「作者/制作信息行」（应隐藏）。
  ///
  /// 开关未开启时恒为 false（零成本短路），调用方可放心常驻调用。
  static bool isFilteredLine(String text) {
    if (!enabled || text.isEmpty) return false;
    return _regexFor(LyricPreferences.instance.creditPattern)
        .hasMatch(text.trim());
  }

  /// 按当前偏好过滤歌词行列表。
  ///
  /// 开关关闭、列表为空、或无任何命中时返回**原列表引用**（恒等），
  /// 保证播放页视图的行高/模糊缓存不因引用变化被无谓打穿。
  static List<LyricLine> filterLines(List<LyricLine> lines) {
    if (!enabled || lines.isEmpty) return lines;
    final regex = _regexFor(LyricPreferences.instance.creditPattern);
    // 单趟扫描：命中前只记索引，命中后才开始拷贝，前面的行直接复用。
    int? firstHit;
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].text.trim();
      if (trimmed.isNotEmpty && regex.hasMatch(trimmed)) {
        firstHit = i;
        break;
      }
    }
    // 无命中：返回原列表引用（保住上层 identical 缓存判定）
    final hit = firstHit;
    if (hit == null) return lines;
    return [
      ...lines.sublist(0, hit),
      for (var i = hit; i < lines.length; i++)
        if (!_matches(lines[i], regex)) lines[i],
    ];
  }

  /// 该行是否命中过滤规则（空行恒为 false：去留由解析器/视图既有行为决定）。
  static bool _matches(LyricLine line, RegExp regex) {
    final trimmed = line.text.trim();
    return trimmed.isNotEmpty && regex.hasMatch(trimmed);
  }

  /// 校验用户自定义正则是否可编译（供设置页保存时即时提示）。
  ///
  /// 空串（= 恢复默认）恒为合法。
  static bool isValidPattern(String pattern) {
    final source = pattern.trim();
    if (source.isEmpty) return true;
    try {
      RegExp(source);
      return true;
    } catch (_) {
      return false;
    }
  }
}

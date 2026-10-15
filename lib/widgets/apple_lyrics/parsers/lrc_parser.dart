/// LRC 歌词解析器
///
/// 解析标准 LRC 格式歌词文本，输出统一的 [LyricLine] 列表。
///
/// 支持的 LRC 特性：
/// - 时间戳 `[mm:ss.xx]`（2 位毫秒，按厘秒处理）与 `[mm:ss.xxx]`（3 位毫秒）
/// - 一行多时间戳：`[00:10.00][00:30.00]Chorus` 展开为多条 [LyricLine]
/// - 字级 LRC：每行内嵌多个时间戳，形如 `[00:01.000]湘[00:01.242]女[00:02.233]多`
///   解析为单条 [LyricLine] 且 [LyricLine.words] 非空（[LyricLine.hasWordTiming] = true）
/// - 元数据行过滤：`[ar:]`、`[ti:]`、`[al:]`、`[by:]`、`[offset:]` 等
/// - 同时间戳多行：相邻多行时间戳相同时，第一行为主歌词，第二行为
///   [LyricLine.translation]，第三行为 [LyricLine.roma]，其余丢弃
///
/// 字级 LRC 与"一行多时间戳"的区分：后者时间戳之间无文本，
/// 字级 LRC 时间戳之间有非空白文本（逐字时间戳）。
/// 详见 spec.md "Requirement: LRC 解析器"。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// LRC 明文解析器。
///
/// 将标准 LRC 文本解析为 [LyricLine] 列表。所有解析失败的情况
/// （如格式损坏、抛异常）一律返回空列表，不向外抛异常。
class LrcParser {
  LrcParser._();

  /// 时间戳正则：匹配 `[mm:ss.xx]` 或 `<mm:ss.xx>`，全局可一行多次。
  /// 方括号为行级/字级时间戳（标准 LRC、字级 LRC），尖括号为增强型 LRC 逐字时间戳。
  static final RegExp _timestampRegex =
      RegExp(r'[\[<](\d{2}):(\d{2})\.(\d{2,3})[\]>]');

  /// 元数据前缀正则：匹配 LRC 元数据标签前缀，这些行不属于歌词内容。
  static final RegExp _metadataPrefixRegex = RegExp(
    r'^\[(ar|ti|al|by|offset|id|hash|total|language|sign|qq|reverb|ve):',
  );

  /// 解析 LRC 明文为 [LyricLine] 列表。
  ///
  /// 解析失败时返回空列表，不抛异常。
  static List<LyricLine> parse(String lrcText) {
    try {
      final List<LyricLine> result = [];

      // 按行拆分，兼容 \n 与 \r\n
      final lines = lrcText.split(RegExp(r'\r?\n'));

      // 先提取 [offset:±xxx] 全局时间偏移（毫秒）
      int offsetMs = 0;
      for (final rawLine in lines) {
        final offsetMatch = RegExp(
          r'^\[offset:([+-]?\d+)\]',
        ).firstMatch(rawLine.trim());
        if (offsetMatch != null) {
          offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
          break;
        }
      }

      for (final rawLine in lines) {
        final line = rawLine.trim();

        // 空行跳过
        if (line.isEmpty) continue;

        // 元数据行跳过（[ar:]/[ti:]/[offset:] 等不匹配 mm:ss.xx 格式）
        if (_metadataPrefixRegex.hasMatch(line)) continue;

        // 提取一行内所有时间戳（支持一行多时间戳）
        final matches = _timestampRegex.allMatches(line).toList();
        // 无时间戳的纯文本行跳过（不属于 LRC 标准格式）
        if (matches.isEmpty) continue;

        // 增强型 LRC 检测：行首方括号时间戳 + 至少一个尖括号时间戳。
        // 必须先于 _isWordLevelLine 判断（增强行也满足"时间戳间有文本"）。
        if (matches.length > 1 && _isEnhancedLine(matches, line)) {
          final enhancedLine = _parseEnhancedLine(line, matches, offsetMs);
          if (enhancedLine != null) {
            result.add(enhancedLine);
          }
          continue;
        }

        // 字级 LRC 检测：2+ 个时间戳且时间戳之间存在非空白文本
        // 此时整行解析为单条 LyricLine（含 words 列表）
        if (matches.length > 1 && _isWordLevelLine(matches, line)) {
          final wordLine = _parseWordLevelLine(line, matches, offsetMs);
          if (wordLine != null) {
            result.add(wordLine);
          }
          continue;
        }

        // 普通 LRC（一行一时间戳 或 一行多时间戳但无字间文本）：
        // 文本 = 最后一个时间戳之后的内容
        final lastMatch = matches.last;
        final text = line.substring(lastMatch.end).trim();

        // 有合法时间戳的空文本行是显式留白槽，不能丢弃。NBSP 不绘制可见字符，
        // 但会在播放器与 Bridge 中保留该行的布局高度和时间位置。
        if (text.isEmpty) {
          for (final match in matches) {
            final minutes = int.parse(match.group(1)!);
            final seconds = int.parse(match.group(2)!);
            final msStr = match.group(3)!;
            final milliseconds =
                int.parse(msStr) * (msStr.length == 2 ? 10 : 1);
            result.add(
              LyricLine(
                startTime:
                    (minutes * 60 + seconds) * 1000 + milliseconds - offsetMs,
                duration: 0,
                text: '\u00A0',
              ),
            );
          }
          continue;
        }

        // 为每个时间戳生成一条 LyricLine（一行多时间戳展开）
        for (final match in matches) {
          final minutes = int.parse(match.group(1)!);
          final seconds = int.parse(match.group(2)!);
          final msStr = match.group(3)!;
          // 2 位毫秒按厘秒换算（×10），3 位毫秒直接使用
          final milliseconds = int.parse(msStr) * (msStr.length == 2 ? 10 : 1);

          final startTime =
              (minutes * 60 + seconds) * 1000 + milliseconds - offsetMs;

          result.add(
            LyricLine(
              startTime: startTime,
              duration: 0, // LRC 没有行 duration 信息，由渲染层根据下一行 startTime 计算
              text: text,
              // words 默认 const []，translation 默认 null
            ),
          );
        }
      }

      // 同一时间戳的相邻行合并：第一行为主歌词，第二行为翻译，第三行为罗马音，
      // 其余丢弃。必须在排序前执行：合并依赖源码中的相邻顺序，而 List.sort 不稳定。
      final merged = _mergeDuplicateTimestampLines(result);

      // 按 startTime 升序排序。List.sort 不保证稳定性，同时间戳行（主歌词与
      // NBSP 占位行）必须保持源码相对顺序，因此带原始下标作为兜底比较键。
      final indexed = merged.asMap().entries.toList()
        ..sort((a, b) {
          final byTime = a.value.startTime.compareTo(b.value.startTime);
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });

      return indexed.map((e) => e.value).toList();
    } catch (_) {
      // 失败兜底：返回空列表，不抛异常
      return [];
    }
  }

  /// 判断是否为字级 LRC 行：连续时间戳之间存在非空白文本。
  ///
  /// 与"一行多时间戳"（如 `[00:10.00][00:30.00]Chorus`）的区别：
  /// 后者时间戳之间是空文本，展开为多条 LyricLine 共享同一文本；
  /// 前者时间戳之间是字文本，生成单条 LyricLine 且每个字有独立 startTime。
  static bool _isWordLevelLine(List<RegExpMatch> matches, String line) {
    for (int i = 0; i < matches.length - 1; i++) {
      final between = line.substring(matches[i].end, matches[i + 1].start);
      if (between.trim().isNotEmpty) return true;
    }
    return false;
  }

  /// 解析字级 LRC 行为单条 [LyricLine]（含逐字 [LyricWord]）。
  ///
  /// 输入示例：
  /// ```
  /// [00:01.000]湘[00:01.242]女[00:02.233]多[00:03.225]情[00:04.216] - [00:05.208]周[00:06.199]杰[00:07.191]伦[00:08.181]
  /// ```
  ///
  /// 算法：
  /// 1. 每个时间戳的绝对毫秒值 = `[mm:ss.xxx]` 解析值 - 全局 offsetMs
  /// 2. 字的文本 = 当前时间戳结束到下一个时间戳开始之间的子串
  /// 3. 字的 duration = 下一个时间戳 - 当前时间戳（最后无下一个时间戳则为 0）
  /// 4. 行 startTime = 第一个字 startTime
  /// 5. 行 duration = 最后一个非空字 startTime + duration - 行 startTime
  /// 6. 跳过文本为空的字（如行尾的纯结束时间戳标记）
  static LyricLine? _parseWordLevelLine(
    String line,
    List<RegExpMatch> matches,
    int offsetMs,
  ) {
    if (matches.isEmpty) return null;

    // 解析每个时间戳的绝对毫秒值
    final List<int> wordStartTimes = [];
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final msStr = match.group(3)!;
      final milliseconds = int.parse(msStr) * (msStr.length == 2 ? 10 : 1);
      wordStartTimes.add(
        (minutes * 60 + seconds) * 1000 + milliseconds - offsetMs,
      );
    }

    // 解析每个字
    final List<LyricWord> words = [];
    for (int i = 0; i < matches.length; i++) {
      // 字文本：当前时间戳结束 → 下一个时间戳开始（或行尾）
      final int textEnd = (i + 1 < matches.length)
          ? matches[i + 1].start
          : line.length;
      final String wordText = line.substring(matches[i].end, textEnd);

      // 跳过空文本字（如行尾的纯结束时间戳 [00:08.181]）
      if (wordText.isEmpty) continue;

      // 字 duration：当前时间戳 → 下一个时间戳的差值（最后一个字为 0）
      final int duration = (i + 1 < matches.length)
          ? wordStartTimes[i + 1] - wordStartTimes[i]
          : 0;

      words.add(
        LyricWord(
          startTime: wordStartTimes[i],
          duration: duration,
          text: wordText,
        ),
      );
    }

    if (words.isEmpty) return null;

    // 整行文本由所有字文本拼接
    final text = words.map((w) => w.text).join();

    // 行 startTime = 第一个字 startTime
    final lineStart = words.first.startTime;
    // 行 duration = 最后一个字 startTime + duration - 行 startTime
    final lastWord = words.last;
    final lineDuration = (lastWord.startTime + lastWord.duration) - lineStart;

    return LyricLine(
      startTime: lineStart,
      duration: lineDuration > 0 ? lineDuration : 0,
      text: text,
      words: words,
    );
  }

  /// 判断是否为增强型 LRC 行：行首是方括号时间戳，且行内存在尖括号时间戳。
  ///
  /// 与字级 LRC（全方括号 `[00:01.000]湘[00:01.242]女`）区分：
  /// 增强型 LRC 用尖括号 `<mm:ss.xx>` 表达逐字时间，行首 `[mm:ss.xx]` 仅为行标记。
  static bool _isEnhancedLine(List<RegExpMatch> matches, String line) {
    if (matches.isEmpty) return false;
    final first = matches.first.group(0)!;
    return first.startsWith('[') &&
        matches.any((m) => m.group(0)!.startsWith('<'));
  }

  /// 解析增强型 LRC 行为单条 [LyricLine]（行首 [..] 标记 + 尖括号 <..> 逐字时间戳）。
  ///
  /// 输入示例：
  /// ```
  /// [02:04.818]<02:04.818>Wait <02:09.158>and <02:09.517>pretend<02:11.436>
  /// ```
  /// 语义（参考 Lyrico EnhancedLrcParser）：
  /// - 行首 `[mm:ss.xx]` 是行起点标记，不单独成字；
  /// - 尖括号 `<mm:ss.xx>` 是逐字**绝对时间**戳，与行首时间同一时间轴；
  /// - 字的 duration = 下一个字时间戳 - 当前字时间戳（最后一个字为 0）；
  /// - 行 startTime = 行首标记时间；行 duration = 最后一字 end - 行 startTime。
  static LyricLine? _parseEnhancedLine(
      String line, List<RegExpMatch> matches, int offsetMs) {
    if (matches.isEmpty) return null;

    // 解析每个时间戳的绝对毫秒值（已应用全局 offset）
    final List<int> times = [];
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final msStr = match.group(3)!;
      // 2 位毫秒按厘秒换算（×10），3 位毫秒直接使用
      final milliseconds = int.parse(msStr) * (msStr.length == 2 ? 10 : 1);
      times.add((minutes * 60 + seconds) * 1000 + milliseconds - offsetMs);
    }

    final int lineStart = times.first; // 行首 [..] 标记时间

    // 生成字列表：跳过行首标记，跳过空文本（如行尾纯结束时间戳）
    final List<LyricWord> words = [];
    for (int i = 0; i < matches.length; i++) {
      if (i == 0) continue; // 行首标记不生成字
      final int textEnd =
          (i + 1 < matches.length) ? matches[i + 1].start : line.length;
      final String wordText = line.substring(matches[i].end, textEnd);
      if (wordText.isEmpty) continue;

      final int duration =
          (i + 1 < matches.length) ? times[i + 1] - times[i] : 0;
      words.add(LyricWord(
        startTime: times[i],
        duration: duration,
        text: wordText,
      ));
    }

    if (words.isEmpty) return null;

    // 整行文本由所有字文本拼接
    final text = words.map((w) => w.text).join();
    final lastWord = words.last;
    final lineDuration = (lastWord.startTime + lastWord.duration) - lineStart;
    return LyricLine(
      startTime: lineStart,
      duration: lineDuration > 0 ? lineDuration : 0,
      text: text,
      words: words,
    );
  }

  /// 合并源码中相邻且时间戳完全相同的行。
  ///
  /// 规则（产品需求）：同段第一行 = 主歌词，第二行 → [LyricLine.translation]，
  /// 第三行 → [LyricLine.roma]，第四行及以后丢弃。
  ///
  /// 只在**源码相邻**行之间合并：长歌词中时间戳可能周期性重复（例如每 300 行
  /// 出现一次 `[00:00.00]`），按全局时间戳分组会错误吞并正常行。
  ///
  /// 因此必须在排序前调用（排序后相邻关系失去意义，且 `List.sort` 不稳定）。
  static List<LyricLine> _mergeDuplicateTimestampLines(List<LyricLine> lines) {
    final result = List<LyricLine>.of(lines);
    final consumed = <int>{};

    var i = 0;
    while (i < lines.length) {
      var end = i + 1;
      while (end < lines.length && lines[end].startTime == lines[i].startTime) {
        end++;
      }
      if (end - i > 1) {
        _mergeDuplicateRun(lines, i, end, result, consumed);
      }
      i = end;
    }

    if (consumed.isEmpty) return result;
    final out = <LyricLine>[];
    for (var k = 0; k < result.length; k++) {
      if (consumed.contains(k)) continue;
      out.add(result[k]);
    }
    return out;
  }

  /// 合并 [start, end) 这段同时间戳的相邻行，写回 [result] 并登记 [consumed]。
  static void _mergeDuplicateRun(
    List<LyricLine> lines,
    int start,
    int end,
    List<LyricLine> result,
    Set<int> consumed,
  ) {
    // 主歌词行：优先取段内第一条带逐字时间戳的行（增强型 / 字级 LRC），
    // 否则取段内第一条。
    var mainIdx = start;
    for (var k = start; k < end; k++) {
      if (lines[k].hasWordTiming) {
        mainIdx = k;
        break;
      }
    }

    // 副行候选：除主行外文本非空、非占位 NBSP 的行，保持出现顺序
    final aux = <int>[];
    for (var k = start; k < end; k++) {
      if (k == mainIdx) continue;
      final text = lines[k].text;
      if (text.isEmpty || text == '\u00A0') continue;
      aux.add(k);
    }
    if (aux.isEmpty) return;

    // 只填空槽位：已有非空值不覆盖，对应候选行保留为独立行
    final main = result[mainIdx];
    var translation = main.translation;
    var roma = main.roma;
    final used = <int>[];
    var changed = false;

    if (translation == null || translation.isEmpty) {
      translation = lines[aux[0]].text;
      used.add(aux[0]);
      changed = true;
    }
    if ((roma == null || roma.isEmpty) && aux.length > used.length) {
      final next = aux[used.length];
      roma = lines[next].text;
      used.add(next);
      changed = true;
    }
    if (!changed) return;

    result[mainIdx] = main.copyWith(translation: translation, roma: roma);
    // 两个槽位填满后仍多余的候选行（源码中的第 4 行及以后）无处安放，按规则丢弃
    consumed.addAll(used);
    consumed.addAll(aux.where((k) => !used.contains(k)));
  }
}

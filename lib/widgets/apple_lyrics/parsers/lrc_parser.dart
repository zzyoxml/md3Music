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

  /// 时间戳正则：匹配 `[mm:ss.xx]` 或 `[mm:ss.xxx]`，全局可一行多次。
  static final RegExp _timestampRegex =
      RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\]');

  /// 元数据前缀正则：匹配 LRC 元数据标签前缀，这些行不属于歌词内容。
  static final RegExp _metadataPrefixRegex = RegExp(
    r'^\[(ar|ti|al|by|offset|id|hash|total|language|sign|qq|reverb|ve):',
  );

  /// 非歌词内容检测：匹配常见的歌词元数据文本（词/曲/编曲/制作等）
  static final RegExp _lyricsMetadataRegex = RegExp(
    r'^(词[：:]|曲[：:]|编曲[：:]|制作人[：:]|混音[：:]|录音[：:]|母带[：:]|出品[：:]|监制[：:]|和声[：:]|吉他[：:]|钢琴[：:]|贝斯[：:]|鼓[：:]|弦乐[：:]|管乐[：:]|合声[：:]|伴奏[：:]|演奏[：:]|演唱[：:]|独唱[：:]|合唱[：:]|乐团[：:]|乐队[：:])',
  );

  /// 歌曲标题行检测：匹配 "歌名 - 歌手" 或 "歌名（专辑）" 格式
  static final RegExp _songTitleRegex = RegExp(
    r'^.+\s*[-—–]\s*.+$|^.+[（(].+[）)]$',
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
        final offsetMatch = RegExp(r'^\[offset:([+-]?\d+)\]').firstMatch(rawLine.trim());
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

        // 字级 LRC 检测：2+ 个时间戳且时间戳之间存在非空白文本
        // 此时整行解析为单条 LyricLine（含 words 列表）
        if (matches.length > 1 && _isWordLevelLine(matches, line)) {
          final wordLine = _parseWordLevelLine(line, matches, offsetMs);
          if (wordLine != null) {
            // 字级 LRC 跳过纯元数据行（词：/曲： 等），但保留标题行
            // 因为用户主动给标题加了字级时间戳，意图保留
            if (_lyricsMetadataRegex.hasMatch(wordLine.text)) continue;
            result.add(wordLine);
          }
          continue;
        }

        // 普通 LRC（一行一时间戳 或 一行多时间戳但无字间文本）：
        // 文本 = 最后一个时间戳之后的内容
        final lastMatch = matches.last;
        final text = line.substring(lastMatch.end).trim();

        // 空文本行跳过
        if (text.isEmpty) continue;

        // 跳过非歌词内容（词/曲/编曲等元数据）
        if (_lyricsMetadataRegex.hasMatch(text)) continue;

        // 跳过歌曲标题行（如 "阴天快乐 - 陈奕迅 (Eason Chan)"）
        if (text.length > 5 && _songTitleRegex.hasMatch(text)) continue;

        // 为每个时间戳生成一条 LyricLine（一行多时间戳展开）
        for (final match in matches) {
          final minutes = int.parse(match.group(1)!);
          final seconds = int.parse(match.group(2)!);
          final msStr = match.group(3)!;
          // 2 位毫秒按厘秒换算（×10），3 位毫秒直接使用
          final milliseconds =
              int.parse(msStr) * (msStr.length == 2 ? 10 : 1);

          final startTime = (minutes * 60 + seconds) * 1000 + milliseconds - offsetMs;

          result.add(LyricLine(
            startTime: startTime,
            duration: 0, // LRC 没有行 duration 信息，由渲染层根据下一行 startTime 计算
            text: text,
            // words 默认 const []，translation 默认 null
          ));
        }
      }

      // 按 startTime 升序排序
      result.sort((a, b) => a.startTime.compareTo(b.startTime));

      return result;
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
      String line, List<RegExpMatch> matches, int offsetMs) {
    if (matches.isEmpty) return null;

    // 解析每个时间戳的绝对毫秒值
    final List<int> wordStartTimes = [];
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final msStr = match.group(3)!;
      final milliseconds = int.parse(msStr) * (msStr.length == 2 ? 10 : 1);
      wordStartTimes.add(
          (minutes * 60 + seconds) * 1000 + milliseconds - offsetMs);
    }

    // 解析每个字
    final List<LyricWord> words = [];
    for (int i = 0; i < matches.length; i++) {
      // 字文本：当前时间戳结束 → 下一个时间戳开始（或行尾）
      final int textEnd =
          (i + 1 < matches.length) ? matches[i + 1].start : line.length;
      final String wordText = line.substring(matches[i].end, textEnd);

      // 跳过空文本字（如行尾的纯结束时间戳 [00:08.181]）
      if (wordText.isEmpty) continue;

      // 字 duration：当前时间戳 → 下一个时间戳的差值（最后一个字为 0）
      final int duration = (i + 1 < matches.length)
          ? wordStartTimes[i + 1] - wordStartTimes[i]
          : 0;

      words.add(LyricWord(
        startTime: wordStartTimes[i],
        duration: duration,
        text: wordText,
      ));
    }

    if (words.isEmpty) return null;

    // 整行文本由所有字文本拼接
    final text = words.map((w) => w.text).join();

    // 行 startTime = 第一个字 startTime
    final lineStart = words.first.startTime;
    // 行 duration = 最后一个字 startTime + duration - 行 startTime
    final lastWord = words.last;
    final lineDuration =
        (lastWord.startTime + lastWord.duration) - lineStart;

    return LyricLine(
      startTime: lineStart,
      duration: lineDuration > 0 ? lineDuration : 0,
      text: text,
      words: words,
    );
  }
}

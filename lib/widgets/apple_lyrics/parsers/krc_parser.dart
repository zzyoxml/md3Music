/// KRC 明文歌词解析器
///
/// 解析已由 Node 侧解密/解码的 KRC 明文格式：
/// ```
/// [id:$00000000]
/// [ar:トゲナシトゲアリ]
/// [ti:運命の華]
/// [12500,4200]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華
/// ```
///
/// 行级时间戳格式：`[start_ms,duration_ms]`
/// 字级时间戳格式：`<offset,duration,property>字文本`
/// 字的绝对 startTime = 行 startTime + 字 offset
///
/// KRC 与 LRC 不同：KRC 携带逐字时间戳信息，输出的 [LyricLine.words] 非空
/// （[LyricLine.hasWordTiming] 为 true），渲染层应启用逐字 mask 渲染。
/// 详见 spec.md "Requirement: KRC 解析器"。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// KRC 明文解析器。
///
/// 将 KRC 明文解析为 [LyricLine] 列表（含逐字 [LyricWord]）。
/// 所有解析失败的情况（如格式损坏、抛异常）一律返回空列表，不向外抛异常。
class KrcParser {
  KrcParser._();

  /// 行首时间戳：`[start_ms,duration_ms]` 后接任意内容
  static final RegExp _lineTimestampRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');

  /// 字级标签：`<offset,duration>` 或 `<offset,duration,property>`
  /// property 字段可选（可能是 0 或其他整数，解析时忽略）
  static final RegExp _wordTagRegex = RegExp(r'<(-?\d+),(-?\d+)(?:,-?\d+)?>');

  /// 通用 KRC 元数据文本头正则：`[字母开头的文本标识符:...]`。
  ///
  /// 覆盖 [id:、[ar:、[manualoffset:] 等全部字母型文本头，避免枚举遗漏。
  /// 以数字开头的行（KRC 时间戳 `[123,456]`）不会命中。
  static final RegExp _metadataHeaderRegex = RegExp(r'^\[[A-Za-z][A-Za-z0-9]*:');

  /// KRC 元数据行前缀列表
  ///
  /// 这些前缀匹配的行将被跳过，不进入歌词列表。
  static const List<String> _metadataPrefixes = [
    '[id:',
    '[ar:',
    '[ti:',
    '[by:',
    '[hash:',
    '[al:',
    '[sign:',
    '[qq:',
    '[total:',
    '[offset:',
    '[language:',
    '[kana:',
  ];

  /// 解析 KRC 明文为 LyricLine 列表，失败返回空列表
  ///
  /// 输入为已解密的 KRC 明文（含元数据头与逐字行）。
  /// 任何解析失败（包括格式损坏）都不抛异常，返回空列表或部分解析结果。
  static List<LyricLine> parse(String krcText) {
    try {
      final List<LyricLine> lines = [];
      if (krcText.isEmpty) return lines;

      // 按行拆分，兼容 \n 与 \r\n
      final rawLines = krcText.split(RegExp(r'\r?\n'));
      for (final rawLine in rawLines) {
        final line = rawLine.trim();

        // 空行跳过
        if (line.isEmpty) continue;

        // 元数据行跳过
        if (_isMetadata(line)) continue;

        // 行首时间戳匹配
        final lineMatch = _lineTimestampRegex.firstMatch(line);
        if (lineMatch == null) {
          // KRC 孤立 word tag 行（无行级时间戳）：剥离标签后追加到上一行
          if (_wordTagRegex.hasMatch(line) && lines.isNotEmpty) {
            final stripped = line.replaceAll(_wordTagRegex, '').trim();
            if (stripped.isNotEmpty) {
              final lastLine = lines.last;
              lines[lines.length - 1] = LyricLine(
                startTime: lastLine.startTime,
                duration: lastLine.duration,
                text: '${lastLine.text}$stripped',
                words: lastLine.words,
              );
            }
          }
          continue;
        }

        // 解析行 startTime / duration（损坏时跳过此行）
        final int lineStart;
        final int lineDuration;
        try {
          lineStart = int.parse(lineMatch.group(1)!);
          lineDuration = int.parse(lineMatch.group(2)!);
        } catch (_) {
          continue;
        }

        // 剩余部分解析字级标签
        final rest = lineMatch.group(3) ?? '';
        final words = _parseWords(rest, lineStart);

        // 字级数据为空时，整行视为无效（无逐字信息则跳过）
        if (words.isEmpty) continue;

        // 整行文本由所有字文本拼接
        final text = words.map((w) => w.text).join();

        // 跳过非歌词内容（词/曲/编曲等元数据）
        if (_isMetadataText(text)) continue;

        lines.add(LyricLine(
          startTime: lineStart,
          duration: lineDuration,
          text: text,
          words: words,
        ));
      }

      // 按 startTime 升序排序，保证多行场景输出有序
      lines.sort((a, b) => a.startTime.compareTo(b.startTime));

      return lines;
    } catch (_) {
      // 整个解析失败时返回空列表，不抛异常
      return [];
    }
  }

  /// 判断是否为元数据行
  static bool _isMetadata(String line) {
    // 通用字母文本头（覆盖 [id:/[ar:/[manualoffset: 等全部字母头，防枚举遗漏）
    if (_metadataHeaderRegex.hasMatch(line)) return true;
    for (final prefix in _metadataPrefixes) {
      if (line.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 判断是否为非歌词内容（词/曲/编曲等元数据文本）
  static bool _isMetadataText(String text) {
    if (text.isEmpty) return false;
    // 歌曲标题行：含 " - " 或 "—" 或 "（" 格式
    if (text.length > 5 && (text.contains(' - ') || text.contains(' — ') || text.contains('（') || text.contains('('))) {
      // 检查是否包含常见元数据关键词
      final metadataKeywords = ['词：', '词:', '曲：', '曲:', '编曲', '制作人', '混音', '录音', '母带', '出品', '监制', '和声', '演唱', '演奏', '乐团', '乐队', '原唱', '翻唱', '作词', '作曲'];
      for (final keyword in metadataKeywords) {
        if (text.contains(keyword)) return true;
      }
    }
    return false;
  }

  /// 解析字级时间戳
  ///
  /// 输入是行首时间戳后的剩余部分，形如：
  /// `<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華`
  ///
  /// 每个字的文本是当前 `<...>` 标签结束位置到下一个 `<...>` 标签开始位置
  /// 之间的所有内容。使用 `String.substring` 截取，会完整保留代理对
  /// （emoji 等）与组合字符，无需额外字符迭代处理。
  static List<LyricWord> _parseWords(String rest, int lineStart) {
    final List<LyricWord> words = [];
    if (rest.isEmpty) return words;

    final matches = _wordTagRegex.allMatches(rest).toList();
    if (matches.isEmpty) return words;

    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];

      // 解析 offset / duration（损坏时跳过此字标签）
      final offset = int.tryParse(m.group(1) ?? '');
      final duration = int.tryParse(m.group(2) ?? '');
      if (offset == null || duration == null) continue;

      // 字的文本：当前标签结束 → 下一个标签开始（或字符串末尾）
      final int textEnd =
          (i + 1 < matches.length) ? matches[i + 1].start : rest.length;
      final String wordText = rest.substring(m.end, textEnd);

      // 空文本字跳过（避免无意义 word）
      if (wordText.isEmpty) continue;

      // 字的绝对 startTime = 行 startTime + 字 offset
      words.add(LyricWord(
        startTime: lineStart + offset,
        duration: duration,
        text: wordText,
      ));
    }

    return words;
  }

  /// 将 KRC 明文转换为字级 LRC 格式文本。
  ///
  /// 输入已解密的 KRC 明文，输出标准 LRC 格式但包含逐字时间戳：
  /// ```
  /// [00:08.467]湘[00:08.803]女[00:09.035]...
  /// [00:12.500]命運の華が咲く
  /// ```
  ///
  /// 解析失败或无逐字数据时返回空字符串，调用方应降级为行级 LRC。
  static String toWordLevelLrc(String krcText) {
    final lines = parse(krcText);
    if (lines.isEmpty) return '';

    final buffer = StringBuffer();
    for (final line in lines) {
      if (line.words.isEmpty) {
        // 无逐字信息，输出行级 LRC
        buffer.writeln('${_formatTimestamp(line.startTime)}${line.text}');
      } else {
        // 逐字 LRC：每个字前加时间戳
        for (final word in line.words) {
          buffer.write('${_formatTimestamp(word.startTime)}${word.text}');
        }
        buffer.writeln();
      }
    }
    return buffer.toString().trimRight();
  }

  /// 毫秒 → LRC 时间戳 `[mm:ss.xxx]`
  static String _formatTimestamp(int ms) {
    final min = (ms ~/ 60000).toString().padLeft(2, '0');
    final sec = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final millis = (ms % 1000).toString().padLeft(3, '0');
    return '[$min:$sec.$millis]';
  }
}

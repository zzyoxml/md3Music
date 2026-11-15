/// 纯文本歌词兜底解析器。
///
/// 当 KRC / LRC 解析器都失败时使用：输入是没有任何时间戳的纯文本歌词，
/// 每一行直接生成一个 [LyricLine]，所有行 `startTime=0`、`duration=0`、
/// `words=[]`（无逐字时间戳）。渲染层会走整行降级渲染路径。
///
/// 详见 spec.md "Requirement: 纯文本兜底解析器"。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// 纯文本歌词解析器。
///
/// 仅按行分割文本，不解析任何时间信息。所有 [LyricLine.startTime] 与
/// [LyricLine.duration] 均为 0，[LyricLine.words] 为空常量列表，
/// [LyricLine.hasWordTiming] 恒为 false。
class PlainTextParser {
  /// 解析纯文本为 [LyricLine] 列表。
  ///
  /// 规则：
  /// 1. 按行 split 输入文本（兼容 `\r\n` / `\n`）。
  /// 2. 每行 trim 后若非空，生成一个 [LyricLine]。
  /// 3. 空行跳过。
  /// 4. 所有行 `startTime` 均为 0，按出现顺序排列。
  /// 5. 失败返回空列表（优雅降级，不抛异常）。
  static List<LyricLine> parse(String text) {
    try {
      final lines = text.split(RegExp(r'\r\n|\n'));
      final result = <LyricLine>[];
      for (final raw in lines) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty) continue; // 空行跳过
        result.add(
          LyricLine(
            startTime: 0,
            duration: 0,
            text: trimmed,
            // 显式标注类型为 List<LyricWord>，确保与外部 `const <LyricWord>[]`
            // 引用一致（const canonicalization 按运行时类型区分）。
            words: const <LyricWord>[],
            translation: null,
          ),
        );
      }
      return result;
    } catch (_) {
      // 任何异常都返回空列表，保证优雅降级
      return const [];
    }
  }
}

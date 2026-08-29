/// 解析器链调度器。
///
/// 按优先级 KRC → LRC → 纯文本自动检测输入格式并委托给对应的解析器。
/// 检测策略基于"首个非空非元数据行"的格式：
/// - `^\[\d+,\d+\]` → KRC（行级毫秒时间戳）
/// - `^\[\d{2}:\d{2}\.\d{2,3}\]` → LRC（`[mm:ss.xx]` 时间戳）
/// - 否则 → 纯文本
///
/// 若所有行都是空行或元数据行，降级为纯文本解析。
/// 详见 spec.md "Requirement: 统一歌词模型" 与 tasks.md Task 5.3。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/krc_parser.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/lrc_parser.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/plaintext_parser.dart';

/// 歌词格式枚举，用于 [LyricParserChain.parseAs] 显式指定格式。
enum LyricFormat { krc, lrc, plaintext }

/// 歌词解析器链调度器。
///
/// 通过 [parse] 自动检测格式并委托给 [KrcParser] / [LrcParser] / [PlainTextParser]，
/// 或通过 [parseAs] 显式指定格式。所有委托方法均不抛异常（解析器内部已兜底），
/// 本调度器同样不抛异常，任何意外情况降级为纯文本。
class LyricParserChain {
  LyricParserChain._();

  /// KRC 行首时间戳正则：`[start_ms,duration_ms]` 后接任意内容。
  static final RegExp _krcLineRegex = RegExp(r'^\[\d+,\d+\]');

  /// LRC 行首时间戳正则：`[mm:ss.xx]` 或 `[mm:ss.xxx]` 后接任意内容。
  static final RegExp _lrcLineRegex = RegExp(r'^\[\d{2}:\d{2}\.\d{2,3}\]');

  /// 通用 KRC/LRC 元数据文本头正则：`[字母开头的文本标识符:...]`。
  ///
  /// 覆盖所有字母型文本头（[id:、[ar:、[ti:、[total:、[language:[manualoffset:] 等），
  /// 避免枚举遗漏导致格式误判。以数字开头的行（KRC `[123,456]`、LRC `[01:02.03]`）不会命中。
  static final RegExp _metadataHeaderRegex = RegExp(r'^\[[A-Za-z][A-Za-z0-9]*:');

  /// 元数据行前缀列表（KRC 与 LRC 合并去重，两者完全一致）。
  ///
  /// 这些前缀匹配的行在自动检测时会被跳过，不参与首行格式判断。
  /// 例如 KRC 文件首行通常是 `[id:$00000000]`，第二行才是
  /// `[12500,4200]<0,300,0>運...`，调度器需要跳过元数据行后才判断。
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

  /// 自动检测格式并解析，按优先级 KRC → LRC → 纯文本。
  ///
  /// 检测逻辑：找到首个非空非元数据行，用正则匹配其前缀决定走哪个解析器；
  /// 若所有行均为空或元数据，降级为纯文本解析。
  ///
  /// 若传入 [translationText]，解析完成后会按时间戳最近邻匹配将翻译合并到
  /// 各行。容差 500ms；翻译文本无时间戳时降级为按行序号顺序匹配。
  ///
  /// [romaText] 同理，但合并到 [LyricLine.roma] 字段（与 translation 并列）。
  static List<LyricLine> parse(String text,
      {String? translationText, String? romaText}) {
    try {
      final format = detectFormat(text);
      var lines = _delegate(text, format);
      if (translationText != null && translationText.isNotEmpty) {
        lines = _mergeField(lines, translationText, isRoma: false);
      }
      if (romaText != null && romaText.isNotEmpty) {
        lines = _mergeField(lines, romaText, isRoma: true);
      }
      return lines;
    } catch (_) {
      // 任何意外都降级纯文本，保证不抛异常
      return PlainTextParser.parse(text);
    }
  }

  /// 显式指定格式解析（可选辅助方法）。
  ///
  /// 调用方已知格式时可直接指定，跳过自动检测。例如外部已通过文件扩展名
  /// 或服务端字段确认是 KRC，可直接 `parseAs(text, LyricFormat.krc)`。
  ///
  /// 若传入 [translationText]，解析完成后会按时间戳最近邻匹配将翻译合并到
  /// 各行。容差 500ms；翻译文本无时间戳时降级为按行序号顺序匹配。
  ///
  /// [romaText] 同理，但合并到 [LyricLine.roma] 字段。
  static List<LyricLine> parseAs(String text, LyricFormat format,
      {String? translationText, String? romaText}) {
    try {
      var lines = _delegate(text, format);
      if (translationText != null && translationText.isNotEmpty) {
        lines = _mergeField(lines, translationText, isRoma: false);
      }
      if (romaText != null && romaText.isNotEmpty) {
        lines = _mergeField(lines, romaText, isRoma: true);
      }
      return lines;
    } catch (_) {
      return PlainTextParser.parse(text);
    }
  }

  /// 将翻译/罗马音 LRC 文本按时间戳对齐到原文行（泛化版）。
  ///
  /// 算法：
  /// 1. 用 [LrcParser] 解析 text 得到 [List<LyricLine>]（仅取 startTime + text）
  /// 2. 对每个原文行，查找时间戳差值最小且 <= 500ms 的翻译行
  /// 3. 命中则用 [LyricLine.copyWith] 替换原文行的 translation 或 roma 字段
  ///
  /// 容差 500ms 用于吸收 KRC（毫秒）vs LRC 翻译（百分秒）轻微错位。
  /// 若文本无法解析为 LRC（无时间戳行），降级按行序号顺序匹配。
  ///
  /// [isRoma] 为 true 时写入 [LyricLine.roma]，否则写入 [LyricLine.translation]。
  static List<LyricLine> _mergeField(
      List<LyricLine> lines, String text, {required bool isRoma}) {
    final fieldLines = LrcParser.parse(text);
    final fieldLabel = isRoma ? 'roma' : 'translation';
    debugPrint('[LyriconDebug._mergeField] '
        'lines.len=${lines.length}, $fieldLabel.len=${text.length}, '
        'fieldLines.len=${fieldLines.length}, '
        'hasTimestamps=${fieldLines.any((l) => l.startTime > 0)}');
    if (fieldLines.isEmpty) return lines;

    // 降级判断：若解析后所有行 startTime 都是 0，说明是纯文本（无时间戳），
    // 按行序号顺序匹配；否则用最近邻时间戳匹配
    final hasTimestamps = fieldLines.any((l) => l.startTime > 0);

    final List<LyricLine> result = [];
    int matchedCount = 0;
    for (int i = 0; i < lines.length; i++) {
      String? matched;
      if (hasTimestamps) {
        // 最近邻：找时间戳差值最小且 <= 500ms 的行
        int bestDelta = 501; // 容差 +1 作为哨兵
        for (final tl in fieldLines) {
          final delta = (tl.startTime - lines[i].startTime).abs();
          if (delta <= 500 && delta < bestDelta) {
            bestDelta = delta;
            matched = tl.text;
          }
        }
      } else {
        // 降级：按行序号匹配
        if (i < fieldLines.length) {
          matched = fieldLines[i].text;
        }
      }
      if (matched != null) matchedCount++;
      result.add(matched == null
          ? lines[i]
          : isRoma
              ? lines[i].copyWith(roma: matched)
              : lines[i].copyWith(translation: matched));
    }
    debugPrint('[LyriconDebug._mergeField] $fieldLabel matched=$matchedCount/${lines.length}');
    return result;
  }

  /// 检测输入文本的歌词格式。
  ///
  /// 算法：
  /// 1. 按行 split（兼容 `\r\n` / `\n`）
  /// 2. 跳过空行（trim 后为空）
  /// 3. 跳过元数据行（匹配 [_metadataPrefixes] 任一前缀）
  /// 4. 找到首个非空非元数据行后，用正则检测：
  ///    - 匹配 [_krcLineRegex] → [LyricFormat.krc]
  ///    - 匹配 [_lrcLineRegex] → [LyricFormat.lrc]
  ///    - 否则 → [LyricFormat.plaintext]
  /// 5. 若所有行都是空或元数据，降级为 [LyricFormat.plaintext]
  static LyricFormat detectFormat(String text) {
    if (text.isEmpty) return LyricFormat.plaintext;

    final lines = text.split(RegExp(r'\r?\n'));
    for (final rawLine in lines) {
      final line = rawLine.trim();

      // 空行跳过
      if (line.isEmpty) continue;

      // 元数据行跳过
      if (_isMetadata(line)) continue;

      // 找到首个非空非元数据行，用正则检测格式
      if (_krcLineRegex.hasMatch(line)) {
        return LyricFormat.krc;
      }
      if (_lrcLineRegex.hasMatch(line)) {
        return LyricFormat.lrc;
      }
      return LyricFormat.plaintext;
    }

    // 所有行均为空或元数据，降级纯文本
    return LyricFormat.plaintext;
  }

  /// 按格式委托给对应解析器。
  static List<LyricLine> _delegate(String text, LyricFormat format) {
    switch (format) {
      case LyricFormat.krc:
        return KrcParser.parse(text);
      case LyricFormat.lrc:
        return LrcParser.parse(text);
      case LyricFormat.plaintext:
        return PlainTextParser.parse(text);
    }
  }

  /// 判断是否为元数据行（KRC 与 LRC 共用同一套前缀）。
  static bool _isMetadata(String line) {
    // 通用字母文本头（覆盖 [id:/[ar:/[manualoffset: 等全部字母头，防枚举遗漏）
    if (_metadataHeaderRegex.hasMatch(line)) return true;
    for (final prefix in _metadataPrefixes) {
      if (line.startsWith(prefix)) return true;
    }
    return false;
  }
}

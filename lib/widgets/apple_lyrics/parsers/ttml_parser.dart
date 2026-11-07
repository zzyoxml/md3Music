/// TTML 歌词解析器。
///
/// 解析 Apple Music 风格 TTML（Timed Text Markup Language）XML 歌词，
/// 输出统一的 [LyricLine] 列表。逻辑参考 Lyrico-master 的 TtmlParser 移植。
///
/// 支持的 TTML 特性：
/// - `<p begin end>` 行级时间戳；
/// - 嵌套 `<span begin end>` 逐字时间戳 → [LyricWord]；
/// - `ttm:role="x-translation"` / `"x-romanization"` 内联翻译/罗马音；
/// - `<iTunesMetadata><translations><text for=...>` 头部翻译（按 itunes:key 关联）；
/// - `ttm:role="x-bg"` 背景歌词（渲染层无背景轨，忽略）。
///
/// 所有解析失败（非法 XML / 非 XML 文本）一律返回空列表，不抛异常。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:xml/xml.dart';

/// 私有中间结构：解析后的行（含翻译/罗马音，供合并阶段使用）。
class _TtmlLine {
  final int? startTime;
  final int? endTime;
  final String text;
  final List<LyricWord> words;
  final String? linkKey;
  final String? agentId;
  final String translation;
  final String roma;

  const _TtmlLine({
    this.startTime,
    this.endTime,
    this.text = '',
    this.words = const [],
    this.linkKey,
    this.agentId,
    this.translation = '',
    this.roma = '',
  });
}

/// 私有结构：单个 <p> 的解析结果。
class _ParsedP {
  final String originalText;
  final String translationText;
  final String romanizationText;
  final List<LyricWord> words;

  const _ParsedP({
    this.originalText = '',
    this.translationText = '',
    this.romanizationText = '',
    this.words = const [],
  });
}

/// TTML 歌词解析器。
class TtmlParser {
  TtmlParser._();

  static const String _nsTtm = 'http://www.w3.org/ns/ttml#metadata';
  static const String _nsItunesInternal = 'http://music.apple.com/lyric-ttml-internal';
  static const String _nsItunesLegacy = 'http://music.apple.com/itunes/ttml';

  /// 解析 TTML 文本为 [LyricLine] 列表，失败返回空列表。
  static List<LyricLine> parse(String raw) {
    if (raw.trim().isEmpty) return [];
    try {
      final doc = XmlDocument.parse(raw);
      final root = doc.rootElement;

      // 阶段 1：收集 metadata 翻译（itunes:key → 文本）
      final metadataTranslations = <String, String>{};
      for (final tr in root.descendants
          .whereType<XmlElement>()
          .where((e) => e.localName == 'translation')) {
        for (final textEl in tr.childElements.where((e) => e.localName == 'text')) {
          final key = textEl.getAttribute('for');
          if (key != null && key.isNotEmpty) {
            metadataTranslations[key] =
                _normalizeText(textEl.innerText, trimEdges: true);
          }
        }
      }

      // 阶段 2：解析所有 <p>
      final mainLines = <_TtmlLine>[];
      final translationLines = <_TtmlLine>[];
      final romaLines = <_TtmlLine>[];
      for (final p in root.descendants
          .whereType<XmlElement>()
          .where((e) => e.localName == 'p')) {
        final beginStr = p.getAttribute('begin');
        final endStr = p.getAttribute('end');
        final begin = beginStr != null ? _parseTtmlTimeMs(beginStr) : null;
        final end = endStr != null ? _parseTtmlTimeMs(endStr) : null;
        if (begin == null && end == null) continue;

        final role = _attr(p, 'role', _nsTtm);
        final linkKey = _attr(p, 'key', _nsItunesInternal) ??
            _attr(p, 'key', _nsItunesLegacy) ??
            p.getAttribute('key');
        // 演唱者标识（对唱用）：仅主行携带，翻译/罗马音行不带
        final agentId = _attr(p, 'agent', _nsTtm);

        final parsed = _parseP(p, begin ?? 0, end ?? (begin ?? 0));
        final tml = _TtmlLine(
          startTime: begin,
          endTime: end,
          text: parsed.originalText,
          words: parsed.words,
          linkKey: linkKey,
          agentId: agentId,
          translation: parsed.translationText,
          roma: parsed.romanizationText,
        );
        switch (role) {
          case 'x-translation':
            translationLines.add(tml);
            break;
          case 'x-romanization':
            romaLines.add(tml);
            break;
          default:
            mainLines.add(tml);
        }
      }

      // 阶段 3：合并翻译/罗马音到主行，输出统一 LyricLine
      final result = <LyricLine>[];
      for (final ml in mainLines) {
        var translation = ml.translation;
        if (translation.isEmpty && ml.linkKey != null) {
          translation = metadataTranslations[ml.linkKey] ?? '';
        }
        if (translation.isEmpty) {
          translation = _findByStart(translationLines, ml.startTime) ?? '';
        }

        var roma = ml.roma;
        if (roma.isEmpty) {
          roma = _findByStart(romaLines, ml.startTime) ?? '';
        }

        result.add(LyricLine(
          startTime: ml.startTime ?? 0,
          duration: _lineDurationMs(ml),
          text: ml.text,
          words: ml.words,
          translation: translation.isEmpty ? null : translation,
          roma: roma.isEmpty ? null : roma,
          agentId: ml.agentId,
        ));
      }

      result.sort((a, b) => a.startTime.compareTo(b.startTime));
      return result;
    } catch (_) {
      // 非法 XML / 非 XML 文本兜底
      return [];
    }
  }

  /// 行 duration：优先 <p end - begin>，否则最后字 end - 行 start。
  static int _lineDurationMs(_TtmlLine line) {
    final start = line.startTime ?? 0;
    if (line.endTime != null) {
      final d = line.endTime! - start;
      return d > 0 ? d : 0;
    }
    if (line.words.isNotEmpty) {
      final last = line.words.last;
      final d = (last.startTime + last.duration) - start;
      return d > 0 ? d : 0;
    }
    return 0;
  }

  /// 按 startTime 精确匹配副行（翻译/罗马音）。
  static String? _findByStart(List<_TtmlLine> lines, int? startTime) {
    if (startTime == null) return null;
    for (final l in lines) {
      if (l.startTime == startTime && l.text.isNotEmpty) return l.text;
    }
    return null;
  }

  /// 解析单个 <p>：收集主文本、逐字 words、内联翻译/罗马音。
  static _ParsedP _parseP(XmlElement p, int fallbackStart, int fallbackEnd) {
    final words = <LyricWord>[];
    final original = StringBuffer();
    final translation = StringBuffer();
    final romanization = StringBuffer();

    void appendOriginalText(String text) {
      // 仅由换行/缩进组成的格式化空白：忽略（不进入歌词文本）
      if (text.trim().isEmpty) return;
      final normalized = _normalizeText(text);
      if (normalized.isEmpty) return;
      if (words.isNotEmpty) {
        // 出现字级时间戳后的游离文本：合并到最后一个字（参考 Lyrico）
        final last = words.removeLast();
        words.add(LyricWord(
          startTime: last.startTime,
          duration: last.duration,
          text: last.text + normalized,
        ));
      } else {
        original.write(normalized);
      }
    }

    void visit(XmlNode node) {
      if (node is XmlText || node is XmlCDATA) {
        final value = node.value;
        if (value != null) appendOriginalText(value);
      } else if (node is XmlElement) {
        final role = _attr(node, 'role', _nsTtm);
        final text = _collectVisibleText(node);
        switch (role) {
          case 'x-translation':
            translation.write(_normalizeText(text, trimEdges: true));
            return;
          case 'x-romanization':
            romanization.write(_normalizeText(text, trimEdges: true));
            return;
          case 'x-bg':
            return; // 背景歌词：渲染层无背景轨，忽略
          default:
            final beginStr = node.getAttribute('begin');
            final endStr = node.getAttribute('end');
            final begin = beginStr != null ? _parseTtmlTimeMs(beginStr) : null;
            final end = endStr != null ? _parseTtmlTimeMs(endStr) : null;
            if (begin != null) {
              final normalized = _normalizeText(text, trimEdges: false);
              final isFormattingWhitespace = normalized.isEmpty &&
                  (text.contains('\n') || text.contains('\r'));
              if (normalized.isNotEmpty && !isFormattingWhitespace) {
                final endMs = end ?? fallbackEnd;
                words.add(LyricWord(
                  startTime: begin,
                  duration: endMs > begin ? (endMs - begin) : 0,
                  text: normalized,
                ));
              }
            } else {
              node.children.forEach(visit);
            }
        }
      }
    }

    p.children.forEach(visit);

    final finalOriginal = words.isNotEmpty
        ? words.map((w) => w.text).join()
        : _normalizeText(original.toString(), trimEdges: true);

    return _ParsedP(
      originalText: finalOriginal,
      translationText: _normalizeText(translation.toString(), trimEdges: true),
      romanizationText: _normalizeText(romanization.toString(), trimEdges: true),
      words: words.isEmpty
          ? (finalOriginal.isEmpty
              ? const []
              : [
                  LyricWord(
                    startTime: fallbackStart,
                    duration: fallbackEnd > fallbackStart
                        ? (fallbackEnd - fallbackStart)
                        : 0,
                    text: finalOriginal,
                  ),
                ])
          : words,
    );
  }

  /// 递归收集元素内所有可见文本（含 CDATA）。
  static String _collectVisibleText(XmlElement e) {
    final buf = StringBuffer();
    void visit(XmlNode node) {
      if (node is XmlText || node is XmlCDATA) {
        final value = node.value;
        if (value != null) buf.write(_normalizeText(value));
      } else if (node is XmlElement) {
        node.children.forEach(visit);
      }
    }

    e.children.forEach(visit);
    return buf.toString();
  }

  /// 属性读取（含命名空间 fallback，参考 Lyrico Element.attr）。
  static String? _attr(XmlElement e, String localName, String? namespace) {
    if (namespace != null) {
      final v = e.getAttribute(localName, namespace: namespace);
      if (v != null && v.isNotEmpty) return v;
    }
    final v = e.getAttribute(localName);
    if (v != null && v.isNotEmpty) return v;
    for (final a in e.attributes) {
      if (a.name.local == localName && a.value.isNotEmpty) return a.value;
    }
    return null;
  }

  /// TTML 文本规范化：换行/多空白折叠为单空格（参考 Lyrico normalizeTtmlText）。
  static String _normalizeText(String text, {bool trimEdges = false}) {
    if (!text.contains('\n') && !text.contains('\r')) {
      return trimEdges ? text.trim() : text;
    }
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
    return trimEdges ? collapsed.trim() : collapsed;
  }

  /// TTML 时间解析（毫秒）。支持：
  /// - `1000ms` / `1s` / `1.000`（裸数字按秒）
  /// - `00:01.000` / `00:00:01.000`
  static int _parseTtmlTimeMs(String value) {
    final text = value.trim();

    Match? m = RegExp(r'^(\d+(?:\.\d+)?)ms$').firstMatch(text);
    if (m != null) return (double.parse(m.group(1)!) * 1).round();

    m = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(text);
    if (m != null) return (double.parse(m.group(1)!) * 1000).round();

    m = RegExp(r'^(\d+(?:\.\d+)?)$').firstMatch(text);
    if (m != null) return (double.parse(m.group(1)!) * 1000).round();

    m = RegExp(r'^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$').firstMatch(text);
    if (m != null) {
      final frac = m.group(4) ?? '';
      final msPart =
          frac.isEmpty ? 0 : int.parse(frac.padRight(3, '0').substring(0, 3));
      return (int.parse(m.group(1)!) * 3600 +
              int.parse(m.group(2)!) * 60 +
              int.parse(m.group(3)!)) *
              1000 +
          msPart;
    }

    m = RegExp(r'^(\d+):(\d{2})(?:\.(\d+))?$').firstMatch(text);
    if (m != null) {
      final frac = m.group(3) ?? '';
      final msPart =
          frac.isEmpty ? 0 : int.parse(frac.padRight(3, '0').substring(0, 3));
      return (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000 +
          msPart;
    }

    return 0;
  }
}

/// LyricInfo 歌词 JSON 构造（纯函数，供单测）。
///
/// 支持两种输出模式：
/// - 默认（colorOsMode=false）：兼容 limczhh LyricInfo / HyperLyric 系——
///   `lyric` 为 ELRC（行标签 + 词级标签 + 同时间戳翻译行），带 `format:'elrc'`、
///   有翻译时带 `translation:'lrc'`。
/// - ColorOS Bridge 模式（colorOsMode=true）：兼容
///   ColorOS-Live-Lyrics-Bridge（Andrea-lyz）开放协议——`lyric` 为纯 LRC 行级、
///   `rawLyric` 为 ELRC 逐字（插件据此启用逐字高亮等增强），不输出
///   format/translation 字段。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// 毫秒 → LRC 行级时间标签 [mm:ss.xxx]
String lrcTagMs(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final msPart = ms % 1000;
  return '[${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${msPart.toString().padLeft(3, '0')}]';
}

/// 毫秒 → ELRC 词级时间标签 <mm:ss.xxx>
String elrcWordTag(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final msPart = ms % 1000;
  return '<${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${msPart.toString().padLeft(3, '0')}>';
}

/// 构造 ELRC 歌词：主行 `[行时间]<字时间>字<字时间>字...`，无逐字的行整行作一个词；
/// [includeTranslation] 时在每行后追加同时间戳的 LRC 翻译行。
/// [includeTrailingEndTag] 为 true 时，在每行末尾追加 `<最后字/行结束时间>` 标签
/// （4.0 逐字 lane 规则 4：用末尾标签标记视觉结束点；仅 rawLyric 使用，避免影响
/// 非 colorOs 模式的 lyric 输出）。
String buildElrcLyric(
  List<LyricLine> lines, {
  required bool includeTranslation,
  bool includeTrailingEndTag = false,
}) {
  final buf = StringBuffer();
  for (final line in lines) {
    if (line.text.isEmpty) continue;
    buf.write(lrcTagMs(line.startTime));
    if (line.hasWordTiming) {
      for (final w in line.words) {
        buf
          ..write(elrcWordTag(w.startTime))
          ..write(w.text);
      }
      if (includeTrailingEndTag && line.words.isNotEmpty) {
        final last = line.words.last;
        if (last.duration > 0) {
          buf.write(elrcWordTag(last.startTime + last.duration));
        }
      }
    } else {
      buf
        ..write(elrcWordTag(line.startTime))
        ..write(line.text);
      if (includeTrailingEndTag && line.duration > 0) {
        buf.write(elrcWordTag(line.startTime + line.duration));
      }
    }
    buf.write('\n');
    final t = includeTranslation ? line.translation : null;
    if (t != null && t.isNotEmpty) {
      buf
        ..write(lrcTagMs(line.startTime))
        ..write(t)
        ..write('\n');
    }
  }
  return buf.toString().trimRight();
}

/// 构造纯 LRC 歌词：每行 `[行时间]文本`，[includeTranslation] 时追加同时间戳翻译行。
String buildPlainLrc(
  List<LyricLine> lines, {
  required bool includeTranslation,
}) {
  final buf = StringBuffer();
  for (final line in lines) {
    if (line.text.isEmpty) continue;
    buf
      ..write(lrcTagMs(line.startTime))
      ..write(line.text)
      ..write('\n');
    final t = includeTranslation ? line.translation : null;
    if (t != null && t.isNotEmpty) {
      buf
        ..write(lrcTagMs(line.startTime))
        ..write(t)
        ..write('\n');
    }
  }
  return buf.toString().trimRight();
}

/// 构造翻译 lane（4.0 `translationLyric`）：只输出翻译行，`[行时间]翻译文本`。
/// 每条翻译只对齐一次；罗马音/音译/注音不写入此 lane。
String buildPlainTranslationLrc(List<LyricLine> lines) {
  final buf = StringBuffer();
  for (final line in lines) {
    final t = line.translation;
    if (t != null && t.isNotEmpty) {
      buf
        ..write(lrcTagMs(line.startTime))
        ..write(t)
        ..write('\n');
    }
  }
  return buf.toString().trimRight();
}

/// 构造 Bridge 渲染 lane：逐字行保留真实增强时间轴，逐行歌词只写普通 LRC，
/// 让 Bridge 建立 LINE_TIMED 模型而不伪造逐字扫光。
String buildColorOsRawLyric(List<LyricLine> lines) {
  final buf = StringBuffer();
  for (final line in lines) {
    if (line.text.isEmpty) continue;
    buf.write(lrcTagMs(line.startTime));
    if (line.hasWordTiming) {
      for (final word in line.words) {
        buf
          ..write(elrcWordTag(word.startTime))
          ..write(word.text);
      }
      final last = line.words.last;
      if (last.duration > 0) {
        buf.write(elrcWordTag(last.startTime + last.duration));
      }
    } else {
      buf.write(line.text);
    }
    buf.write('\n');
  }
  return buf.toString().trimRight();
}

String _identityText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$'), '')
    .replaceAll(RegExp(r'[\s\-—–_·•|/\\（）()\[\]【】]+'), '');

class _ColorOsLyricLines {
  final List<LyricLine> main;

  const _ColorOsLyricLines(this.main);
}

enum _LyricScript { latin, cjk, other }

_LyricScript _lyricScript(String text) {
  int latin = 0;
  int cjk = 0;
  for (final rune in text.runes) {
    if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    } else if ((rune >= 0x3400 && rune <= 0x9FFF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF)) {
      cjk++;
    }
  }
  if (latin == 0 && cjk == 0) return _LyricScript.other;
  return latin >= cjk ? _LyricScript.latin : _LyricScript.cjk;
}

_LyricScript _dominantPrimaryScript(List<LyricLine> lines) {
  int latin = 0;
  int cjk = 0;
  // 逐字行是主歌词最可靠的样本，不让无逐字翻译行反向主导语言判断。
  final wordTimed = lines.where((line) => line.hasWordTiming).toList();
  final samples = wordTimed.isNotEmpty ? wordTimed : lines;
  for (final line in samples) {
    final script = _lyricScript(line.text);
    if (script == _LyricScript.latin) latin++;
    if (script == _LyricScript.cjk) cjk++;
  }
  if (latin == 0 && cjk == 0) return _LyricScript.other;
  return latin >= cjk ? _LyricScript.latin : _LyricScript.cjk;
}

/// 把解析器可能产出的“同时间戳主行 + 翻译独立行”归一成 v5 的主行与
/// [LyricLine.translation]。歌词正文不做版权、来源或制作人员内容过滤。
_ColorOsLyricLines _normalizeColorOsLyricLines(
  List<LyricLine> lines, {
  required bool includeTranslation,
}) {
  final filtered = lines
      .where((line) => line.text.isNotEmpty)
      .toList(growable: false);
  if (filtered.isEmpty) return const _ColorOsLyricLines([]);

  // 两组以上重复时间戳才视为双语结构，避免单个同唱/标题行被误当翻译。
  int bilingualGroupCount = 0;
  int start = 0;
  while (start < filtered.length) {
    final timestamp = filtered[start].startTime;
    int end = start + 1;
    final texts = <String>{filtered[start].text.trim()};
    while (end < filtered.length && filtered[end].startTime == timestamp) {
      texts.add(filtered[end].text.trim());
      end++;
    }
    if (texts.where((text) => text.isNotEmpty).length > 1) {
      bilingualGroupCount++;
    }
    start = end;
  }
  final hasInlineBilingualLane = bilingualGroupCount >= 2;
  final dominantScript = _dominantPrimaryScript(filtered);

  final normalized = <LyricLine>[];
  start = 0;
  while (start < filtered.length) {
    final timestamp = filtered[start].startTime;
    int end = start + 1;
    while (end < filtered.length && filtered[end].startTime == timestamp) {
      end++;
    }
    final group = filtered.sublist(start, end);
    if (!hasInlineBilingualLane || group.length == 1) {
      normalized.addAll(
        group.map(
          (line) =>
              includeTranslation ? line : line.copyWith(clearTranslation: true),
        ),
      );
      start = end;
      continue;
    }

    final primary = group.firstWhere(
      (line) => line.hasWordTiming,
      orElse: () => group.firstWhere(
        (line) => _lyricScript(line.text) == dominantScript,
        orElse: () => group.first,
      ),
    );
    String? translation = includeTranslation ? primary.translation : null;
    if (includeTranslation && (translation == null || translation.isEmpty)) {
      for (final candidate in group) {
        final text = candidate.text == '\u00A0'
            ? candidate.text
            : candidate.text.trim();
        if (!identical(candidate, primary) &&
            text.isNotEmpty &&
            _identityText(text) != _identityText(primary.text)) {
          translation = text;
          break;
        }
      }
    }
    normalized.add(
      primary.copyWith(
        translation: translation,
        clearTranslation: !includeTranslation,
      ),
    );
    start = end;
  }
  return _ColorOsLyricLines(normalized);
}

/// 当前推送配置下是否存在应发布到 ColorOS 的真实翻译。
///
/// 与 ColorOS payload 使用同一归一化规则，保证按钮能力与实际 translationLyric 一致。
bool hasPushableTranslation(
  List<LyricLine> lines, {
  required bool includeTranslation,
}) {
  if (!includeTranslation) return false;
  final normalized = _normalizeColorOsLyricLines(
    lines,
    includeTranslation: true,
  );
  return normalized.main.any((line) => line.translation?.isNotEmpty ?? false);
}

/// 组装 lyricInfo JSON map（供 `MediaNotificationService.updateLyricInfo` jsonEncode）。
///
/// [includeTranslation] 对应设置页共用「翻译歌词」开关。返回空 map 表示无有效歌词。
Map<String, dynamic> buildLyricInfoJson({
  required String songName,
  required String artist,
  required String songId,
  required List<LyricLine> lines,
  required bool includeTranslation,
  required bool colorOsMode,
  String? album,
  String? trackKey,
  int? sessionGeneration,
}) {
  if (colorOsMode) {
    final normalized = _normalizeColorOsLyricLines(
      lines,
      includeTranslation: includeTranslation,
    );
    final mainLines = normalized.main;
    final lyric = buildPlainLrc(mainLines, includeTranslation: false);
    if (lyric.isEmpty) return const {};
    final rawLyric = buildColorOsRawLyric(mainLines);
    final transLrc = includeTranslation
        ? buildPlainTranslationLrc(mainLines)
        : '';
    return {
      'songName': songName,
      'artist': artist,
      'songId': songId,
      'lyricType': 0,
      'lyric': lyric,
      if (rawLyric.isNotEmpty) 'rawLyric': rawLyric,
      if (transLrc.isNotEmpty) 'translationLyric': transLrc,
      'noLyric': false,
      'provider': 'com.md3music.md3music',
      'source': 'com.md3music.md3music-v5',
      if (album != null && album.isNotEmpty) 'album': album,
      if (trackKey != null && trackKey.isNotEmpty) 'trackKey': trackKey,
      if (sessionGeneration != null && sessionGeneration > 0)
        'sessionGeneration': sessionGeneration,
    };
  }
  final elrc = buildElrcLyric(lines, includeTranslation: includeTranslation);
  if (elrc.isEmpty) return const {};
  var hasTranslation = false;
  for (final line in lines) {
    if (includeTranslation &&
        line.translation != null &&
        line.translation!.isNotEmpty) {
      hasTranslation = true;
      break;
    }
  }
  return {
    'songName': songName,
    'artist': artist,
    'songId': songId,
    'lyric': elrc,
    'format': 'elrc',
    if (hasTranslation) 'translation': 'lrc',
  };
}

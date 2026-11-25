/// LyricInfo 歌词 JSON 构造（纯函数，供单测）。
///
/// 支持两种输出模式：
/// - 默认（colorOsMode=false）：lidesheng LyricInfo 规范（HyperLyric 等消费方）——
///   `lyric` 为原文逐行 LRC，`rawLyric` 为原文增强（仅存在真实逐字时输出），
///   `translation`/`roma` 为互相独立的 lane，`album`/`songId` 仅在非空时写入；
///   不输出 `format`（增强信息由 `rawLyric` 的 `<>` 标签自描述）。
/// - ColorOS Bridge 模式（colorOsMode=true）：兼容
///   ColorOS-Live-Lyrics-Bridge（Andrea-lyz）开放协议——`lyric` 为纯 LRC 行级、
///   `rawLyric` 为 ELRC 逐字（含末尾结束标签）、`translationLyric` 独立 lane，
///   附 `lyricType`/`noLyric`/`provider`/`source`。
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

/// 构造罗马音 lane（规范 `roma`）：只输出罗马音/音译行，`[行时间]罗马音文本`。
/// 与 [buildPlainTranslationLrc] 互相独立，二者都不合并进 `lyric`/`rawLyric`。
String buildPlainRomaLrc(List<LyricLine> lines) {
  final buf = StringBuffer();
  for (final line in lines) {
    final r = line.roma;
    if (r != null && r.isNotEmpty) {
      buf
        ..write(lrcTagMs(line.startTime))
        ..write(r)
        ..write('\n');
    }
  }
  return buf.toString().trimRight();
}

/// 构造「原文增强 lane」（规范 `rawLyric`）。
///
/// 逐字行输出 `[行时间]<字时间>字<字时间>字...`；只有行级时间的行保持普通 LRC
/// 文本，**不伪造**词级标签（避免非逐字源被消费方误判为可扫光）。
/// 翻译与罗马音是独立 lane，不写入本 lane。
///
/// [includeTrailingEndTag] 为 true 时逐字行末追加 `<末字结束时间>` 标签
/// （ColorOS Bridge 4.0 逐字 lane 规则 4；lidesheng 规范无此要求，故默认 false）。
String buildRawLyricLane(
  List<LyricLine> lines, {
  bool includeTrailingEndTag = false,
}) {
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
      if (includeTrailingEndTag) {
        final last = line.words.last;
        if (last.duration > 0) {
          buf.write(elrcWordTag(last.startTime + last.duration));
        }
      }
    } else {
      buf.write(line.text);
    }
    buf.write('\n');
  }
  return buf.toString().trimRight();
}

/// ColorOS Bridge 4.0 的 rawLyric：在 [buildRawLyricLane] 基础上补逐字行末尾结束标签。
String buildColorOsRawLyric(List<LyricLine> lines) =>
    buildRawLyricLane(lines, includeTrailingEndTag: true);

String _identityText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$'), '')
    .replaceAll(RegExp(r'[\s\-—–_·•|/\\（）()\[\]【】]+'), '');

class _LyricLanes {
  final List<LyricLine> main;

  const _LyricLanes(this.main);
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

/// 把解析器可能产出的“同时间戳主行 + 翻译独立行”归一成主行与
/// [LyricLine.translation] / [LyricLine.roma]。歌词正文不做版权、来源或制作人员内容过滤。
///
/// 归一化恒保留翻译与罗马音数据；是否发布由 lane 构造处的
/// `includeTranslation` / `includeRoma` 决定（两模式共用同一归一化规则，
/// 保证原生侧 hasTranslation 能力位与实际 payload 一致）。
_LyricLanes _normalizeLyricLanes(List<LyricLine> lines) {
  final filtered = lines
      .where((line) => line.text.isNotEmpty)
      .toList(growable: false);
  if (filtered.isEmpty) return const _LyricLanes([]);

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
      normalized.addAll(group);
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
    String? translation = primary.translation;
    if (translation == null || translation.isEmpty) {
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
    normalized.add(primary.copyWith(translation: translation));
    start = end;
  }
  return _LyricLanes(normalized);
}

/// 当前推送配置下是否存在应发布的真实翻译（两种模式共用）。
///
/// 与 payload 使用同一归一化规则，保证按钮能力与实际翻译 lane 一致
/// （ColorOS 模式为 `translationLyric`，规范模式为 `translation`）。
bool hasPushableTranslation(
  List<LyricLine> lines, {
  required bool includeTranslation,
}) {
  if (!includeTranslation) return false;
  return _normalizeLyricLanes(lines)
      .main
      .any((line) => line.translation?.isNotEmpty ?? false);
}

/// 组装 lyricInfo JSON map（供 `MediaNotificationService.updateLyricInfo` jsonEncode）。
///
/// [colorOsMode]=false（默认）：lidesheng LyricInfo 规范——`lyric` 为原文逐行 LRC，
/// `rawLyric` 为原文增强（仅存在真实逐字时输出），`translation`/`roma` 为互相独立的
/// lane；可选字段仅在有效非空时写入；`songName`/`artist`/`lyric` 任一无效时返回空 map。
///
/// [colorOsMode]=true：ColorOS-Live-Lyrics-Bridge 4.0 开放协议——`lyric` 纯 LRC +
/// `rawLyric` 逐字（带末尾结束标签）+ `translationLyric`，附 `lyricType`/`noLyric`/
/// `provider`/`source`；[includeRoma] 在该模式下被忽略。
///
/// [includeTranslation] 对应设置页共用「翻译歌词」开关，[includeRoma] 对应「罗马音歌词」
/// 开关。返回空 map 表示无有效歌词（原生侧不做推送/保持移除状态）。
Map<String, dynamic> buildLyricInfoJson({
  required String songName,
  required String artist,
  required String songId,
  required List<LyricLine> lines,
  required bool includeTranslation,
  required bool colorOsMode,
  bool includeRoma = false,
  String? album,
  String? trackKey,
  int? sessionGeneration,
}) {
  if (colorOsMode) {
    final normalized = _normalizeLyricLanes(lines);
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
  // 规范模式：lyric=原文逐行 LRC，rawLyric=原文增强，translation/roma=独立 lane。
  final mainLines = _normalizeLyricLanes(lines).main;
  final trimmedSongName = songName.trim();
  final trimmedArtist = artist.trim();
  final lyric = buildPlainLrc(mainLines, includeTranslation: false);
  if (lyric.isEmpty || trimmedSongName.isEmpty || trimmedArtist.isEmpty) {
    return const {};
  }
  final rawLyric = mainLines.any((line) => line.hasWordTiming)
      ? buildRawLyricLane(mainLines)
      : '';
  final translationLrc =
      includeTranslation ? buildPlainTranslationLrc(mainLines) : '';
  final romaLrc = includeRoma ? buildPlainRomaLrc(mainLines) : '';
  final trimmedSongId = songId.trim();
  final trimmedAlbum = album?.trim() ?? '';
  return {
    'songName': trimmedSongName,
    'artist': trimmedArtist,
    'lyric': lyric,
    if (trimmedSongId.isNotEmpty) 'songId': trimmedSongId,
    if (trimmedAlbum.isNotEmpty) 'album': trimmedAlbum,
    if (rawLyric.isNotEmpty) 'rawLyric': rawLyric,
    if (translationLrc.isNotEmpty) 'translation': translationLrc,
    if (romaLrc.isNotEmpty) 'roma': romaLrc,
  };
}

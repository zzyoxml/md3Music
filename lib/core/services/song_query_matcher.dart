import 'dart:math' as math;

/// 语音点歌的「关键词 → 曲目」匹配打分（纯函数，便于单测）。
///
/// 目标：车机语音「播放周杰伦的稻香」这类 query 能稳定命中正版曲目，而不是搜索
/// 结果里的翻唱 / 串烧。策略是**标题优先、歌手次之、多词共现兜底**：
///
/// - 不做编辑距离 / 首字母模糊：相似度会把翻唱判成原唱，反而更糟；
/// - 标题完全一致 100 分、前缀 80、包含 60，形成"越像越靠前"的严格偏序；
/// - 歌手命中最高只到 40（避免"周杰伦"命中一堆别人的合唱曲压过标题命中）；
/// - 「周杰伦的稻香」按「的」拆词，两词都在标题+歌手组合里出现给 70 分。
class QueryCandidate {
  const QueryCandidate({
    required this.title,
    required this.artist,
    required this.index,
  });

  /// 搜索结果的曲名（酷狗 `songname` 字段）。
  final String title;

  /// 搜索结果的歌手串（多歌手时由上游用「、」拼接）。
  final String artist;

  /// 该候选在原始搜索结果里的下标，用于把打分结果映射回列表位置。
  final int index;
}

/// 归一化：小写、全角转半角、去括号内容、去空白与常见分隔符。
///
/// 去括号很关键——酷狗搜索结果里大量「稻香 (Live)」「稻香（伴奏）」这类版本标注，
/// 不剥掉会让「完全一致」永远命不中正版。
String normalizeForMatch(String input) {
  if (input.isEmpty) return '';
  final buffer = StringBuffer();
  for (final rune in input.toLowerCase().runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      // 全角 ASCII（！＂＃…～）→ 半角
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  var text = buffer.toString();
  // 去括号内容：() （） [] 【】 里通常是版本/来源标注。
  // 注意不处理《》——它常直接包住歌名本身（《稻香》），只把书名号当分隔符剥掉。
  text = text.replaceAll(
    RegExp(r'[\(\[【][^\)\]】]*[\)\]】]'),
    '',
  );
  const separators = <String>[
    ' ', '\t', '-', '_', '·', '.', ',', '，', '。', '!', '！', '?', '？',
    '、', '/', '\\', '|', '&', '+', '"', "'", '“', '”', '‘', '’', ':', '：',
    '~', '～', '*', '#', '@', '《', '》',
  ];
  for (final separator in separators) {
    if (text.contains(separator)) {
      text = text.replaceAll(separator, '');
    }
  }
  return text;
}

/// 按「的」与空白拆词后再归一化（语音 query 常见「歌手 + 的 + 歌名」）。
List<String> _tokensOf(String query) {
  final parts = query
      .toLowerCase()
      .replaceAll('的', ' ')
      .split(RegExp(r'[\s]+'));
  final tokens = <String>[];
  for (final part in parts) {
    final token = normalizeForMatch(part);
    if (token.isNotEmpty) tokens.add(token);
  }
  return tokens;
}

/// 翻唱 / 伴奏 / 铃声等"非原版"标记：命中即降权，避免语音点歌点到翻唱。
///
/// 只在**原始标题**上判定——[normalizeForMatch] 会把括号里的版本标注剥掉，
/// 剥之前必须先看一眼，否则「稻香 (Cover)」会与正版同分。
const List<String> _coverMarkers = <String>[
  '翻唱', 'cover', '伴奏', 'instrumental', '纯音乐', 'ktv', '铃声',
  'dj版', 'remix', '片段', '试听', '抖音',
];

/// 现场版降权（比翻唱轻：很多歌只有 Live 可播，不该完全压死）。
const List<String> _liveMarkers = <String>['live', '现场', '演唱会'];

int _versionPenalty(String rawTitle, String rawArtist) {
  final raw = '${rawTitle.toLowerCase()} ${rawArtist.toLowerCase()}';
  var penalty = 0;
  for (final marker in _coverMarkers) {
    if (raw.contains(marker)) {
      penalty += 25;
      break;
    }
  }
  for (final marker in _liveMarkers) {
    if (raw.contains(marker)) {
      penalty += 10;
      break;
    }
  }
  return penalty;
}

/// 单个候选的匹配分（0 表示不相关）。
int scoreCandidate(String query, QueryCandidate candidate) {
  final normalizedQuery = normalizeForMatch(query);
  if (normalizedQuery.isEmpty) return 0;
  final title = normalizeForMatch(candidate.title);
  final artist = normalizeForMatch(candidate.artist);

  var best = 0;
  if (title.isNotEmpty) {
    if (title == normalizedQuery) {
      best = 100;
    } else if (title.startsWith(normalizedQuery)) {
      best = 80;
    } else if (title.contains(normalizedQuery)) {
      best = 60;
    }
  }
  if (artist.isNotEmpty) {
    if (artist == normalizedQuery) {
      best = math.max(best, 40);
    } else if (artist.contains(normalizedQuery)) {
      best = math.max(best, 25);
    }
  }

  // 多词共现：「周杰伦的稻香」→ [周杰伦, 稻香]，两词都出现在标题+歌手里才算命中。
  final tokens = _tokensOf(query);
  if (tokens.length >= 2) {
    final haystack = '$title$artist';
    if (tokens.every(haystack.contains)) {
      best = math.max(best, 70);
    }
  }
  if (best == 0) return 0;
  return math.max(0, best - _versionPenalty(candidate.title, candidate.artist));
}

/// 取综合分最高的候选下标；全部为 0 分时返回 null（调用方据此提示"没找到"）。
///
/// 同分时保留搜索结果原序（严格大于才替换），与酷狗自身的相关度排序保持一致。
int? pickBestIndex(String query, List<QueryCandidate> candidates) {
  var bestScore = 0;
  int? bestIndex;
  for (final candidate in candidates) {
    final score = scoreCandidate(query, candidate);
    if (score > bestScore) {
      bestScore = score;
      bestIndex = candidate.index;
    }
  }
  return bestIndex;
}

import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../data/repositories/local_music_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/song_match_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

/// 封面组件用：解析本地歌曲自己的匹配记录（含单曲偏好位与在线封面 URL）。
///
/// listen:true 订阅匹配状态——自动匹配每确认一首、偏好开关切换都会 notify，
/// 封面组件随之重建。无 Provider 环境（部分测试）静默返回 null，保持原行为。
SongMatchInfo? matchedInfoForLocal(BuildContext context, String localId) {
  try {
    final provider = Provider.of<SongMatchProvider>(context, listen: true);
    return provider.matchedInfo(localId);
  } on ProviderNotFoundException {
    return null;
  }
}

/// 本地歌曲 ↔ 在线歌曲匹配的状态入口。
///
/// 包装 [SongMatchRepository] 提供 UI 可订阅的匹配状态，并内置自动匹配引擎：
/// 扫描完成 / 启动后对未匹配的本地歌曲逐首搜索，高置信度（标题+歌手+时长）
/// 才自动确认；其余记录尝试时间进入冷却，等待手动匹配。
class SongMatchProvider extends ChangeNotifier {
  SongMatchProvider({bool autoStartOnCreate = true}) {
    instance = this;
    // 尽早预热匹配记忆（评论解析/歌词 hash/封面兜底都走同步查询）
    unawaited(_repository.ensureLoaded());
    if (autoStartOnCreate) {
      // 错开启动高峰：等曲库恢复、首页渲染完再开始逐首搜索
      Future.delayed(const Duration(seconds: 5), () {
        if (instance == this && !_disposed) runAutoMatch();
      });
    }
  }

  /// 跨 provider 触发入口：LibraryProvider 扫描完成后调用
  /// [onLibraryUpdated]，无需经 context。
  static SongMatchProvider? instance;

  final SongMatchRepository _repository = SongMatchRepository();
  final SettingsRepository _settings = SettingsRepository();

  /// 测试注入：替换搜索引擎（弹层搜索与自动匹配共用）。
  @visibleForTesting
  static Future<KugouSearchResult?> Function(String keywords)?
      debugSearchOverride;

  bool _disposed = false;
  bool _autoMatching = false;
  bool _cancelRequested = false;
  int _autoMatchTotal = 0;
  int _autoMatchDone = 0;

  bool get autoMatching => _autoMatching;
  int get autoMatchTotal => _autoMatchTotal;
  int get autoMatchDone => _autoMatchDone;

  /// 确保仓库内存缓存就绪（同步查询入口前的兜底；通常构造后即完成）。
  Future<void> ensureReady() => _repository.ensureLoaded();

  /// 本地歌曲对应的在线歌曲（未匹配/在线歌曲返回 null）。同步查内存。
  Song? matchedSongFor(Song song) {
    if (song.isOnline) return null;
    return matchedSongForId(song.id);
  }

  /// 按本地歌曲 id 查询（本地歌曲 id = `local_<路径>`）。
  Song? matchedSongForId(String localId) {
    final info = _repository.get(localId);
    if (info == null || !info.isMatched) return null;
    return info.toSong();
  }

  /// 同步判断是否已有有效匹配。
  bool isMatched(String localId) => _repository.isMatched(localId);

  /// 同步读取某首歌的完整匹配记录（含单曲偏好位；需先 ensureLoaded）。
  SongMatchInfo? matchedInfo(String localId) => _repository.get(localId);

  /// 单曲偏好：这首歌词用在线结果覆盖内嵌/本地歌词（未匹配时 no-op）。
  Future<void> setUseOnlineLyrics(Song local, bool value) async {
    final info = _repository.get(local.id);
    if (info == null || !info.isMatched || info.preferOnlineLyrics == value) {
      return;
    }
    await _repository.put(info.copyWith(preferOnlineLyrics: value));
    if (!_disposed) notifyListeners();
  }

  /// 单曲偏好：这首歌封面用在线结果覆盖内嵌封面（未匹配时 no-op）。
  Future<void> setUseOnlineCover(Song local, bool value) async {
    final info = _repository.get(local.id);
    if (info == null || !info.isMatched || info.preferOnlineCover == value) {
      return;
    }
    await _repository.put(info.copyWith(preferOnlineCover: value));
    if (!_disposed) notifyListeners();
  }

  /// 手动确认匹配：覆盖已有自动匹配，并复活被否决的记录。
  Future<void> setManualMatch(Song local, KugouSongDetail candidate) async {
    await _repository.put(
      infoFromCandidate(local.id, candidate, SongMatchSource.manual),
    );
    if (!_disposed) notifyListeners();
  }

  /// 用户主动取消匹配：记录否决标记，自动匹配不再触碰（手动改选可复活）。
  Future<void> dismissMatch(Song local) async {
    await _repository.dismiss(local.id);
    if (!_disposed) notifyListeners();
  }

  /// 弹层候选搜索（与自动匹配共用注入点，便于测试）。
  Future<List<KugouSongDetail>> searchCandidates(
    String keywords, {
    int pagesize = 30,
  }) async {
    if (keywords.trim().isEmpty) return const [];
    final override = debugSearchOverride;
    if (override != null) {
      final result = await override(keywords);
      return result?.songs ?? const [];
    }
    final result = await KugouApiClient()
        .search(keywords.trim(), pagesize: pagesize, type: 'song');
    return result?.songs ?? const [];
  }

  /// 曲库变化（扫描完成/恢复）后触发自动匹配。引擎已运行时忽略。
  Future<void> onLibraryUpdated(List<Song> songs) async {
    if (_autoMatching) return;
    await runAutoMatch(songs: songs);
  }

  /// 全库自动匹配入口（启动延迟触发 / 扫描完成 / 设置页「立即匹配」）。
  ///
  /// [force] 为 true 时忽略设置开关与 7 天冷却（设置页手动触发用）。
  Future<void> runAutoMatch({List<Song>? songs, bool force = false}) async {
    if (_autoMatching) return;
    if (!force) {
      final enabled = await _settings.getAutoMatchOnlineInfo();
      if (!enabled) return;
    }
    await _repository.ensureLoaded();
    final all = songs ??
        await LocalMusicRepository()
            .getSavedSongs(); // 未传时读已持久化的扫描结果
    final now = DateTime.now().millisecondsSinceEpoch;
    final cooldownMs = SongMatchRepository.attemptCooldown.inMilliseconds;
    final pending = <Song>[];
    for (final song in all) {
      if (song.isOnline || song.localPath == null) continue;
      final info = _repository.get(song.id);
      if (info != null && info.isMatched) continue;
      if (info != null && info.dismissed) continue;
      if (!force &&
          info != null &&
          info.attemptedAt > 0 &&
          now - info.attemptedAt < cooldownMs) {
        continue;
      }
      pending.add(song);
    }
    if (pending.isEmpty) return;

    _autoMatching = true;
    _cancelRequested = false;
    _autoMatchTotal = pending.length;
    _autoMatchDone = 0;
    if (!_disposed) notifyListeners();

    for (var i = 0; i < pending.length; i++) {
      if (_cancelRequested || _disposed) break;
      try {
        await _autoMatchOne(pending[i]);
      } catch (_) {
        // 单首失败不中断整轮；留待下轮冷却后重试
        try {
          await _repository.markAttempted(pending[i].id);
        } catch (_) {}
      }
      _autoMatchDone = i + 1;
      if (!_disposed) notifyListeners();
      if (!_cancelRequested && i < pending.length - 1) {
        // 限速：逐首间隔，避免连续请求挤占在线体验
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    _autoMatching = false;
    if (!_disposed) notifyListeners();
  }

  /// 设置页/用户主动终止本轮自动匹配。
  void cancelAutoMatch() {
    _cancelRequested = true;
  }

  /// 外部直接改写仓库后（如设置页「清除全部匹配记录」）刷新订阅者。
  void notifyChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _autoMatchOne(Song song) async {
    final keyword = buildSearchKeyword(song);
    if (keyword.isEmpty) {
      await _repository.markAttempted(song.id);
      return;
    }
    final candidates = await searchCandidates(keyword, pagesize: 10);
    final best = pickBestCandidate(song, candidates);
    if (best == null) {
      await _repository.markAttempted(song.id);
    } else {
      // pickBestCandidate 已把候选封装成 SongMatchInfo（source=auto）
      await _repository.put(best);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (instance == this) instance = null;
    super.dispose();
  }

  // ── 匹配评分 ──────────────────────────────────────────────

  /// 由本地歌曲构造在线搜索关键词：`歌名 歌手`（歌手未知时只用歌名）。
  static String buildSearchKeyword(Song song) {
    final title = song.displayName.trim();
    if (title.isEmpty) return '';
    final artistKnown = !isUnknownArtist(song.artist);
    final artist = artistKnown ? song.artist.trim() : '';
    return '$title $artist'.trim();
  }

  /// 从候选中挑出可自动确认的最佳匹配；不满足高置信度门槛时返回 null。
  ///
  /// 硬门槛：标题相似度 ≥0.85、歌手可对应（本地歌手未知时放行）、
  /// 双方时长都已知且相差 ≤2 秒（过滤 remix/live/翻唱误配）。
  static SongMatchInfo? pickBestCandidate(
    Song local,
    List<KugouSongDetail> candidates,
  ) {
    final normTitle = normalizeForMatch(local.displayName);
    if (normTitle.isEmpty) return null;
    final artistUnknown = isUnknownArtist(local.artist);
    final normArtist = artistUnknown ? '' : normalizeForMatch(local.artist);
    final localDurMs = local.duration.inMilliseconds;

    KugouSongDetail? best;
    var bestScore = 0.0;
    for (final c in candidates) {
      if (c.hash.isEmpty) continue;
      final cTitle = normalizeForMatch(c.songName);
      if (cTitle.isEmpty) continue;
      final titleSim = bigramSimilarity(normTitle, cTitle);
      if (titleSim < 0.85) continue;

      final cArtist = normalizeForMatch(c.artistName ?? '');
      final artistOk = artistUnknown ||
          cArtist.isEmpty ||
          cArtist == normArtist ||
          cArtist.contains(normArtist) ||
          normArtist.contains(cArtist);
      if (!artistOk) continue;

      final cDurMs = c.duration > 0 ? c.duration * 1000 : 0;
      if (cDurMs == 0 || localDurMs == 0) continue;
      final diff = (cDurMs - localDurMs).abs();
      if (diff > 2000) continue;

      final durSim = 1 - (diff / 2000.0).clamp(0.0, 1.0);
      final artistSim = artistUnknown ? 0.5 : (cArtist.isEmpty ? 0.4 : 1.0);
      final score = titleSim * 0.6 + artistSim * 0.25 + durSim * 0.15;
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best == null
        ? null
        : infoFromCandidate(local.id, best, SongMatchSource.auto);
  }

  /// 由在线候选构造匹配记录（标题/歌手/专辑存候选侧原值，供在线能力使用；
  /// 本地列表的展示文案不受影响）。
  static SongMatchInfo infoFromCandidate(
    String localId,
    KugouSongDetail candidate,
    SongMatchSource source,
  ) {
    return SongMatchInfo(
      localId: localId,
      hash: candidate.hash,
      albumAudioId: candidate.albumAudioId,
      songId: candidate.songId,
      title: candidate.songName,
      artist: candidate.artistName,
      album: candidate.albumName,
      albumId: candidate.albumId,
      artistId: candidate.artistId,
      artworkUri: candidate.artworkUri,
      durationMs: candidate.duration > 0 ? candidate.duration * 1000 : 0,
      source: source,
      matchedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 匹配规范化：小写 + 去空白/标点/符号（中英文括号引号等），用于相似度比较。
  static String normalizeForMatch(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      if (_noiseChar.hasMatch(ch)) continue;
      buffer.write(ch);
    }
    return buffer.toString();
  }

  static final RegExp _noiseChar = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

  /// 双字组 Dice 相似度（0~1），对中文与英文歌名都适用。
  static double bigramSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
    final grams = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final g = a.substring(i, i + 2);
      grams[g] = (grams[g] ?? 0) + 1;
    }
    var hits = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final g = b.substring(i, i + 2);
      final count = grams[g];
      if (count != null && count > 0) {
        hits++;
        grams[g] = count - 1;
      }
    }
    return 2 * hits / (a.length - 1 + b.length - 1);
  }
}

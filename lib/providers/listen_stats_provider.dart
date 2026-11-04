import 'package:flutter/foundation.dart';

import '../data/models/song.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

/// 云端听歌统计的跨页状态源。
///
/// **数据源 = `/user/history`（云端播放历史），排行由历史条目聚合派生**。
///
/// 为什么不用 listenservice 榜单（`/user/listen`）：2026-10-11 实机核对确认
/// 它不消费 `/playhistory/upload` 的上传 —— 周榜恒空、全量榜快照停在
/// `data_date: 2024xxxx` 且 `listen_count` 全为 1。而同一账号的
/// `/user/history` 有 100+ 条带完整歌曲信息（`songs[].info{}`）、`pc`
/// 累计次数与 `ot` 播放时间的真实记录（含官方 App 的收听），故排行/统计
/// 统一由历史派生：口径与「听歌记录云端统一」写入路径完全一致，
/// 且天然跨设备（官方端写入的记录同样计入）。
///
/// 供三处共用：播放历史页「云端历史」Tab、听歌排行页、听歌统计页。
/// 与 KugouProvider 联动（app.dart 的 ChangeNotifierProxyProvider）：
/// 登录态/账号变化时清空缓存，防止跨账号串状态。
class ListenStatsProvider extends ChangeNotifier {
  /// 排行/统计聚合最多翻取的历史页数（每页 100 条，3 页 = 300 首）。
  ///
  /// 越深越全但越慢；300 首对个人排行/歌手聚合已足够（官方账号常见
  /// 历史总条数在几百量级），且单页响应含完整歌曲信息、体积不小。
  static const int rankingMaxHistoryPages = 3;

  /// 最近一周窗口（秒）。
  static const int recentWeekSeconds = 7 * 24 * 3600;

  final KugouApiClient _apiClient = KugouApiClient();

  final Map<int, _RankingBucket> _rankings = {
    0: _RankingBucket(),
    1: _RankingBucket(),
  };

  /// 已成功翻取的历史页数（排行深度控制用）。
  int _historyPagesFetched = 0;

  List<KugouHistoryEntry> _historyEntries = [];
  String? _historyNextBp;
  bool _historyLoading = false;
  bool _historyLoaded = false;
  Object? _historyError;
  Future<void>? _historyInFlight;

  // 登录态跟踪：isLoggedIn 或 userid 翻转（登录/登出/换号）即清空缓存。
  bool _lastLoggedIn = false;
  String? _lastUserid;

  /// 由 app.dart 在 KugouProvider 通知时同步（非公开 API，UI 不直接调用）。
  void syncLoginState({required bool loggedIn, String? userid}) {
    if (_lastLoggedIn == loggedIn && _lastUserid == userid) return;
    _lastLoggedIn = loggedIn;
    _lastUserid = userid;
    reset();
  }

  // ---- 排行（由云端播放历史聚合派生）----

  List<KugouRankedSong> rankingSongs(int type) =>
      List.unmodifiable(_bucketOf(type).songs);

  bool isLoadingRanking(int type) => _bucketOf(type).loading;

  bool isRankingLoaded(int type) => _bucketOf(type).loaded;

  Object? rankingError(int type) => _bucketOf(type).error;

  /// 拉取排行：先确保历史翻到足够深度（最多 [rankingMaxHistoryPages] 页），
  /// 再由历史条目聚合出两份排行（0=最近一周，1=全部累计）。
  ///
  /// [force] true 时强制重拉历史（进页刷新）；false 时复用已有页。
  Future<void> loadRanking(int type, {bool force = false}) async {
    // 两份排行同源，正在拉取时共享同一 Future（防并发重复请求）
    final existing = _bucketOf(type).inFlight ?? _bucketOf(1 - type).inFlight;
    if (existing != null) return existing;
    if (!force && isRankingLoaded(type) && isRankingLoaded(1 - type)) {
      return Future.value();
    }
    final future = _doFetchRankings(force: force);
    _bucketOf(type).inFlight = future;
    _bucketOf(1 - type).inFlight = future;
    return future;
  }

  Future<void> _doFetchRankings({required bool force}) async {
    for (final b in _rankings.values) {
      b.loading = true;
      b.error = null;
    }
    notifyListeners();
    try {
      await _ensureHistoryPages(force: force);
      if (_historyError != null) {
        for (final b in _rankings.values) {
          b.error = _historyError;
        }
      } else {
        _rebuildRankings();
        for (final b in _rankings.values) {
          b.loaded = true;
        }
      }
    } catch (e) {
      for (final b in _rankings.values) {
        b.error = e;
      }
    } finally {
      for (final b in _rankings.values) {
        b.loading = false;
        b.inFlight = null;
      }
      notifyListeners();
    }
  }

  /// 翻取历史页直到满足排行深度（或没有更多页/拉取出错）。
  Future<void> _ensureHistoryPages({required bool force}) async {
    if (force) {
      await _doFetchHistory(force: true);
      // force 重拉只取第一页：此后按需继续翻页
    } else if (!_historyLoaded) {
      await _doFetchHistory(force: false);
    }
    while (_historyError == null &&
        _historyNextBp != null &&
        _historyNextBp!.isNotEmpty &&
        _historyPagesFetched < rankingMaxHistoryPages) {
      await _doFetchHistory(force: false);
    }
  }

  /// 由历史条目聚合出排行（按曲聚合：同曲取 pc 最大值与最新 ot）。
  ///
  /// - 全部累计（type 1）：按累计次数（pc）降序；
  /// - 最近一周（type 0）：仅保留 ot 在 7 天窗口内的曲目，同样按 pc 降序。
  void _rebuildRankings() {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final byId = <String, ({KugouHistoryEntry entry, int pc, int ot})>{};
    for (final e in _historyEntries) {
      final id = e.song.id;
      if (id.isEmpty) continue;
      final prev = byId[id];
      // pc = 该曲累计播放次数（服务端保持 max），缺失按 1 次计
      final pc = e.playCount > 0 ? e.playCount : 1;
      final ot = e.timestampSec;
      if (prev == null) {
        byId[id] = (entry: e, pc: pc, ot: ot);
      } else {
        // 同曲合并：pc 取最大（服务端保持 max），ot 取最新
        byId[id] = (
          entry: ot >= prev.ot ? e : prev.entry,
          pc: pc > prev.pc ? pc : prev.pc,
          ot: ot > prev.ot ? ot : prev.ot,
        );
      }
    }
    final all = byId.values.toList()
      ..sort((a, b) {
        final byPc = b.pc.compareTo(a.pc);
        return byPc != 0 ? byPc : b.ot.compareTo(a.ot);
      });
    _bucketOf(1).songs
      ..clear()
      ..addAll(
        all.map(
          (r) => KugouRankedSong(song: r.entry.song, playCount: r.pc),
        ),
      );
    final weekCutoff = nowSec - recentWeekSeconds;
    _bucketOf(0).songs
      ..clear()
      ..addAll(
        all
            .where((r) => r.ot >= weekCutoff)
            .map(
              (r) => KugouRankedSong(song: r.entry.song, playCount: r.pc),
            ),
      );
  }

  _RankingBucket _bucketOf(int type) => _rankings[type == 1 ? 1 : 0]!;

  // ---- 最近听歌历史（/user/history，bp 翻页）----

  List<KugouHistoryEntry> get historyEntries =>
      List.unmodifiable(_historyEntries);

  bool get historyLoading => _historyLoading;

  bool get historyLoaded => _historyLoaded;

  Object? get historyError => _historyError;

  bool get historyHasMore =>
      _historyLoaded && _historyNextBp != null && _historyNextBp!.isNotEmpty;

  /// 拉取第一页（已加载过且非强制时复用缓存）。
  Future<void> loadHistory({bool force = false}) {
    if (!force) {
      if (_historyLoaded) return Future.value();
      final f = _historyInFlight;
      if (f != null) return f;
    }
    if (_historyInFlight != null) return _historyInFlight!;
    final future = _doFetchHistory(force: force);
    _historyInFlight = future;
    return future;
  }

  /// 加载下一页（bp 游标翻页；无游标时为空操作）。
  Future<void> loadMoreHistory() {
    if (_historyLoading || !_historyLoaded || !historyHasMore) {
      return Future.value();
    }
    if (_historyInFlight != null) return _historyInFlight!;
    final future = _doFetchHistory(force: false);
    _historyInFlight = future;
    return future;
  }

  Future<void> _doFetchHistory({required bool force}) async {
    _historyLoading = true;
    _historyError = null;
    notifyListeners();
    try {
      final bp = force ? null : _historyNextBp;
      final resp = await _apiClient.getUserHistory(bp: bp);
      final snapshot =
          resp == null ? null : KugouHistorySnapshot.fromJson(resp);
      if (snapshot == null || !snapshot.ok) {
        _historyError = Exception(snapshot == null ? '历史请求失败' : '历史业务失败');
        if (force) {
          _historyEntries.clear();
          _historyNextBp = null;
          _historyPagesFetched = 0;
        }
      } else {
        if (force) {
          _historyEntries.clear();
          _historyPagesFetched = 0;
        }
        _historyEntries.addAll(snapshot.entries);
        // 云端返回顺序**不保证按时间**（2026-10-11 实机核对：100 条里 ot
        // 逆序 15 次、当天记录散落在各处；官方 App 也是客户端自行排序）。
        // 客户端统一按播放时间降序排列，保证「最近播放」视图符合直觉。
        _sortHistoryByTimeDesc();
        _historyPagesFetched += 1;
        _historyNextBp = snapshot.nextBp;
        _historyLoaded = true;
        // 上游没给游标或本页为空都视为无更多页
        if (snapshot.entries.isEmpty) _historyNextBp = null;
      }
    } catch (e) {
      _historyError = e;
    } finally {
      _historyLoading = false;
      _historyInFlight = null;
      notifyListeners();
    }
  }

  /// 按播放时间（ot）降序稳定排序；无时间戳（0）沉底。
  /// 服务端顺序不可依赖（见 [_doFetchHistory] 注释），客户端统一排序。
  void _sortHistoryByTimeDesc() {
    if (_historyEntries.length < 2) return;
    // Dart List.sort 不稳定：带原始下标做 tiebreak，同时间戳保持页内原序
    final decorated = <(int, KugouHistoryEntry)>[
      for (var i = 0; i < _historyEntries.length; i++)
        (i, _historyEntries[i]),
    ];
    decorated.sort((a, b) {
      final byTime = b.$2.timestampSec.compareTo(a.$2.timestampSec);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    _historyEntries
      ..clear()
      ..addAll(decorated.map((e) => e.$2));
  }

  /// 统计页聚合（全云端，一条计算路径）。数据不足时各维度返回空结构。
  ListenStatsAggregate aggregate() => computeListenStats(
        weekSongs: rankingSongs(0),
        allTimeSongs: rankingSongs(1),
        historyEntries: _historyEntries,
      );

  /// 清空全部缓存（登录/登出/换号时由 syncLoginState 触发）。
  void reset() {
    for (final b in _rankings.values) {
      b.clear();
    }
    _historyEntries = [];
    _historyNextBp = null;
    _historyPagesFetched = 0;
    _historyLoading = false;
    _historyLoaded = false;
    _historyError = null;
    _historyInFlight = null;
    notifyListeners();
  }
}

class _RankingBucket {
  final List<KugouRankedSong> songs = [];
  bool loading = false;
  bool loaded = false;
  Object? error;
  Future<void>? inFlight;

  void clear() {
    songs.clear();
    loading = false;
    loaded = false;
    error = null;
    inFlight = null;
  }
}

// ==================== 统计页聚合（纯函数，可单测） ====================

/// 统计页的总览聚合结果。全云端口径：
/// - 总览卡：排行 TOP120 的播放次数合计（上游只回前 120，卡片副标题注明口径）；
/// - 7 天柱状图 / 时段偏好：最近历史条目的播放时间聚合（响应无时间戳时
///   [historyTimeAvailable] 为 false，UI 降级隐藏）；
/// - 歌手/歌曲/专辑 TOP：全部累计排行（type 1）聚合。
class ListenStatsAggregate {
  /// 本周（最近一周 TOP120）：总播放次数 / 歌曲数。
  final int weekTotalPlays;
  final int weekSongCount;

  /// 全部累计（TOP120）：总播放次数 / 歌曲数。
  final int totalPlays;
  final int totalSongCount;

  /// 常听歌手 TOP（全部累计聚合，按次数降序，最多 6）。
  final List<ListenStatsArtist> topArtists;

  /// 高频歌曲 TOP（全部累计前 6，已按次数降序）。
  final List<KugouRankedSong> topSongs;

  /// 最常回访专辑（全部累计聚合第一名；无可解析专辑时 null）。
  final ListenStatsAlbum? topAlbum;

  /// 最近 7 天（含今天，旧→新）每天播放条数（来自最近历史的时间聚合）。
  final List<ListenStatsDay> last7Days;

  /// 时段偏好 4 桶播放条数（凌晨 0-6 / 上午 6-12 / 下午 12-18 / 夜晚 18-24）。
  final List<int> timeBuckets;

  /// 最近历史是否携带可用时间戳（false 时柱状图/时段降级隐藏）。
  final bool historyTimeAvailable;

  /// 参与时间聚合的历史条数（UI 标注口径「基于最近 N 条」）。
  final int historySampleCount;

  const ListenStatsAggregate({
    this.weekTotalPlays = 0,
    this.weekSongCount = 0,
    this.totalPlays = 0,
    this.totalSongCount = 0,
    this.topArtists = const [],
    this.topSongs = const [],
    this.topAlbum,
    this.last7Days = const [],
    this.timeBuckets = const [],
    this.historyTimeAvailable = false,
    this.historySampleCount = 0,
  });
}

/// 聚合后的歌手条目（同名合并；[plays] 为次数加权，[songCount] 为去重歌曲数）。
class ListenStatsArtist {
  final String name;
  final int plays;
  final int songCount;

  /// 该歌手名下第一首能解析出歌手 id 的歌曲的 id（跳歌手页用，可空）。
  final String? artistId;

  const ListenStatsArtist({
    required this.name,
    required this.plays,
    required this.songCount,
    this.artistId,
  });
}

/// 聚合后的专辑条目。
class ListenStatsAlbum {
  final String name;
  final int plays;
  final int songCount;

  const ListenStatsAlbum({
    required this.name,
    required this.plays,
    required this.songCount,
  });
}

/// 7 天柱状图的单日数据。
class ListenStatsDay {
  final DateTime day;

  /// 当天最近历史条数（口径=历史记录条数，非精确播放次数）。
  final int plays;

  const ListenStatsDay({required this.day, required this.plays});
}

/// 聚合入口：排行两份 + 最近历史 → [ListenStatsAggregate]。纯函数无副作用。
ListenStatsAggregate computeListenStats({
  required List<KugouRankedSong> weekSongs,
  required List<KugouRankedSong> allTimeSongs,
  required List<KugouHistoryEntry> historyEntries,
}) {
  int sumPlays(List<KugouRankedSong> songs) {
    var total = 0;
    for (final s in songs) {
      total += s.playCount ?? 0;
    }
    return total;
  }

  // 歌手聚合：多位歌手连写按分隔符拆开分别计（与播放页跳歌手同一套拆分规则）
  final artistPlays = <String, int>{};
  final artistSongs = <String, Set<String>>{};
  final artistIds = <String, String>{};
  final albumPlays = <String, int>{};
  final albumSongs = <String, Set<String>>{};
  for (final ranked in allTimeSongs) {
    final song = ranked.song;
    final weight = ranked.playCount ?? 1;
    for (final name in splitSongArtistNames(song.artist)) {
      artistPlays[name] = (artistPlays[name] ?? 0) + weight;
      (artistSongs[name] ??= {}).add(song.id);
      final aid = song.artistId;
      if (aid != null && aid.isNotEmpty && !artistIds.containsKey(name)) {
        artistIds[name] = aid;
      }
    }
    final album = song.album.trim();
    if (album.isNotEmpty) {
      albumPlays[album] = (albumPlays[album] ?? 0) + weight;
      (albumSongs[album] ??= {}).add(song.id);
    }
  }
  final topArtists = artistPlays.entries
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final artists = topArtists
      .take(6)
      .map(
        (e) => ListenStatsArtist(
          name: e.key,
          plays: e.value,
          songCount: artistSongs[e.key]?.length ?? 0,
          artistId: artistIds[e.key],
        ),
      )
      .toList();

  ListenStatsAlbum? topAlbum;
  if (albumPlays.isNotEmpty) {
    final entries = albumPlays.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final first = entries.first;
    topAlbum = ListenStatsAlbum(
      name: first.key,
      plays: first.value,
      songCount: albumSongs[first.key]?.length ?? 0,
    );
  }

  // 高频歌曲：上游本就按次数降序，这里兜底再排一次（null 沉底）
  final topSongs = allTimeSongs.toList()
    ..sort((a, b) => (b.playCount ?? -1).compareTo(a.playCount ?? -1));

  // 时间维度：来自最近历史的时间戳（今天 0 点为锚，往回 7 天）
  final today = DateTime.now();
  final todayStart = DateTime(today.year, today.month, today.day);
  final days = List<ListenStatsDay>.generate(
    7,
    (i) => ListenStatsDay(
      day: todayStart.subtract(Duration(days: 6 - i)),
      plays: 0,
    ),
  );
  // 时段 4 桶：凌晨 0-6 / 上午 6-12 / 下午 12-18 / 夜晚 18-24
  final buckets = List<int>.filled(4, 0);
  var timedCount = 0;
  for (final entry in historyEntries) {
    final ts = entry.timestampSec;
    if (ts <= 0) continue;
    timedCount++;
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final dayStart = DateTime(dt.year, dt.month, dt.day);
    final diff = todayStart.difference(dayStart).inDays;
    if (diff >= 0 && diff < 7) {
      days[6 - diff] = ListenStatsDay(day: days[6 - diff].day, plays: days[6 - diff].plays + 1);
    }
    buckets[dt.hour ~/ 6] += 1;
  }

  return ListenStatsAggregate(
    weekTotalPlays: sumPlays(weekSongs),
    weekSongCount: weekSongs.length,
    totalPlays: sumPlays(allTimeSongs),
    totalSongCount: allTimeSongs.length,
    topArtists: artists,
    topSongs: topSongs.take(6).toList(),
    topAlbum: topAlbum,
    last7Days: days,
    timeBuckets: buckets,
    historyTimeAvailable: timedCount > 0,
    historySampleCount: timedCount,
  );
}

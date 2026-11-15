import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db/listen_stats_db.dart';

/// 本地听歌统计的时间范围（滚动窗口，以"现在"为终点往回推）。
enum LocalListenStatsRange {
  /// 最近 7 天
  week,

  /// 最近 30 天
  month,

  /// 最近 365 天
  year,

  /// 全部
  all,
}

/// 本地听歌统计的跨页状态源（与云端 `ListenStatsProvider` 分工：
/// 这里只消费本地库 [ListenStatsDb]，不依赖登录态/网络，本地歌同样计入）。
///
/// 缓存策略：按 [LocalListenStatsRange] 各存一份结果，每份带**版本号
/// （= countByUser(validOnly: false) 的记录总数快照）**——版本一致直接
/// 命中缓存不重查，有新播放入库后版本变化才重新聚合。
///
/// 跨账号：由 app.dart 的 `ChangeNotifierProxyProvider<KugouProvider, ...>`
/// 在登录态/账号变化时调 [syncLoginState] 清空缓存，防止跨账号串状态
/// （与云端 ListenStatsProvider 同一套接线）。
class LocalListenStatsProvider extends ChangeNotifier {
  LocalListenStatsProvider({ListenStatsDb? db}) : _dbOverride = db;

  /// 测试注入的库；null 时使用默认路径库（应用支持目录/listen_stats.db）。
  final ListenStatsDb? _dbOverride;

  /// 默认库：进程内共享一个实例即可（只读查询，无写入方），
  /// [ListenStatsDb] 懒开库，构造无 IO。
  static final ListenStatsDb _defaultDb = ListenStatsDb();

  ListenStatsDb get _db => _dbOverride ?? _defaultDb;

  /// Top 榜每维条数（UI 一屏展示量级，后续页面接入可再调）。
  static const int _topLimit = 10;

  LocalListenStatsRange _selectedRange = LocalListenStatsRange.month;
  final Map<LocalListenStatsRange, _LocalRangeCache> _caches = {};
  bool _isLoading = false;
  Future<void>? _inFlight;

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

  // ---- 只读状态 ----

  LocalListenStatsRange get selectedRange => _selectedRange;

  bool get isLoading => _isLoading;

  /// 当前范围的曲目 Top（未加载时为空列表）。
  List<LocalTopEntry> get topTracks => _topOf((c) => c.topTracks);

  /// 当前范围的艺人 Top（NULL/空艺人已归"未知艺人"桶）。
  List<LocalTopEntry> get topArtists => _topOf((c) => c.topArtists);

  /// 当前范围的专辑 Top（NULL/空专辑已归"未知专辑"桶）。
  List<LocalTopEntry> get topAlbums => _topOf((c) => c.topAlbums);

  /// 当前范围的总览数值（未加载时全 0）。
  LocalOverview get overview =>
      _caches[_selectedRange]?.overview ?? const LocalOverview();

  /// 当前范围的逐月趋势（month = yyyyMM，升序）。
  List<LocalMonthPoint> get monthlyTrends =>
      _caches[_selectedRange]?.monthlyTrends ?? const <LocalMonthPoint>[];

  List<LocalTopEntry> _topOf(
    List<LocalTopEntry> Function(_LocalRangeCache) pick,
  ) {
    final cache = _caches[_selectedRange];
    return cache == null ? const <LocalTopEntry>[] : List.unmodifiable(pick(cache));
  }

  // ---- 加载 ----

  /// 加载当前范围的统计（缓存版本一致时复用，不重查库）。
  ///
  /// [force] true 时跳过版本比对强制重聚合（进页刷新用）。
  /// 请求串行化：前一次加载未完成时排队接续，避免乱序覆盖。
  Future<void> load({bool force = false}) {
    final prev = _inFlight ?? Future<void>.value();
    final completer = Completer<void>();
    _inFlight = completer.future;
    prev.whenComplete(() async {
      try {
        await _doLoad(force: force);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _doLoad({required bool force}) async {
    final range = _selectedRange;
    // 版本号 = 全量记录数快照：有新播放入库（valid 与否都算）即视为过期
    final version = await _db.countByUser(validOnly: false);
    final cache = _caches[range];
    if (!force && cache != null && cache.version == version) return;
    _isLoading = true;
    notifyListeners();
    try {
      final startMs = _startMsOf(range);
      final tracks = await _db.topTracks(startMs: startMs, limit: _topLimit);
      final artists = await _db.topArtists(startMs: startMs, limit: _topLimit);
      final albums = await _db.topAlbums(startMs: startMs, limit: _topLimit);
      final ov = await _db.overview(startMs: startMs);
      final monthly = await _db.monthlyTrends(startMs: startMs);
      _caches[range] = _LocalRangeCache(
        version: version,
        topTracks: [for (final m in tracks) LocalTopEntry.fromDb(m)],
        topArtists: [for (final m in artists) LocalTopEntry.fromDb(m)],
        topAlbums: [for (final m in albums) LocalTopEntry.fromDb(m)],
        overview: LocalOverview(
          plays: ov.plays,
          playedMs: ov.playedMs,
          activeDays: ov.activeDays,
          distinctTracks: ov.distinctTracks,
          distinctArtists: ov.distinctArtists,
        ),
        monthlyTrends: [
          for (final p in monthly)
            LocalMonthPoint(
              month: p.month,
              count: p.count,
              playedMs: p.playedMs,
            ),
        ],
      );
    } catch (e) {
      // 统计属锦上添花：失败只记日志，不向 fire-and-forget 调用方抛异步异常
      debugPrint('[LocalListenStats] 统计加载失败 range=$range err=$e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 切换时间范围并触发重载（新范围无缓存时查库，有缓存时走版本比对）。
  void setRange(LocalListenStatsRange range) {
    if (range == _selectedRange) return;
    _selectedRange = range;
    notifyListeners();
    unawaited(load());
  }

  /// 滚动窗口起点（毫秒）；all 为 null 表示不设下界。
  int? _startMsOf(LocalListenStatsRange range) {
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (range) {
      case LocalListenStatsRange.week:
        return now - 7 * 24 * 3600 * 1000;
      case LocalListenStatsRange.month:
        return now - 30 * 24 * 3600 * 1000;
      case LocalListenStatsRange.year:
        return now - 365 * 24 * 3600 * 1000;
      case LocalListenStatsRange.all:
        return null;
    }
  }

  /// 清空全部缓存（登录/登出/换号时由 syncLoginState 触发）。
  void reset() {
    _caches.clear();
    _isLoading = false;
    notifyListeners();
  }
}

/// 单个时间范围的一份缓存结果。
class _LocalRangeCache {
  const _LocalRangeCache({
    required this.version,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.overview,
    required this.monthlyTrends,
  });

  /// 建缓存时的 countByUser(validOnly: false) 快照，用于命中判断。
  final int version;
  final List<LocalTopEntry> topTracks;
  final List<LocalTopEntry> topArtists;
  final List<LocalTopEntry> topAlbums;
  final LocalOverview overview;
  final List<LocalMonthPoint> monthlyTrends;
}

/// Top 榜单条目（曲目/艺人/专辑三个维度共用结构，不可变）。
class LocalTopEntry {
  const LocalTopEntry({
    required this.key,
    required this.count,
    required this.playedMs,
    this.repTitle,
    this.repArtist,
    this.unknown = false,
  });

  /// 由库层行构造（listen_stats_db.dart 的 top* 返回行）。
  factory LocalTopEntry.fromDb(Map<String, Object?> row) => LocalTopEntry(
        key: row['key']! as String,
        count: row['count']! as int,
        playedMs: row['playedMs']! as int,
        repTitle: row['repTitle'] as String?,
        repArtist: row['repArtist'] as String?,
        unknown: (row['isUnknown'] as bool?) ?? false,
      );

  /// 分组键：曲名 / 艺人名 / 专辑名（"未知艺人"/"未知专辑"为归桶名）。
  final String key;

  /// 播放次数。
  final int count;

  /// 净播放时长合计（毫秒）。
  final int playedMs;

  /// 该组内净播放时长最长一曲的曲名（代表作，可空）。
  final String? repTitle;

  /// 该组内净播放时长最长一曲的演唱者（可空）。
  final String? repArtist;

  /// 是否为"未知艺人/未知专辑"归桶（NULL/空值合并而来）。
  final bool unknown;
}

/// 总览数值（不可变）。
class LocalOverview {
  const LocalOverview({
    this.plays = 0,
    this.playedMs = 0,
    this.activeDays = 0,
    this.distinctTracks = 0,
    this.distinctArtists = 0,
  });

  /// 播放次数。
  final int plays;

  /// 净播放时长合计（毫秒）。
  final int playedMs;

  /// 活跃天数（有播放的自然日数，本地时区）。
  final int activeDays;

  /// 曲目数（按曲名去重）。
  final int distinctTracks;

  /// 艺人数（NULL/空艺人计为"未知"一档）。
  final int distinctArtists;
}

/// 逐月趋势单点（不可变）。
class LocalMonthPoint {
  const LocalMonthPoint({
    required this.month,
    required this.count,
    required this.playedMs,
  });

  /// 月份，yyyyMM 整数（如 202610），升序。
  final int month;

  /// 当月播放次数。
  final int count;

  /// 当月净播放时长合计（毫秒）。
  final int playedMs;
}

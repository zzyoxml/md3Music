import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_api_client.dart';
import '../models/song.dart';

class HistoryRepository {
  // 单例：内存缓存与防抖 Timer 必须跨调用共享，
  // 否则每次 HistoryRepository() 新建实例都会重新读盘。
  static final HistoryRepository _instance = HistoryRepository._();
  factory HistoryRepository() => _instance;
  HistoryRepository._();

  static const String _baseKey = 'play_history';
  static const String _basePlayCountsKey = 'play_history_counts';
  static const String _baseLastPlayTimesKey = 'play_history_times';
  static const int _maxCount = 100;

  /// 播放次数/最近播放时间字典上限：长期使用不设上限会随历史听歌量
  /// 无限增长（每次切歌都要全量读写这两个 map），超限后按写入顺序淘汰最旧。
  static const int _countsMaxEntries = 2000;

  /// 历史落盘防抖：切歌路径只改内存，攒 5 秒合并写一次磁盘。
  /// App 退后台时由 [flush] 立即落盘兜底。
  static const Duration _flushDelay = Duration(seconds: 5);

  /// 播放历史键后缀：登录时按账号隔离（`_$userid`），未登录用全局键。
  String get _suffix {
    final uid = KugouApiClient().userid;
    return uid == null ? '' : '_$uid';
  }

  String get _key => '$_baseKey$_suffix';
  String get _playCountsKey => '$_basePlayCountsKey$_suffix';
  String get _lastPlayTimesKey => '$_baseLastPlayTimesKey$_suffix';

  // ── 内存缓存（按账号键隔离） ─────────────────────────────
  // _cachedSuffix 记录缓存所属账号：登录态切换后旧缓存作废重载，
  // 防止把 A 账号的历史/计数写进 B 账号的键。
  List<Song>? _historyCache;
  Map<String, int>? _countsCache;
  Map<String, int>? _timesCache;
  String? _cachedSuffix;
  Timer? _flushTimer;
  String? _flushSuffix; // 防抖期间实际应落盘的账号键

  /// 缓存属于当前账号时返回 true；否则作废旧缓存。
  bool _cacheValid() {
    if (_cachedSuffix == _suffix) return true;
    _historyCache = null;
    _countsCache = null;
    _timesCache = null;
    _cachedSuffix = null;
    return false;
  }

  /// 取内存缓存或从磁盘加载（加载结果同时填充缓存）。
  Future<List<Song>> _loadHistory(SharedPreferences prefs) async {
    if (_cacheValid() && _historyCache != null) return _historyCache!;
    final jsonList = prefs.getStringList(_key);
    final list = jsonList == null
        ? <Song>[]
        : jsonList
            .map((str) {
              try {
                return Song.fromJson(jsonDecode(str) as Map<String, dynamic>);
              } catch (_) {
                return null;
              }
            })
            .whereType<Song>()
            .toList();
    _historyCache = list;
    _cachedSuffix = _suffix;
    return list;
  }

  Future<Map<String, int>> _loadCounts(SharedPreferences prefs) async {
    if (_cacheValid() && _countsCache != null) return _countsCache!;
    _countsCache = await _readCountsFromDisk(prefs);
    _cachedSuffix = _suffix;
    return _countsCache!;
  }

  Future<Map<String, int>> _loadTimes(SharedPreferences prefs) async {
    if (_cacheValid() && _timesCache != null) return _timesCache!;
    _timesCache = await _readTimesFromDisk(prefs);
    _cachedSuffix = _suffix;
    return _timesCache!;
  }

  Future<Map<String, int>> _readCountsFromDisk(SharedPreferences prefs) async {
    final raw = prefs.getString(_playCountsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v is int ? v : 0));
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, int>> _readTimesFromDisk(SharedPreferences prefs) async {
    final raw = prefs.getString(_lastPlayTimesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v is int ? v : 0));
    } catch (_) {
      return {};
    }
  }

  Future<void> addHistory(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    // 快速路径：内存缓存已就绪 → 纯内存操作 + 调度防抖落盘
    if (_historyCache != null && _countsCache != null && _timesCache != null) {
      _applyHistoryInMemory(song);
      _scheduleFlush();
      return;
    }
    // 冷路径（首次切歌）：加载磁盘到缓存后同样走内存路径
    await _loadHistory(prefs);
    await _loadCounts(prefs);
    await _loadTimes(prefs);
    _applyHistoryInMemory(song);
    _scheduleFlush();
  }

  void _applyHistoryInMemory(Song song) {
    final history = _historyCache!;
    history.removeWhere((s) => s.id == song.id);
    history.insert(0, song);
    if (history.length > _maxCount) {
      history.removeRange(_maxCount, history.length);
    }

    // 累加播放次数（超限淘汰最旧条目）
    final counts = _countsCache!;
    counts[song.id] = (counts[song.id] ?? 0) + 1;
    if (counts.length > _countsMaxEntries) {
      counts.remove(counts.keys.first);
    }

    // 更新最近播放时间（秒级时间戳），同样受上限约束
    final times = _timesCache!;
    times[song.id] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (times.length > _countsMaxEntries) {
      times.remove(times.keys.first);
    }
  }

  /// 调度防抖落盘：切歌高频路径不直接写磁盘。
  void _scheduleFlush() {
    _flushSuffix = _suffix;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, flush);
  }

  /// 立即把内存缓存落盘（App 退后台 / 定时器到期时调用）。
  ///
  /// 落盘使用记录时刻的账号键：即使期间发生登录态切换，也不会把
  /// A 账号的历史写进 B 账号的键。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final history = _historyCache;
    final counts = _countsCache;
    final times = _timesCache;
    final suffix = _flushSuffix;
    if (history == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (suffix != null && suffix != _suffix) {
      // 账号已切换：用记录时刻的键落盘
      await prefs.setStringList(
        '$_baseKey$suffix',
        history.map((s) => jsonEncode(s.toJson())).toList(),
      );
      if (counts != null) {
        await prefs.setString('$_basePlayCountsKey$suffix', jsonEncode(counts));
      }
      if (times != null) {
        await prefs.setString('$_baseLastPlayTimesKey$suffix', jsonEncode(times));
      }
      return;
    }
    await prefs.setStringList(
      _key,
      history.map((s) => jsonEncode(s.toJson())).toList(),
    );
    if (counts != null) {
      await prefs.setString(_playCountsKey, jsonEncode(counts));
    }
    if (times != null) {
      await prefs.setString(_lastPlayTimesKey, jsonEncode(times));
    }
  }

  Future<List<Song>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadHistory(prefs);
  }

  /// 获取每首歌的播放次数 {songId: count}
  Future<Map<String, int>> getPlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadCounts(prefs);
  }

  /// 获取每首歌最近一次播放时间 {songId: epochSeconds}
  Future<Map<String, int>> getLastPlayTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadTimes(prefs);
  }

  /// 获取按播放次数降序排列的歌曲列表（含播放次数）。
  ///
  /// [recentDays] 为 null 时返回全部累计；不为 null 时只返回最近 N 天内播放过的歌曲。
  Future<List<RankedSong>> getRankedSongs({int? recentDays}) async {
    final history = await getHistory();
    final counts = await getPlayCounts();
    final times = await getLastPlayTimestamps();

    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cutoff = recentDays != null
        ? nowEpoch - (recentDays * 86400)
        : 0;

    final ranked = <RankedSong>[];
    for (final song in history) {
      final count = counts[song.id] ?? 0;
      final lastTime = times[song.id] ?? 0;
      if (count <= 0) continue;
      if (recentDays != null && lastTime < cutoff) continue;
      ranked.add(RankedSong(song: song, playCount: count));
    }

    // 按播放次数降序
    ranked.sort((a, b) => b.playCount.compareTo(a.playCount));
    return ranked;
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_playCountsKey);
    await prefs.remove(_lastPlayTimesKey);
    // 同步清空内存缓存，避免旧数据被后续 flush 复活
    _historyCache = null;
    _countsCache = null;
    _timesCache = null;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// 删除指定 id 的播放历史，并同步清理对应的播放次数与最近播放时间。
  Future<void> removeIds(Set<String> ids) async {
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final history = await _loadHistory(prefs);
    final counts = await _loadCounts(prefs);
    final times = await _loadTimes(prefs);

    history.removeWhere((s) => ids.contains(s.id));
    counts.removeWhere((k, _) => ids.contains(k));
    times.removeWhere((k, _) => ids.contains(k));

    // 低频管理操作：直接落盘（跳过防抖）
    _flushTimer?.cancel();
    _flushTimer = null;
    await prefs.setStringList(
      _key,
      history.map((s) => jsonEncode(s.toJson())).toList(),
    );
    await prefs.setString(_playCountsKey, jsonEncode(counts));
    await prefs.setString(_lastPlayTimesKey, jsonEncode(times));
  }
}

/// 带播放次数的歌曲（用于排行展示）
class RankedSong {
  final Song song;
  final int playCount;

  const RankedSong({required this.song, required this.playCount});
}

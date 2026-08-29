import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_api_client.dart';
import '../models/song.dart';

class HistoryRepository {
  static const String _baseKey = 'play_history';
  static const String _basePlayCountsKey = 'play_history_counts';
  static const String _baseLastPlayTimesKey = 'play_history_times';
  static const int _maxCount = 100;

  /// 播放历史键后缀：登录时按账号隔离（`_$userid`），未登录用全局键。
  String get _suffix {
    final uid = KugouApiClient().userid;
    return uid == null ? '' : '_$uid';
  }

  String get _key => '$_baseKey$_suffix';
  String get _playCountsKey => '$_basePlayCountsKey$_suffix';
  String get _lastPlayTimesKey => '$_baseLastPlayTimesKey$_suffix';

  Future<void> addHistory(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await getHistory();
    history.removeWhere((s) => s.id == song.id);
    history.insert(0, song);
    if (history.length > _maxCount) {
      history.removeRange(_maxCount, history.length);
    }
    final jsonList = history.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_key, jsonList);

    // 累加播放次数
    final counts = await getPlayCounts();
    counts[song.id] = (counts[song.id] ?? 0) + 1;
    await prefs.setString(_playCountsKey, jsonEncode(counts));

    // 更新最近播放时间（秒级时间戳）
    final times = await getLastPlayTimestamps();
    times[song.id] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await prefs.setString(_lastPlayTimesKey, jsonEncode(times));
  }

  Future<List<Song>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key);
    if (jsonList == null) return [];
    return jsonList
        .map((str) {
          try {
            return Song.fromJson(jsonDecode(str) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<Song>()
        .toList();
  }

  /// 获取每首歌的播放次数 {songId: count}
  Future<Map<String, int>> getPlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playCountsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v is int ? v : 0));
    } catch (_) {
      return {};
    }
  }

  /// 获取每首歌最近一次播放时间 {songId: epochSeconds}
  Future<Map<String, int>> getLastPlayTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastPlayTimesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v is int ? v : 0));
    } catch (_) {
      return {};
    }
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
  }
}

/// 带播放次数的歌曲（用于排行展示）
class RankedSong {
  final Song song;
  final int playCount;

  const RankedSong({required this.song, required this.playCount});
}

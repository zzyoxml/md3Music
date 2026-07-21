import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// 持久化"上次退出时的播放状态"：播放列表 + 当前索引 + 进度。
///
/// 仅持久化元数据，不持久化在线歌曲的临时 URL（保存时置 null），
/// 恢复时由 PlayerProvider._resolveAndPlayCurrentSong 重新解析 URL。
///
/// 触发保存的时机：
/// - App 进入后台（AppLifecycleState.paused）
/// - 切歌（next/previous/playSongAt/playSong/playPlaylist）
/// - 暂停（pause）
/// - 清空播放列表（clearPlaylist）
/// - 单曲播放完成（_handlePlaybackCompleted）
class PlaybackStateRepository {
  static const String _keyPlaylist = 'playback_playlist';
  static const String _keyCurrentIndex = 'playback_current_index';
  static const String _keyPositionMs = 'playback_position_ms';

  /// 保存播放状态。在线歌曲的 url 字段会被置 null（URL 会过期）。
  Future<void> save({
    required List<Song> playlist,
    required int currentIndex,
    required Duration position,
  }) async {
    // 索引非法时清空，避免恢复时越界
    if (playlist.isEmpty || currentIndex < 0 || currentIndex >= playlist.length) {
      await clear();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    // 在线歌曲 url 置 null，避免恢复时使用过期 URL；
    // 本地歌曲 localPath 保留（不会过期）
    final sanitizedJson = playlist.map((song) {
      final json = song.toJson();
      if (song.isOnline) {
        json['url'] = null;
      }
      return jsonEncode(json);
    }).toList();
    await prefs.setStringList(_keyPlaylist, sanitizedJson);
    await prefs.setInt(_keyCurrentIndex, currentIndex);
    await prefs.setInt(_keyPositionMs, position.inMilliseconds);
  }

  /// 读取保存的播放状态。返回 null 表示无保存数据或数据损坏。
  Future<({List<Song> playlist, int currentIndex, Duration position})?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_keyPlaylist);
    if (jsonList == null || jsonList.isEmpty) return null;
    final index = prefs.getInt(_keyCurrentIndex) ?? -1;
    final posMs = prefs.getInt(_keyPositionMs) ?? 0;
    if (index < 0 || index >= jsonList.length) return null;

    final playlist = <Song>[];
    for (final str in jsonList) {
      try {
        playlist.add(Song.fromJson(jsonDecode(str) as Map<String, dynamic>));
      } catch (_) {
        // 跳过损坏的条目，保证其余歌曲仍可恢复
      }
    }
    // 部分条目损坏后索引可能越界，做一次保护
    if (playlist.isEmpty || index >= playlist.length) return null;
    return (
      playlist: playlist,
      currentIndex: index,
      position: Duration(milliseconds: posMs),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPlaylist);
    await prefs.remove(_keyCurrentIndex);
    await prefs.remove(_keyPositionMs);
  }
}

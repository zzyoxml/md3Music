import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// 在后台 isolate 中编码播放列表（主 isolate 只做 toJson 的浅转换）。
List<String> _encodePlaylistJson(List<Map<String, dynamic>> songs) =>
    songs.map((s) => jsonEncode(s)).toList();

/// 播放器状态持久化：保存/恢复当前歌曲、播放列表、播放位置、循环模式等。
///
/// 冷启动时 PlayerProvider 从此处读取上次状态，恢复播放位置并准备就绪。
///
/// 性能约定：
/// - [saveCursor] 仅写游标类字段（当前歌/索引/位置/模式），高频调用开销极小；
/// - [savePlaylist] 仅在队列结构变化（换歌单/增删/排序/随机）时调用，
///   序列化在后台 isolate 执行，避免大队列在主 isolate 上 jsonEncode。
class PlayerStateRepository {
  static const _keyCurrentSong = 'player_current_song';
  static const _keyPlaylist = 'player_playlist';
  static const _keyCurrentIndex = 'player_current_index';
  static const _keyPosition = 'player_position';
  static const _keyLoopMode = 'player_loop_mode';
  static const _keyShuffleEnabled = 'player_shuffle_enabled';

  /// 保存游标类播放状态（当前歌/索引/位置/模式），不触碰队列本体。
  ///
  /// 高频路径（position 防抖/暂停/seek/切歌）只调用本方法；
  /// 大队列序列化成本完全由 [savePlaylist] 承担（低频）。
  Future<void> saveCursor({
    required Song? currentSong,
    required int currentIndex,
    required Duration position,
    required String loopMode,
    required bool shuffleEnabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    if (currentSong != null) {
      await prefs.setString(_keyCurrentSong, jsonEncode(currentSong.toJson()));
    } else {
      await prefs.remove(_keyCurrentSong);
    }
    await prefs.setInt(_keyCurrentIndex, currentIndex);
    await prefs.setInt(_keyPosition, position.inMilliseconds);
    await prefs.setString(_keyLoopMode, loopMode);
    await prefs.setBool(_keyShuffleEnabled, shuffleEnabled);
  }

  /// 保存播放队列本体（仅在队列结构变化时调用；编码在后台 isolate）。
  Future<void> savePlaylist(List<Song> playlist) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = await compute(
      _encodePlaylistJson,
      playlist.map((s) => s.toJson()).toList(growable: false),
    );
    await prefs.setStringList(_keyPlaylist, jsonList);
  }

  /// 保存当前播放状态（完整：游标 + 队列）。
  ///
  /// 供低频路径使用；高频路径请优先使用 [saveCursor] / [savePlaylist] 组合。
  Future<void> saveState({
    required Song? currentSong,
    required List<Song> playlist,
    required int currentIndex,
    required Duration position,
    required String loopMode,
    required bool shuffleEnabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    if (currentSong != null) {
      await prefs.setString(_keyCurrentSong, jsonEncode(currentSong.toJson()));
    } else {
      await prefs.remove(_keyCurrentSong);
    }

    final jsonList = await compute(
      _encodePlaylistJson,
      playlist.map((s) => s.toJson()).toList(growable: false),
    );
    await prefs.setStringList(_keyPlaylist, jsonList);
    await prefs.setInt(_keyCurrentIndex, currentIndex);
    await prefs.setInt(_keyPosition, position.inMilliseconds);
    await prefs.setString(_keyLoopMode, loopMode);
    await prefs.setBool(_keyShuffleEnabled, shuffleEnabled);
  }

  /// 恢复上次的播放状态。
  Future<PlayerState?> restoreState() async {
    final prefs = await SharedPreferences.getInstance();

    final songJson = prefs.getString(_keyCurrentSong);
    if (songJson == null) return null;

    Song currentSong;
    try {
      currentSong = Song.fromJson(jsonDecode(songJson) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }

    final jsonList = prefs.getStringList(_keyPlaylist);
    final playlist = jsonList
        ?.map((str) {
          try {
            return Song.fromJson(jsonDecode(str) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<Song>()
        .toList();
    if (playlist == null || playlist.isEmpty) return null;

    final currentIndex = prefs.getInt(_keyCurrentIndex) ?? 0;
    final positionMs = prefs.getInt(_keyPosition) ?? 0;
    final loopMode = prefs.getString(_keyLoopMode) ?? 'off';
    final shuffleEnabled = prefs.getBool(_keyShuffleEnabled) ?? false;

    return PlayerState(
      currentSong: currentSong,
      playlist: playlist,
      currentIndex: currentIndex.clamp(0, playlist.length - 1),
      position: Duration(milliseconds: positionMs),
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
    );
  }

  /// 清除保存的状态。
  Future<void> clearState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCurrentSong);
    await prefs.remove(_keyPlaylist);
    await prefs.remove(_keyCurrentIndex);
    await prefs.remove(_keyPosition);
    await prefs.remove(_keyLoopMode);
    await prefs.remove(_keyShuffleEnabled);
  }
}

class PlayerState {
  final Song currentSong;
  final List<Song> playlist;
  final int currentIndex;
  final Duration position;
  final String loopMode;
  final bool shuffleEnabled;

  const PlayerState({
    required this.currentSong,
    required this.playlist,
    required this.currentIndex,
    required this.position,
    required this.loopMode,
    required this.shuffleEnabled,
  });
}

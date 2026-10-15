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
  PlayerStateRepository({this.beforeWrite});

  static const _keyCurrentSong = 'player_current_song';
  static const _keyPlaylist = 'player_playlist';
  static const _keyCurrentIndex = 'player_current_index';
  static const _keyPosition = 'player_position';
  static const _keyLoopMode = 'player_loop_mode';
  static const _keyShuffleEnabled = 'player_shuffle_enabled';

  // 进程内单写者队列：游标、队列和清空按调用顺序落盘。
  // 前一项失败不会阻断后续保存，但各调用者仍会收到自己那次写入的错误。
  Future<void> _writeTail = Future<void>.value();
  @visibleForTesting
  final Future<void> Function(String step)? beforeWrite;

  Future<void> _before(String step) async {
    await beforeWrite?.call(step);
  }

  Future<void> _enqueueWrite(Future<void> Function() write) {
    final operation = _writeTail.then((_) => write());
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  /// 等待调用时已经排入队列的播放状态写入完成。
  ///
  /// 后续新写入不属于本次屏障；已失败写入仍由对应保存调用报告，flush只负责排空。
  Future<void> flush() => _writeTail;

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
    final currentSongJson = currentSong == null
        ? null
        : jsonEncode(currentSong.toJson());
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      if (currentSongJson != null) {
        await _before('cursor.current_song');
        await prefs.setString(_keyCurrentSong, currentSongJson);
      } else {
        await _before('cursor.current_song');
        await prefs.remove(_keyCurrentSong);
      }
      await _before('cursor.index');
      await prefs.setInt(_keyCurrentIndex, currentIndex);
      await _before('cursor.position');
      await prefs.setInt(_keyPosition, position.inMilliseconds);
      await _before('cursor.loop_mode');
      await prefs.setString(_keyLoopMode, loopMode);
      await _before('cursor.shuffle');
      await prefs.setBool(_keyShuffleEnabled, shuffleEnabled);
    });
  }

  /// 保存播放队列本体（仅在队列结构变化时调用；编码在后台 isolate）。
  Future<void> savePlaylist(List<Song> playlist) {
    final snapshot = playlist.map((song) => song.toJson()).toList();
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = await compute(_encodePlaylistJson, snapshot);
      await _before('playlist.value');
      await prefs.setStringList(_keyPlaylist, jsonList);
    });
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
  }) {
    final currentSongJson = currentSong == null
        ? null
        : jsonEncode(currentSong.toJson());
    final playlistSnapshot = playlist.map((song) => song.toJson()).toList();
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      if (currentSongJson != null) {
        await _before('state.current_song');
        await prefs.setString(_keyCurrentSong, currentSongJson);
      } else {
        await _before('state.current_song');
        await prefs.remove(_keyCurrentSong);
      }
      final jsonList = await compute(_encodePlaylistJson, playlistSnapshot);
      await _before('state.playlist');
      await prefs.setStringList(_keyPlaylist, jsonList);
      await _before('state.index');
      await prefs.setInt(_keyCurrentIndex, currentIndex);
      await _before('state.position');
      await prefs.setInt(_keyPosition, position.inMilliseconds);
      await _before('state.loop_mode');
      await prefs.setString(_keyLoopMode, loopMode);
      await _before('state.shuffle');
      await prefs.setBool(_keyShuffleEnabled, shuffleEnabled);
    });
  }

  /// 恢复上次的播放状态。
  Future<PlayerState?> restoreState() async {
    await _writeTail;
    final prefs = await SharedPreferences.getInstance();

    String? songJson;
    try {
      songJson = prefs.getString(_keyCurrentSong);
    } catch (_) {
      // 偏好项类型损坏时，不让恢复流程中断应用启动。
      return null;
    }
    if (songJson == null) return null;

    Song currentSong;
    try {
      currentSong = Song.fromJson(jsonDecode(songJson) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }

    List<String>? jsonList;
    try {
      jsonList = prefs.getStringList(_keyPlaylist);
    } catch (_) {
      // 队列类型损坏时仍可按当前歌曲恢复单曲。
    }
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
    // 队列本体缺失/为空但当前歌存在：降级为「单曲队列」恢复，而不是整块放弃。
    // 队列写入失败（如整表替换入口漏落盘的历史数据）时，至少把当前歌与进度
    // 找回来，而不是让冷启动回到完全空白的播放器。
    // 不会误恢复「用户主动删空的队列」：删空路径会一并移除 player_current_song
    // （saveCursor(currentSong: null) 直接删除该键），此处已提前 return null。
    var effectivePlaylist = (playlist == null || playlist.isEmpty)
        ? <Song>[currentSong]
        : playlist;

    int storedIndex;
    try {
      storedIndex = prefs.getInt(_keyCurrentIndex) ?? 0;
    } catch (_) {
      storedIndex = 0;
    }
    var currentIndex = storedIndex.clamp(0, effectivePlaylist.length - 1);
    if (effectivePlaylist[currentIndex].id != currentSong.id) {
      final matchingIndex = effectivePlaylist.indexWhere(
        (song) => song.id == currentSong.id,
      );
      if (matchingIndex >= 0) {
        currentIndex = matchingIndex;
      } else {
        // 多键写入中断后找不到当前歌对应项时，退化为可解释的单曲快照，
        // 避免用旧索引恢复成另一首歌。
        effectivePlaylist = [currentSong];
        currentIndex = 0;
      }
    }

    int rawPositionMs;
    try {
      rawPositionMs = prefs.getInt(_keyPosition) ?? 0;
    } catch (_) {
      rawPositionMs = 0;
    }
    final maxPositionMs = currentSong.duration.inMilliseconds;
    final positionMs = rawPositionMs < 0
        ? 0
        : maxPositionMs > 0
        ? rawPositionMs.clamp(0, maxPositionMs)
        : rawPositionMs;
    String loopMode;
    try {
      loopMode = prefs.getString(_keyLoopMode) ?? 'off';
    } catch (_) {
      loopMode = 'off';
    }
    bool shuffleEnabled;
    try {
      shuffleEnabled = prefs.getBool(_keyShuffleEnabled) ?? false;
    } catch (_) {
      shuffleEnabled = false;
    }

    return PlayerState(
      currentSong: currentSong,
      playlist: effectivePlaylist,
      currentIndex: currentIndex,
      position: Duration(milliseconds: positionMs),
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
    );
  }

  /// 清除保存的状态。
  Future<void> clearState() {
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      await _before('clear.current_song');
      await prefs.remove(_keyCurrentSong);
      await _before('clear.playlist');
      await prefs.remove(_keyPlaylist);
      await _before('clear.index');
      await prefs.remove(_keyCurrentIndex);
      await _before('clear.position');
      await prefs.remove(_keyPosition);
      await _before('clear.loop_mode');
      await prefs.remove(_keyLoopMode);
      await _before('clear.shuffle');
      await prefs.remove(_keyShuffleEnabled);
    });
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

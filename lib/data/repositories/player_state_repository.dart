import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// 在后台 isolate 中编码播放列表（主 isolate 只做 toJson 的浅转换）。
List<String> _encodePlaylistJson(List<Map<String, dynamic>> songs) =>
    songs.map((s) => jsonEncode(s)).toList();

/// 播放器状态持久化：保存/恢复当前歌曲、播放列表、播放位置、循环模式等。
///
/// 冷启动时 PlayerProvider 从此处读取上次状态，恢复播放位置并准备就绪。
///
/// ## 为什么游标不再写 `SharedPreferences`（2026-10-24）
///
/// Windows 的 `shared_preferences` 是**整文件重写**实现：每次 `setXxx()/remove()`
/// 都把**全部**偏好项重新 `jsonEncode` 再落盘。本仓偏好文件实测 1.7 MB（播放
/// 列表、历史、收藏都在里面），**单个键写入 ≈ 41~45 ms**；[saveCursor] 原先一次
/// 写 5 个键 → 主 isolate 被堵 **≈200 ms**，表现为「暂停/恢复/拖动进度时整窗
/// 冻一下」（每 5s 的位置防抖同样触发）。键盘与鼠标、暂停与播放都卡，根因在此。
///
/// 现在游标写进**独立小文件** `playback_cursor.json`（几百字节，异步 IO，主
/// isolate 同步开销 <1ms）。`SharedPreferences` 只保留为**旧数据读取来源**：
/// 读不到游标文件时才回退旧键（并顺手迁移），拿不到应用目录（单元测试等）
/// 时退回偏好项单键存储。
///
/// 性能约定：
/// - [saveCursor] 仅写游标类字段（当前歌/索引/位置/模式），单次小文件写；
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

  /// 游标回退存储键（拿不到应用目录时使用；单键一次写入，替代旧版 5 键）。
  static const _keyCursor = 'player_cursor';

  /// 游标文件默认文件名（位于应用支持目录）。
  static const _cursorFileName = 'playback_cursor.json';

  /// 游标文件是否已解析（解析失败也记一次，避免每次保存都去问 path_provider）。
  bool _cursorFileResolved = false;
  File? _cursorFileCache;

  /// 测试注入：返回 null 表示强制走偏好项单键回退路径；单元测试用它把落盘
  /// 隔离掉（否则 Windows 上 path_provider 会真的写到用户目录，跨用例串状态）。
  @visibleForTesting
  static Future<File?> Function()? debugCursorFileOverride;

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

  /// 游标文件（应用支持目录下的独立小文件）。拿不到目录时返回 null，
  /// 调用方退回偏好项单键存储（单元测试等无插件环境）。
  Future<File?> _cursorFile() async {
    final Future<File?> Function()? override = debugCursorFileOverride;
    if (override != null) return override();
    if (_cursorFileResolved) return _cursorFileCache;
    _cursorFileResolved = true;
    try {
      final Directory dir = await getApplicationSupportDirectory();
      _cursorFileCache =
          File('${dir.path}${Platform.pathSeparator}$_cursorFileName');
    } catch (_) {
      _cursorFileCache = null;
    }
    return _cursorFileCache;
  }

  String _encodeCursor({
    required Song? currentSong,
    required int currentIndex,
    required Duration position,
    required String loopMode,
    required bool shuffleEnabled,
  }) {
    return jsonEncode(<String, Object?>{
      'song': currentSong?.toJson(),
      'index': currentIndex,
      'position': position.inMilliseconds,
      'loopMode': loopMode,
      'shuffleEnabled': shuffleEnabled,
    });
  }

  /// 写入游标存储：优先小文件，其次偏好项单键（一次写入，不触发多次整文件重写）。
  Future<void> _writeCursorStore(String payload) async {
    final File? file = await _cursorFile();
    if (file != null) {
      await file.writeAsString(payload);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCursor, payload);
  }

  /// 读取游标存储。`present=false` 表示两种存储都不存在，此时才允许回退
  /// 旧版逐键数据；`present=true` 且 `value=null` 表示存过但已损坏/已清空，
  /// 必须当作「没有可恢复状态」，不能让旧键把已清状态复活。
  Future<({bool present, Map<String, dynamic>? value})>
  _readCursorStore() async {
    final File? file = await _cursorFile();
    if (file != null) {
      try {
        if (await file.exists()) {
          final String raw = await file.readAsString();
          final Object? decoded = jsonDecode(raw);
          return (
            present: true,
            value: decoded is Map<String, dynamic> ? decoded : null,
          );
        }
      } catch (_) {
        return (present: true, value: null);
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_keyCursor);
      if (raw == null) return (present: false, value: null);
      final Object? decoded = jsonDecode(raw);
      return (
        present: true,
        value: decoded is Map<String, dynamic> ? decoded : null,
      );
    } catch (_) {
      return (present: true, value: null);
    }
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
  }) {
    // 编码只涉及一首歌的小对象（<1KB），主 isolate 成本可忽略；
    // 落盘走独立小文件 / 偏好项单键，避免旧实现 5 次整表重写（≈200ms）。
    final String payload = _encodeCursor(
      currentSong: currentSong,
      currentIndex: currentIndex,
      position: position,
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
    );
    return _enqueueWrite(() async {
      await _before('cursor.write');
      await _writeCursorStore(payload);
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
    final playlistSnapshot = playlist.map((song) => song.toJson()).toList();
    // 游标存储（小文件 / 偏好项单键）与旧逐键数据同步刷新，恢复时优先读它。
    final String cursorPayload = _encodeCursor(
      currentSong: currentSong,
      currentIndex: currentIndex,
      position: position,
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
    );
    return _enqueueWrite(() async {
      // 游标先写（小文件，代价可忽略）：即使后面的队列写入失败，恢复时也能
      // 拿到最新的「当前歌 + 进度」，队列缺失由 restoreState 的单曲降级兜住。
      await _before('state.cursor_store');
      await _writeCursorStore(cursorPayload);
      final prefs = await SharedPreferences.getInstance();
      final jsonList = await compute(_encodePlaylistJson, playlistSnapshot);
      await _before('state.playlist');
      await prefs.setStringList(_keyPlaylist, jsonList);
    });
  }

  /// 恢复上次的播放状态。
  Future<PlayerState?> restoreState() async {
    await _writeTail;
    final prefs = await SharedPreferences.getInstance();

    // 游标存储（小文件 / 偏好项单键）存在时只认它：旧逐键数据可能是已被
    // 清理或长期未更新的陈旧值，混用会让「已清空的队列」复活。
    final ({bool present, Map<String, dynamic>? value}) cursor =
        await _readCursorStore();
    final bool useCursorStore = cursor.present;
    final Map<String, dynamic>? cursorValue = cursor.value;

    String? songJson;
    if (useCursorStore) {
      final Object? songValue = cursorValue?['song'];
      songJson = songValue == null ? null : jsonEncode(songValue);
    } else {
      try {
        songJson = prefs.getString(_keyCurrentSong);
      } catch (_) {
        // 偏好项类型损坏时，不让恢复流程中断应用启动。
        return null;
      }
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
    if (useCursorStore) {
      final Object? stored = cursorValue?['index'];
      storedIndex = stored is int ? stored : 0;
    } else {
      try {
        storedIndex = prefs.getInt(_keyCurrentIndex) ?? 0;
      } catch (_) {
        storedIndex = 0;
      }
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
    if (useCursorStore) {
      final Object? stored = cursorValue?['position'];
      rawPositionMs = stored is int ? stored : 0;
    } else {
      try {
        rawPositionMs = prefs.getInt(_keyPosition) ?? 0;
      } catch (_) {
        rawPositionMs = 0;
      }
    }
    final maxPositionMs = currentSong.duration.inMilliseconds;
    final positionMs = rawPositionMs < 0
        ? 0
        : maxPositionMs > 0
        ? rawPositionMs.clamp(0, maxPositionMs)
        : rawPositionMs;
    String loopMode;
    if (useCursorStore) {
      final Object? stored = cursorValue?['loopMode'];
      loopMode = stored is String ? stored : 'off';
    } else {
      try {
        loopMode = prefs.getString(_keyLoopMode) ?? 'off';
      } catch (_) {
        loopMode = 'off';
      }
    }
    bool shuffleEnabled;
    if (useCursorStore) {
      final Object? stored = cursorValue?['shuffleEnabled'];
      shuffleEnabled = stored is bool ? stored : false;
    } else {
      try {
        shuffleEnabled = prefs.getBool(_keyShuffleEnabled) ?? false;
      } catch (_) {
        shuffleEnabled = false;
      }
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
      // 游标存储一并清理：删小文件 + 移除回退单键。
      // 否则旧文件会让「清空队列」后的冷启动复活上一首。
      await _before('clear.cursor_store');
      final File? cursorFile = await _cursorFile();
      if (cursorFile != null) {
        try {
          if (await cursorFile.exists()) await cursorFile.delete();
        } catch (_) {}
      }
      await prefs.remove(_keyCursor);
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

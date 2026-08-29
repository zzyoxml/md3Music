import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/song.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// Lyricon 设备桥接服务：作为 Dart 与 Kotlin（MainActivity MethodChannel
/// `com.md3music.md3music/lyricon`）之间的中间层，负责向 Lyricon 实时歌词
/// 提供方推送歌曲信息、播放进度、播放状态以及用户偏好（翻译 / 罗马音），
/// 并接收 Kotlin 侧反向回调的连接状态变更，通知 UI 刷新。
///
/// 设计参考 [DesktopLyricService]：单例 + `addListener` 通知模式，
/// 所有 MethodChannel 调用均 try-catch 静默吞异常，避免桥接失败影响主播放流程。
enum LyriconConnectionState {
  /// 未启用
  disabled,

  /// 连接中
  connecting,

  /// 已连接
  connected,

  /// 已断开
  disconnected,

  /// 连接超时
  timeout,
}

class LyriconProviderService {
  static final LyriconProviderService instance =
      LyriconProviderService._();
  LyriconProviderService._();

  static const _channel = MethodChannel('com.md3music.md3music/lyricon');

  LyriconConnectionState _state = LyriconConnectionState.disabled;
  LyriconConnectionState get state => _state;

  bool get enabled => _state != LyriconConnectionState.disabled;

  /// 原生端多次重连仍失败（connect_failed）后置 true，UI 监听后弹窗提示用户。
  /// 用户重新启用 / 连接成功后清空。
  bool connectFailed = false;

  // 通知外部状态变化（让 UI 可以监听刷新连接状态指示）
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// 在 main.dart 启动时调用一次：注册 Kotlin 反向回调 handler。
  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onConnectionStateChanged':
          _onConnectionStateChanged(call.arguments as String?);
          break;
      }
    });
  }

  void _onConnectionStateChanged(String? state) {
    switch (state) {
      case 'connected':
      case 'reconnected':
        connectFailed = false;
        _state = LyriconConnectionState.connected;
        break;
      case 'auto_restored':
        // Kotlin 端在 AudioPlaybackService.onCreate 自动恢复后回调此事件。
        // 这里直接进 connecting：Provider 已 register，但 Lyricon 中心服务
        // 尚未回调 onConnected，等异步连接成功后再切到 connected。
        // 同时让 PlayerProvider 监听到此状态变化后重推当前歌曲。
        connectFailed = false;
        _state = LyriconConnectionState.connecting;
        break;
      case 'connect_failed':
        // Kotlin 端多次重连仍失败后回调：通知 UI 弹窗提示用户检查词幕服务。
        _state = LyriconConnectionState.timeout;
        connectFailed = true;
        break;
      case 'disconnected':
        _state = LyriconConnectionState.disconnected;
        break;
      case 'timeout':
        _state = LyriconConnectionState.timeout;
        break;
      default:
        return;
    }
    _notify();
  }

  /// 启用 / 禁用 Lyricon 提供方。
  ///
  /// 启用前先本地切到 connecting 态，禁用立刻切到 disabled 态，
  /// 让 UI 无需等待原生回调即可反馈。
  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      _state = LyriconConnectionState.connecting;
    } else {
      _state = LyriconConnectionState.disabled;
    }
    // 用户手动操作：清空失败标记，允许后续再次弹窗
    connectFailed = false;
    _notify();
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  /// 推送当前歌曲 + 完整歌词列表给 Kotlin。
  ///
  /// 字段映射（已与模型源码核对）：
  /// - Song.title → songMap['name']（Kotlin 侧期望 name）
  /// - Song.artist → songMap['artist']
  /// - Song.duration 是 Duration，需 .inMilliseconds 转 int
  /// - LyricLine.startTime / endTime 均为 int（毫秒），endTime 是 getter
  /// - LyricWord.startTime 是 int（毫秒），无 endTime getter，用 startTime + duration
  /// - LyricLine.translation / roma 是 String?，原样透传
  ///
  /// preferTranslation 行为：读取 SharedPreferences 的 lyricon_prefer_translation
  /// 偏好。当某行同时携带 translation 和 roma 时二选一推送：
  /// - preferTranslation=true（默认）：保留 translation，丢弃 roma
  /// - preferTranslation=false：保留 roma，丢弃 translation
  /// 单独存在 translation 或 roma 时不受影响，原样透传。
  Future<void> setSong(Song? song, List<LyricLine> lines, {int? positionMs}) async {
    // 缓存本次参数，供 repushLastSong 重新推送（用户切换 preferTranslation 后触发）
    _lastSong = song;
    _lastLines = lines;

    if (song == null) {
      try {
        await _channel.invokeMethod('setSong', {'song': null});
      } catch (_) {}
      return;
    }
    // 读取 preferTranslation 偏好（默认 true：同时存在时优先推送翻译）
    bool preferTranslation = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      preferTranslation = prefs.getBool('lyricon_prefer_translation') ?? true;
    } catch (_) {}

    // 预处理：为每行计算一个合法的 end。
    // LRC 解析器输出的 duration=0，导致 endTime==startTime，会被 SDK 的
    // Song.normalize() 过滤（条件 begin < end 失败）。兜底策略：
    // - LRC 行（duration==0）：end = 下一行 startTime；末行 end = begin + 5000
    // - KRC 行（duration>0）：原样使用 endTime
    // 同时过滤 text 为空白的行（normalize 也会过滤，提前过滤避免无意义传输）。
    final List<Map<String, dynamic>> lyricMaps = [];
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.text.trim().isEmpty) continue;
      final int begin = line.startTime;
      final int end;
      if (line.endTime > begin) {
        end = line.endTime;
      } else if (i + 1 < lines.length && lines[i + 1].startTime > begin) {
        end = lines[i + 1].startTime;
      } else {
        end = begin + 5000; // 末行兜底 5 秒
      }
      // 同时存在翻译和罗马音时二选一：
      // - preferTranslation=true：保留 translation，丢弃 roma
      // - preferTranslation=false：保留 roma，丢弃 translation
      final hasTranslation = line.translation != null &&
          line.translation!.isNotEmpty;
      final hasRoma = line.roma != null && line.roma!.isNotEmpty;
      final String? translationValue;
      final String? romaValue;
      if (hasTranslation && hasRoma) {
        if (preferTranslation) {
          translationValue = line.translation;
          romaValue = null;
        } else {
          translationValue = null;
          romaValue = line.roma;
        }
      } else {
        translationValue = line.translation;
        romaValue = line.roma;
      }
      lyricMaps.add(<String, dynamic>{
        'begin': begin,
        'end': end,
        'text': line.text,
        if (translationValue != null) 'translation': translationValue,
        if (romaValue != null) 'roma': romaValue,
        'words': line.words
            .map((w) => <String, dynamic>{
                  'text': w.text,
                  'begin': w.startTime,
                  'end': w.startTime + w.duration,
                })
            .toList(),
      });
    }

    final songMap = <String, dynamic>{
      'id': song.id,
      // 用 displayName 剥离 .mp3/.flac 等后缀，避免 Lyricon 标题显示带后缀
      'name': song.displayName,
      'artist': song.artist,
      'duration': song.duration.inMilliseconds,
      // 切歌起点（毫秒）：Kotlin 端 setSong 后据此建立 Auto PlaybackState 基点，
      // 否则新歌可能从 0 或上一曲位置开始走时
      if (positionMs != null) 'startPositionMs': positionMs,
      'lyrics': lyricMaps,
    };
    try {
      await _channel.invokeMethod('setSong', {'song': songMap});
    } catch (_) {}
  }

  /// 缓存上次 setSong 的参数，供 repushLastSong 重新推送。
  Song? _lastSong;
  List<LyricLine> _lastLines = const [];

  /// 重新推送上次的歌曲（用户切换 preferTranslation 偏好后调用，
  /// 让过滤逻辑立即生效）。
  Future<void> repushLastSong() async {
    if (!enabled) return;
    await setSong(_lastSong, _lastLines);
  }

  /// 由 PlayerProvider 在切歌时调用。
  ///
  /// Lyricon 推荐调用顺序（文档 6.8）：setSong → setPosition → setPlaybackState。
  /// 只调 setSong 不调后两个，Lyricon 中心服务无法确定当前播放进度和状态，
  /// 会导致歌词不渲染、回退显示"作者-歌名"。
  Future<void> onSongChanged(
    Song? song,
    List<LyricLine> lines, {
    int positionMs = 0,
    bool isPlaying = false,
  }) async {
    if (!enabled) return;
    await setSong(song, lines, positionMs: positionMs);
    try {
      // 先推 setPlaybackState 让 Kotlin 端 lyriconIsPlaying 更新为当前曲播放态，
      // 再推 setPosition（其内部用缓存 isPlaying 组装 Auto PlaybackState 基点），
      // 避免切歌后 setPosition 沿用上一曲播放态导致新歌停在原地不推进。
      await _channel.invokeMethod(
        'setPlaybackState',
        {
          // 必须用 PlaybackStateCompat 常量：STATE_PLAYING=3, STATE_PAUSED=2
          // Kotlin 端判断 state==3 推导 isPlaying，传 1 会被当成 STATE_STOPPED→isPlaying=false
          'state': isPlaying ? 3 : 2,
          'position': positionMs,
          'speed': 1.0,
        },
      );
      await _channel.invokeMethod('setPosition', {'positionMs': positionMs});
    } catch (_) {}
  }

  /// 推送一段纯文本（如临时提示）。
  Future<void> sendText(String text) async {
    try {
      await _channel.invokeMethod('sendText', {'text': text});
    } catch (_) {}
  }

  /// 推送当前播放位置（毫秒）。
  Future<void> setPosition(int positionMs) async {
    try {
      // key 必须与 Kotlin 端 MainActivity.kt 的 "setPosition" handler 对齐（期望 "positionMs"）
      await _channel.invokeMethod('setPosition', {'positionMs': positionMs});
    } catch (_) {}
  }

  /// 推送播放状态。
  ///
  /// state 必须用 PlaybackStateCompat 常量：STATE_PLAYING=3, STATE_PAUSED=2。
  /// Kotlin 端判断 state==3 推导 isPlaying，传其他值会被当成 paused。
  Future<void> setPlaybackState({
    required int state,
    required int position,
    required double speed,
  }) async {
    try {
      await _channel.invokeMethod('setPlaybackState', {
        'state': state,
        'position': position,
        'speed': speed,
      });
    } catch (_) {}
  }

  /// 用户拖动进度条时通知 Lyricon 跳转。
  Future<void> seekTo(int positionMs) async {
    try {
      // key 必须与 Kotlin 端 MainActivity.kt 的 "seekTo" handler 对齐（期望 "positionMs"）
      await _channel.invokeMethod('seekTo', {'positionMs': positionMs});
    } catch (_) {}
  }

  /// 切换翻译显示。
  Future<void> setDisplayTranslation(bool enabled) async {
    try {
      await _channel.invokeMethod('setDisplayTranslation', {'enabled': enabled});
    } catch (_) {}
  }

  /// 切换罗马音显示。
  Future<void> setDisplayRoma(bool enabled) async {
    try {
      await _channel.invokeMethod('setDisplayRoma', {'enabled': enabled});
    } catch (_) {}
  }
}

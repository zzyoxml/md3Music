import 'package:flutter/services.dart';

class MediaNotificationService {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_lyric',
  );

  static void Function()? onPrevious;
  static void Function()? onNext;
  static void Function()? onTogglePlayPause;
  static void Function(int)? onSeekTo;
  // 线控耳机媒体键映射的独立播放 / 暂停命令（原生端唤醒播放下发）
  static void Function()? onPlay;
  static void Function()? onPause;
  // 来自通知栏桌面歌词按钮
  static void Function()? onToggleDesktopLyric;
  static void Function()? onToggleFavorite;
  // 来自悬浮窗内按钮：参数为 "lock" / "previous" / "play" / "next" / "settings"
  static void Function(String)? onDesktopLyricAction;
  // 来自悬浮窗内修改配置后回传
  static void Function(Map<dynamic, dynamic>)? onConfigChanged;

  static void initCallbacks() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'previous':
          onPrevious?.call();
          break;
        case 'next':
          onNext?.call();
          break;
        case 'togglePlayPause':
          onTogglePlayPause?.call();
          break;
        case 'play':
          onPlay?.call();
          break;
        case 'pause':
          onPause?.call();
          break;
        case 'seekTo':
          final pos = call.arguments as int?;
          if (pos != null) onSeekTo?.call(pos);
          break;
        case 'toggleDesktopLyric':
          onToggleDesktopLyric?.call();
          break;
        case 'toggleFavorite':
          onToggleFavorite?.call();
          break;
        case 'desktopLyricAction':
          final action = call.arguments as String?;
          if (action != null) onDesktopLyricAction?.call(action);
          break;
        case 'desktopLyricConfigChanged':
          final config = call.arguments as Map<dynamic, dynamic>?;
          if (config != null) onConfigChanged?.call(config);
          break;
      }
      return null;
    });
  }

  static Future<void> updateNotification({
    required String title,
    required String artist,
    String? artUrl,
    String? fallbackFilePath,
    required bool isPlaying,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool desktopLyricEnabled = false,
    bool isFavorited = false,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'fallbackFilePath': fallbackFilePath,
        'isPlaying': isPlaying,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'desktopLyricEnabled': desktopLyricEnabled,
        'isFavorited': isFavorited,
      });
    } catch (_) {}
  }

  static Future<void> hideNotification() async {
    try {
      await _channel.invokeMethod('hideNotification');
    } catch (_) {}
  }

  /// 通知原生端：播放状态已恢复完成，可安全派发线控耳机命令（唤醒播放）。
  /// 原生端 AudioPlaybackService 进程被杀后创建后台 FlutterEngine 并等待该信号
  /// 后才派发 play/next 等命令，确保 PlayerProvider 已完成状态恢复。
  static Future<void> notifyPlayerReady() async {
    try {
      await _channel.invokeMethod('playerReady');
    } catch (_) {}
  }

  // 桌面歌词（悬浮窗）相关
  static Future<bool> hasOverlayPermission() async {
    try {
      final r = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> startFloatingLyric({
    required String lyric,
    required String title,
  }) async {
    try {
      final r = await _channel.invokeMethod<bool>('startFloatingLyric', {
        'lyric': lyric,
        'title': title,
      });
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateLyric(String lyric, {String nextLyric = ''}) async {
    try {
      final r = await _channel.invokeMethod<bool>('updateLyric', {
        'lyric': lyric,
        'nextLyric': nextLyric,
      });
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> updateTitle(String title) async {
    try {
      final r = await _channel.invokeMethod<bool>('updateTitle', {
        'title': title,
      });
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stopFloatingLyric() async {
    try {
      final r = await _channel.invokeMethod<bool>('stopFloatingLyric');
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  // 蓝牙歌词相关：通过修改 MediaSession 元数据（title→歌词，artist→「作者 - 标题」）
  // 在蓝牙 AVRCP 协议下让汽车主机等设备显示当前歌词。
  static Future<void> updateBluetoothLyric(String lyric) async {
    try {
      await _channel.invokeMethod('updateBluetoothLyric', {
        'lyric': lyric,
      });
    } catch (_) {}
  }

  static Future<void> setBluetoothLyricEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setBluetoothLyricEnabled', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  // LyricInfo 歌词转发：把整首歌词（LRC/ELRC JSON）写入 MediaSession extras，
  // 供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  // 传入空字符串表示移除 lyricInfo（切歌/功能关闭时调用）。
  static Future<void> updateLyricInfo(String jsonString) async {
    try {
      await _channel.invokeMethod('updateLyricInfo', {
        'lyricInfo': jsonString,
      });
    } catch (_) {}
  }

  static Future<void> removeLyricInfo() async {
    await updateLyricInfo('');
  }

  // ================= 锁屏歌词 =================
  // 原生侧 LockScreenLyricActivity 覆盖在锁屏上方显示全屏逐字歌词。
  // Dart 端 DesktopLyricService 每 250ms 推送当前行字级数据。

  static Future<void> showLockScreenLyric() async {
    try {
      await _channel.invokeMethod('showLockScreenLyric');
    } catch (_) {}
  }

  static Future<void> hideLockScreenLyric() async {
    try {
      await _channel.invokeMethod('hideLockScreenLyric');
    } catch (_) {}
  }

  /// 推送当前行逐字数据到原生锁屏歌词界面。
  ///
  /// [words]/[wordStartTimes]/[wordDurations] 长度一致；
  /// LRC/纯文本（无逐字）时传空列表，原生侧整行显示。
  /// [artUrl]/[fallbackFilePath] 用于锁屏背景的模糊专辑封面；
  /// [fontSize]/[fontWeight] 同步歌词字号与粗细（与 AM 歌词设置一致）。
  static Future<void> updateLockScreenLyric({
    required String lineText,
    required String prevText,
    required String nextText,
    required List<String> words,
    required List<int> wordStartTimes,
    required List<int> wordDurations,
    required int currentPositionMs,
    required int durationMs,
    required bool isPlaying,
    required String title,
    required String artist,
    String? artUrl,
    String? fallbackFilePath,
    double fontSize = 22,
    int fontWeight = 600,
  }) async {
    try {
      await _channel.invokeMethod('updateLockScreenLyric', {
        'lineText': lineText,
        'prevText': prevText,
        'nextText': nextText,
        'words': words,
        'wordStartTimes': wordStartTimes,
        'wordDurations': wordDurations,
        'currentPositionMs': currentPositionMs,
        'durationMs': durationMs,
        'isPlaying': isPlaying,
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'fallbackFilePath': fallbackFilePath,
        'fontSize': fontSize,
        'fontWeight': fontWeight,
      });
    } catch (_) {}
  }
}

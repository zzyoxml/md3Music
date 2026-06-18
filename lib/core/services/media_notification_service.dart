import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MediaNotificationService {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_lyric',
  );

  static void Function()? onPrevious;
  static void Function()? onNext;
  static void Function()? onTogglePlayPause;
  static void Function(int)? onSeekTo;
  // 来自通知栏桌面歌词按钮
  static void Function()? onToggleDesktopLyric;
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
        case 'seekTo':
          final pos = call.arguments as int?;
          if (pos != null) onSeekTo?.call(pos);
          break;
        case 'toggleDesktopLyric':
          onToggleDesktopLyric?.call();
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
    required bool isPlaying,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool desktopLyricEnabled = false,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'isPlaying': isPlaying,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'desktopLyricEnabled': desktopLyricEnabled,
      });
    } catch (e) {
      debugPrint('MediaNotification update error: $e');
    }
  }

  static Future<void> hideNotification() async {
    try {
      await _channel.invokeMethod('hideNotification');
    } catch (e) {
      // ignore
    }
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
    } catch (e) {
      debugPrint('startFloatingLyric error: $e');
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
}

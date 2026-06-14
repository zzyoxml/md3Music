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
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'isPlaying': isPlaying,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
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
}

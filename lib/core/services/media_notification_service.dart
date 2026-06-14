import 'package:flutter/services.dart';

class MediaNotificationService {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_lyric',
  );

  static Future<void> showNotification({
    required String title,
    required String artist,
    String? artUrl,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'isPlaying': isPlaying,
      });
    } catch (e) {
      // ignore
    }
  }

  static Future<void> updateNotification({
    required String title,
    required String artist,
    String? artUrl,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'isPlaying': isPlaying,
      });
    } catch (e) {
      // ignore
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

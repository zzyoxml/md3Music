import 'package:flutter/services.dart';

class FloatingLyricService {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_lyric',
  );

  static bool _isRunning = false;

  static bool get isRunning => _isRunning;

  static Future<bool> hasOverlayPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> start(String lyric, {String title = ''}) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'startFloatingLyric',
        {'lyric': lyric, 'title': title},
      );
      _isRunning = result ?? false;
      return _isRunning;
    } catch (e) {
      _isRunning = false;
      return false;
    }
  }

  static Future<void> updateLyric(String lyric) async {
    if (!_isRunning) return;
    try {
      await _channel.invokeMethod('updateLyric', {'lyric': lyric});
    } catch (e) {
      // ignore
    }
  }

  static Future<void> updateTitle(String title) async {
    if (!_isRunning) return;
    try {
      await _channel.invokeMethod('updateTitle', {'title': title});
    } catch (e) {
      // ignore
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopFloatingLyric');
    } catch (e) {
      // ignore
    }
    _isRunning = false;
  }

  static Future<void> toggle(String lyric, {String title = ''}) async {
    if (_isRunning) {
      await stop();
    } else {
      await start(lyric, title: title);
    }
  }
}

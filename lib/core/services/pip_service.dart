import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MV 画中画服务：通过原生 MethodChannel 控制 Android 画中画（API 26+）。
///
/// - [enterPip]：手动进入画中画（MV 页画中画按钮）。
/// - [setVideoActive]：标记视频是否播放中 + 视频宽高比，供原生端按 Home 自动进入。
/// - [isPipMode]：当前是否处于画中画模式（原生 onPictureInPictureModeChanged 回调）。
class PipService {
  PipService._();
  static final instance = PipService._();

  static const _channel = MethodChannel('com.md3music.md3music/pip');

  /// 当前是否处于画中画模式（由原生 onPictureInPictureModeChanged 回调）。
  final ValueNotifier<bool> isPipMode = ValueNotifier(false);

  /// 是否已设置原生侧回调监听，避免重复 setMethodCallHandler。
  bool _listening = false;

  void _ensureListener() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        isPipMode.value = call.arguments as bool? ?? false;
      }
    });
  }

  /// 当前设备是否支持画中画（Android 8.0+）。
  Future<bool> isSupported() async {
    _ensureListener();
    try {
      return await _channel.invokeMethod<bool>('isPipSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 手动进入画中画；视频宽高比需已通过 [setVideoActive] 同步给原生端。
  Future<void> enterPip() async {
    _ensureListener();
    try {
      await _channel.invokeMethod('enterPip');
    } catch (_) {}
  }

  /// 标记视频播放状态与宽高比：播放中按 Home 自动进入画中画。
  Future<void> setVideoActive(bool active, {double? aspectRatio}) async {
    try {
      await _channel.invokeMethod('setVideoActive', {
        'active': active,
        if (aspectRatio != null) 'width': (aspectRatio * 1000).round(),
        if (aspectRatio != null) 'height': 1000,
      });
    } catch (_) {}
  }
}

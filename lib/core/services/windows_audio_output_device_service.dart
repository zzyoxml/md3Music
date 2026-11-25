import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_logger.dart';

/// Windows 桌面输出设备选择：设备切换由 just_audio_windows 原生层应用到播放器。
class WindowsAudioOutputDevice {
  const WindowsAudioOutputDevice({
    required this.id,
    required this.name,
    required this.isSystemDefault,
  });

  final String id;
  final String name;
  final bool isSystemDefault;

  factory WindowsAudioOutputDevice.fromMap(Map<Object?, Object?> map) =>
      WindowsAudioOutputDevice(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        isSystemDefault: map['isSystemDefault'] as bool? ?? false,
      );
}

class WindowsAudioOutputDeviceService {
  WindowsAudioOutputDeviceService._();

  static const MethodChannel _channel =
      MethodChannel('md3music/windows_audio_output');
  static const String _preferenceKey = 'windows_audio_output_device_id';

  static Future<List<WindowsAudioOutputDevice>> listDevices() async {
    final rows = await _channel.invokeListMethod<Object?>('listOutputDevices');
    return [
      for (final row in rows ?? const <Object?>[])
        if (row is Map<Object?, Object?>)
          WindowsAudioOutputDevice.fromMap(row),
    ];
  }

  static Future<String?> selectedDeviceId() async =>
      (await SharedPreferences.getInstance()).getString(_preferenceKey);

  static Future<void> selectDevice(String? id) async {
    await _channel.invokeMethod<void>('setOutputDevice', {'deviceId': id});
    final preferences = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await preferences.remove(_preferenceKey);
    } else {
      await preferences.setString(_preferenceKey, id);
    }
    DiagnosticLogger.instance.info(
      '[AudioOutput] selected=${id ?? 'system-default'}',
    );
  }

  /// 播放器初始化后恢复上次选择；设备暂时离线时先用系统默认并等待重连。
  static Future<void> restore() async {
    final id = await selectedDeviceId();
    if (id == null) return;
    try {
      final devices = await listDevices();
      final available = devices.any((device) => device.id == id);
      if (!available) {
        DiagnosticLogger.instance.warning(
          '[AudioOutput] saved endpoint is unavailable; waiting for reconnect',
        );
      }
      // 原生层会在设备未连接时暂用系统默认，并监听端点重新出现后自动切回。
      await _channel.invokeMethod<void>('setOutputDevice', {'deviceId': id});
    } on PlatformException {
      DiagnosticLogger.instance.warning(
        '[AudioOutput] unable to restore the saved endpoint; keeping the preference',
      );
    }
  }
}

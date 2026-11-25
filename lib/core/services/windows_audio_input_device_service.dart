import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_logger.dart';

/// 一个 Windows 录音端点。
class WindowsAudioInputDevice {
  const WindowsAudioInputDevice({
    required this.id,
    required this.name,
    required this.isSystemDefault,
  });

  /// WASAPI 端点 ID，同时也是 MediaFoundation 的 audcap endpoint ID，
  /// 可直接作为 `record` 的 `InputDevice.id`。
  final String id;
  final String name;
  final bool isSystemDefault;

  factory WindowsAudioInputDevice.fromMap(Map<Object?, Object?> map) =>
      WindowsAudioInputDevice(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        isSystemDefault: map['isSystemDefault'] as bool? ?? false,
      );
}

/// 从「设备列表 + 已保存 id」解析当前选择。
///
/// 已保存的设备被拔出/禁用时返回 null —— 语义是「跟随系统默认」，
/// 与输出设备选择（`WindowsAudioOutputDeviceService`）同口径。
WindowsAudioInputDevice? resolveInputDevice(
  List<WindowsAudioInputDevice> devices,
  String? savedId,
) {
  if (savedId == null || savedId.isEmpty) return null;
  for (final device in devices) {
    if (device.id == savedId) return device;
  }
  return null;
}

/// Windows 录音设备枚举与选择。
///
/// 枚举走 runner 原生通道（WASAPI），不依赖 `record` 插件的
/// `listInputDevices`：后者在进程未 `MFStartup` 时拿不到设备
/// （见 `windows/runner/audio_input_devices.h` 的说明）。
class WindowsAudioInputDeviceService {
  WindowsAudioInputDeviceService._();

  static const MethodChannel channel = MethodChannel(
    'md3music/windows_audio_input',
  );
  static const String _preferenceKey = 'windows_audio_input_device_id';

  /// 枚举当前活动录音端点；通道缺失/原生失败时返回空列表，
  /// 调用方按「只有系统默认」渲染。
  static Future<List<WindowsAudioInputDevice>> listDevices() async {
    try {
      final rows = await channel.invokeListMethod<Object?>('listInputDevices');
      return [
        for (final row in rows ?? const <Object?>[])
          if (row is Map<Object?, Object?>)
            WindowsAudioInputDevice.fromMap(row),
      ].where((device) => device.id.isNotEmpty).toList(growable: false);
    } on PlatformException catch (error) {
      DiagnosticLogger.instance.warning(
        '[RecognitionInput] listInputDevices failed: ${error.message}',
      );
      return const <WindowsAudioInputDevice>[];
    } on MissingPluginException {
      DiagnosticLogger.instance.warning(
        '[RecognitionInput] native channel unavailable',
      );
      return const <WindowsAudioInputDevice>[];
    }
  }

  static Future<String?> selectedDeviceId() async =>
      (await SharedPreferences.getInstance()).getString(_preferenceKey);

  /// [id] 为 null 表示跟随系统默认（删除偏好）。
  static Future<void> selectDevice(String? id) async {
    final preferences = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await preferences.remove(_preferenceKey);
    } else {
      await preferences.setString(_preferenceKey, id);
    }
    DiagnosticLogger.instance.info(
      '[RecognitionInput] selected=${id ?? 'system-default'}',
    );
  }
}

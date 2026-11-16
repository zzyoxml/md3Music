import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/repositories/settings_repository.dart';

/// 遥控器模式：TV 版（kTvBuild）D-pad 导航总开关。
///
/// 三态：
/// - auto（默认）：按设备形态自动（TV 设备开、手机/平板关）
/// - always_on   ：强制开启（带键盘的手机/平板也可用）
/// - always_off  ：强制关闭
///
/// 仅 TV 构建注册本 Provider（app.dart 按 kTvBuild 挂载）并安装 Dpad.wrap，
/// 正常构建整体不编入。dpad 的遍历/区域/视觉由 Task 3.3 的 Dpad.wrap 承担，
/// 本 Provider 只负责"要不要启用"。
class RemoteControlProvider extends ChangeNotifier {
  RemoteControlProvider() {
    // 触发异步初始化；UI 侧无需等待，完成后 notifyListeners 驱动刷新。
    unawaited(restored);
  }

  static const MethodChannel _deviceFormChannel = MethodChannel(
    'com.md3music.md3music/device_form',
  );

  /// 'auto' / 'always_on' / 'always_off'
  String _mode = 'auto';

  /// null = 设备形态未知（检测中/检测失败）。
  bool? _isTvDevice;

  /// 异步初始化完成信号（测试用；UI 侧无需 await）。
  Future<void> get restored => _restored;
  late final Future<void> _restored = _restore();

  String get mode => _mode;

  bool get isTvDevice => _isTvDevice ?? false;

  bool get enabled {
    switch (_mode) {
      case 'always_on':
        return true;
      case 'always_off':
        return false;
      default:
        return _isTvDevice ?? false;
    }
  }

  Future<void> _restore() async {
    try {
      final settings = SettingsRepository();
      _mode = await settings.getRemoteControlMode();
      if (_isTvDevice == null) {
        try {
          _isTvDevice =
              await _deviceFormChannel.invokeMethod<bool>('isTv');
        } catch (_) {
          // 通道未实现（正常构建/测试环境）→ 视为非 TV
          _isTvDevice = false;
        }
      }
    } catch (_) {
      // 偏好读取失败保持默认 auto
    }
    notifyListeners();
  }

  Future<void> setMode(String value) async {
    if (_mode == value) return;
    _mode = value;
    await SettingsRepository().setRemoteControlMode(value);
    notifyListeners();
  }
}

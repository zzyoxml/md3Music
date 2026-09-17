import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备类型选择模式。
///
/// - [auto]：按有效视口最短边自动判定（见 `core/layout/responsive_layout.dart`
///   的 `isPadLayout`，>= 600dp → Pad）
/// - [phone]：强制手机模式
/// - [pad]：强制 Pad 模式
enum DeviceType { auto, phone, pad }

class DeviceProvider extends ChangeNotifier {
  static const String _key = 'device_type';

  DeviceType _deviceType = DeviceType.auto;

  DeviceType get deviceType => _deviceType;

  /// 自动检测：物理屏幕最短边 >= 600dp → Pad。
  ///
  /// 只用于设置页展示"自动检测到的设备类型"。**布局判定不要用它** ——
  /// 布局要跟随「显示大小」后的有效视口，走 `isPadLayout(context)`。
  bool _autoDetect() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide >= 600;
  }

  /// 自动检测结果的中文描述（仅在 [deviceType] 为 [DeviceType.auto] 时有意义）。
  String get autoDetectedLabel => _autoDetect() ? 'Pad' : '手机';

  DeviceProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_key) ?? 0;
    _deviceType = DeviceType.values[index.clamp(0, DeviceType.values.length - 1)];
    notifyListeners();
  }

  Future<void> setDeviceType(DeviceType type) async {
    if (_deviceType == type) return;
    _deviceType = type;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, type.index);
  }
}

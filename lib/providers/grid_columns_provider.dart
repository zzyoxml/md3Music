import 'package:flutter/material.dart';

import '../data/repositories/settings_repository.dart';

/// Pad 端网格页面列数偏好的 Provider。
///
/// 仿照 [DeviceProvider] 的写法：构造时从 [SettingsRepository] 异步读取
/// 持久化偏好，列数变化时通知监听器并落盘。捏合手势通过 [increment] /
/// [decrement] 调整列数。
class GridColumnsProvider extends ChangeNotifier {
  static const int minColumns = 2;
  static const int maxColumns = 4;

  // Pad 端默认 4 栏，手机端不使用此值（固定 2 栏）
  int _gridColumns = 4;

  int get gridColumns => _gridColumns;

  GridColumnsProvider() {
    // 仿照 DeviceProvider：构造时异步加载持久化偏好
    loadFromSettings();
  }

  /// 从 [SettingsRepository] 读取列数偏好并初始化。
  Future<void> loadFromSettings() async {
    final count = await SettingsRepository().getGridColumns();
    _gridColumns = count.clamp(minColumns, maxColumns);
    notifyListeners();
  }

  /// 设置列数，范围 [minColumns, maxColumns]，超出自动 clamp。
  /// 仅当值实际变化时通知监听器并持久化。
  void setColumns(int count) {
    final clamped = count.clamp(minColumns, maxColumns);
    if (_gridColumns == clamped) return;
    _gridColumns = clamped;
    notifyListeners();
    SettingsRepository().setGridColumns(clamped);
  }

  /// 列数 +1（上限 [maxColumns]）。
  void increment() => setColumns(_gridColumns + 1);

  /// 列数 -1（下限 [minColumns]）。
  void decrement() => setColumns(_gridColumns - 1);
}

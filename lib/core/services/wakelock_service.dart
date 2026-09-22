import 'package:flutter/services.dart';

import '../../data/repositories/settings_repository.dart';

/// 屏幕常亮服务：根据「设置开关」与「歌曲/MV 播放状态」合并计算是否保持屏幕常亮。
///
/// 通过原生 MethodChannel 调用 [WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON]，
/// 仅在前台生效；暂停或关闭开关后恢复系统默认息屏行为。
class WakelockService {
  WakelockService._();
  static final instance = WakelockService._();

  static const _channel = MethodChannel('com.md3music.md3music/wakelock');

  bool _settingEnabled = false; // 设置开关
  bool _songPlaying = false; // 歌曲正在播放
  bool _videoPlaying = false; // MV 正在播放
  bool _lastApplied = false; // 上次下发给原生的状态，用于去重

  /// 启动时从 SharedPreferences 恢复开关状态。
  Future<void> init() async {
    try {
      _settingEnabled = await SettingsRepository().getKeepScreenOn();
    } catch (_) {}
  }

  /// 设置开关变更（来自设置页）。
  void setSettingEnabled(bool v) {
    if (_settingEnabled == v) return;
    _settingEnabled = v;
    _apply();
  }

  /// 歌曲播放状态变更（来自 PlayerProvider）。
  void setSongPlaying(bool v) {
    if (_songPlaying == v) return;
    _songPlaying = v;
    _apply();
  }

  /// MV 播放状态变更（来自 MvPlayerPage）。
  void setVideoPlaying(bool v) {
    if (_videoPlaying == v) return;
    _videoPlaying = v;
    _apply();
  }

  void _apply() {
    final on = _settingEnabled && (_songPlaying || _videoPlaying);
    if (on == _lastApplied) return;
    _lastApplied = on;
    _channel.invokeMethod('setKeepScreenOn', {'on': on});
  }
}

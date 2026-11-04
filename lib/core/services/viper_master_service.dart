import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/settings_repository.dart';

/// 蝰蛇母带服务：控制挂在 DefaultAudioSink AudioProcessorChain 上的
/// 蝰蛇母带处理链（10 段 EQ + 256 帧联动限幅 + 软削波），
/// 规格对齐 EchoMusic `native/echo-audio-player/src/dsp/basic.rs` 与 `limiter.rs`。
///
/// 关键设计（与 EqualizerService 同风格）：
/// - 单例 ChangeNotifier，经 MethodChannel "com.md3music.md3music/viper_dsp"
///   广播给原生 ViperDspPlugin（主引擎与 headless 播放引擎各注册一次）
/// - 开关持久化在 SettingsRepository；10 段增益存 SharedPreferences（viper_eq_gain_0..9）
/// - 增益钳到 ±12dB；频率固定 31..16k 十段，与原生 ViperMasterChain.BAND_FREQUENCIES 一致
/// - 非 Android 平台 invokeMethod 抛 MissingPluginException，内部吞掉，仅 debugPrint
class ViperMasterService extends ChangeNotifier {
  static final ViperMasterService instance = ViperMasterService._();

  ViperMasterService._();

  static const _channel = MethodChannel('com.md3music.md3music/viper_dsp');

  /// 频段数，必须与原生 ViperMasterProcessor.BAND_COUNT 一致。
  static const int bandCount = 10;

  static const double _maxGainDb = 12.0;

  /// 十段频率（Hz），与原生 ViperMasterChain.BAND_FREQUENCIES 一致。
  static const List<int> bandFrequencies = [
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
  ];

  /// 音效库预设 → 10 段增益曲线（dB）。
  /// 键与 EqualizerService.customPresets 的自定义预设键对齐，
  /// SoundsPage 在母带链开启时按 mapPreset 的返回值路由到这里。
  static const Map<String, List<double>> viperCurves = {
    '正常': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    '流行': [-1, -1, 0, 2, 3, 3, 2, 1, 0, -1],
    '摇滚': [4, 3, 0, -1, 0, 2, 3, 3, 4, 4],
    '爵士': [3, 2, 0, -1, 1, 2, 3, 3, 3, 3],
    '古典': [4, 3, 1, 0, -1, 0, 1, 2, 3, 4],
    '重低音': [6, 5, 3, 1, 0, 0, 0, 0, 1, 1],
    '高音增强': [0, 0, 0, 0, 0, 1, 3, 5, 6, 6],
    '人声': [-2, -1, 0, 2, 4, 4, 3, 1, 0, 0],
    '电子': [4, 3, 0, -2, 0, 1, 2, 3, 4, 4],
  };

  bool _enabled = false;
  List<double> _gains = List.filled(bandCount, 0.0);

  bool get enabled => _enabled;
  List<double> get gains => List.unmodifiable(_gains);

  /// 预设名 → 10 段曲线；未知预设回退「流行」。
  static List<double> curveFor(String preset) =>
      List.unmodifiable(viperCurves[preset] ?? viperCurves['流行']!);

  /// 初始化：恢复开关与频段增益，并把当前状态推给原生处理链。
  /// main.dart 启动时调用；主引擎与 headless 引擎都会执行，推送幂等。
  Future<void> init() async {
    try {
      _enabled = await SettingsRepository().getViperMasterEnabled();
      _gains = List.filled(bandCount, 0.0);
      final prefs = await SharedPreferences.getInstance();
      for (int i = 0; i < bandCount; i++) {
        final v = prefs.getDouble('viper_eq_gain_$i');
        if (v != null && v.isFinite) {
          _gains[i] = v.clamp(-_maxGainDb, _maxGainDb).toDouble();
        }
      }
      await _pushEnabled();
      await _pushGains();
      notifyListeners();
    } catch (e) {
      debugPrint('ViperMasterService init error: $e');
    }
  }

  /// 开关母带处理链；持久化并即时推送原生。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _pushEnabled();
    await SettingsRepository().setViperMasterEnabled(value);
    notifyListeners();
  }

  /// 设置 10 段增益（dB，越界钳到 ±12），持久化并即时推送原生。
  Future<void> setGains(List<double> values) async {
    final next = List.filled(bandCount, 0.0);
    for (int i = 0; i < bandCount && i < values.length; i++) {
      final v = values[i];
      if (v.isFinite) next[i] = v.clamp(-_maxGainDb, _maxGainDb).toDouble();
    }
    _gains = next;
    await _pushGains();
    final prefs = await SharedPreferences.getInstance();
    for (int i = 0; i < bandCount; i++) {
      await prefs.setDouble('viper_eq_gain_$i', _gains[i]);
    }
    notifyListeners();
  }

  /// 应用预设曲线（键见 [viperCurves]）。
  Future<void> applyPreset(String name) => setGains(curveFor(name));

  Future<void> _pushEnabled() async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': _enabled});
    } catch (e) {
      debugPrint('ViperMaster setEnabled error: $e');
    }
  }

  Future<void> _pushGains() async {
    try {
      await _channel.invokeMethod('setEqGains', {'gains': _gains});
    } catch (e) {
      debugPrint('ViperMaster setEqGains error: $e');
    }
  }
}

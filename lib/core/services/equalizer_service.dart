import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_service.dart';

/// 均衡器服务：通过 Android 原生 Equalizer API 实现音频均衡器。
///
/// 关键设计：
/// - 单例 ChangeNotifier，通过 MethodChannel 与原生 EqualizerPlugin 通信
/// - 频段数和频率由设备硬件决定（通常 5 段）
/// - 增益单位为 millibel (mB)，范围由设备决定（通常 ±1500 mB = ±15 dB）
/// - 自定义预设按 5 个频率区域定义（bass/lowmid/mid/highmid/treble），
///   应用时根据设备实际频段频率映射到最接近的区域
/// - 绑定到 just_audio 的 audio session ID，仅在播放歌曲后可用
/// - 4 秒超时保护（原生端实现）
class EqualizerService extends ChangeNotifier {
  static final EqualizerService instance = EqualizerService._();

  EqualizerService._();

  static const _channel = MethodChannel('com.md3music.md3music/equalizer');

  // 频率区域边界（Hz），用于将设备频段映射到预设的 5 个区域
  static const _zoneBoundaries = [250.0, 500.0, 2000.0, 6000.0];

  /// 自定义预设（dB 值，5 个区域：bass/lowmid/mid/highmid/treble）
  static const Map<String, List<double>> customPresets = {
    '正常': [0, 0, 0, 0, 0],
    '流行': [-1, 2, 4, 2, -1],
    '摇滚': [4, -1, 0, 3, 4],
    '爵士': [3, 2, -1, 1, 3],
    '古典': [4, 0, -1, 2, 4],
    '重低音': [6, 0, 0, 0, 0],
    '高音增强': [0, 0, 0, 4, 6],
    '人声': [-2, 2, 4, 3, -1],
    '电子': [4, -2, 0, 3, 5],
  };

  bool _enabled = false;
  bool _isBound = false;
  bool _isBinding = false;

  int _bandCount = 0;
  int _minLevel = 0; // mB
  int _maxLevel = 0; // mB
  List<int> _centerFreqs = []; // milliHz
  List<int> _bandLevels = []; // mB
  List<String> _systemPresets = [];
  String _currentPreset = '正常';

  bool get enabled => _enabled;
  bool get isBound => _isBound;
  bool get isBinding => _isBinding;
  int get bandCount => _bandCount;
  int get minLevel => _minLevel;
  int get maxLevel => _maxLevel;
  int get minDb => (_minLevel / 100).round();
  int get maxDb => (_maxLevel / 100).round();
  List<int> get centerFreqs => List.unmodifiable(_centerFreqs);
  List<int> get bandLevels => List.unmodifiable(_bandLevels);
  List<String> get systemPresets => List.unmodifiable(_systemPresets);
  String get currentPreset => _currentPreset;

  /// 所有可选预设名（自定义 + 系统）
  List<String> get allPresetNames => [
        ...customPresets.keys,
        ..._systemPresets.where((p) => !customPresets.containsKey(p)),
      ];

  StreamSubscription<bool>? _playingSub;

  /// 初始化：从 SharedPreferences 恢复设置。
  /// 不绑定音频会话（需等播放器就绪后调用 [tryBind]）。
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('eq_enabled') ?? false;
      _currentPreset = prefs.getString('eq_preset') ?? '正常';

      // 恢复保存的频段增益（mB），实际频段数在绑定后才知道
      // 先读取已保存的值，绑定后按实际频段数应用
      _savedBandLevels = _loadSavedBandLevels(prefs);

      // 监听播放状态，播放时自动绑定
      _playingSub?.cancel();
      _playingSub = AudioService().playingStream.listen((playing) {
        if (playing && !_isBound && !_isBinding) {
          tryBind();
        }
      });

      notifyListeners();
    } catch (e) {
      debugPrint('EqualizerService init error: $e');
    }
  }

  List<int> _savedBandLevels = [];

  List<int> _loadSavedBandLevels(SharedPreferences prefs) {
    final levels = <int>[];
    for (int i = 0; i < 16; i++) {
      final val = prefs.getInt('eq_band_level_$i');
      if (val != null) {
        levels.add(val);
      } else {
        break;
      }
    }
    return levels;
  }

  /// 尝试绑定到 just_audio 的 audio session ID。
  /// 返回 true 表示绑定成功。
  Future<bool> tryBind() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    if (_isBound || _isBinding) return _isBound;

    final sessionId = AudioService().androidAudioSessionId;
    if (sessionId == null || sessionId == 0) return false;

    _isBinding = true;
    notifyListeners();

    try {
      final result = await _channel.invokeMethod<Map>('init', {
        'audioSessionId': sessionId,
      });

      if (result == null) {
        _isBinding = false;
        notifyListeners();
        return false;
      }

      _bandCount = result['bandCount'] as int? ?? 0;
      _minLevel = result['minLevel'] as int? ?? 0;
      _maxLevel = result['maxLevel'] as int? ?? 0;
      _centerFreqs = (result['centerFreqs'] as List?)?.cast<int>() ?? [];
      _bandLevels = List.filled(_bandCount, 0);

      // 获取系统预设
      try {
        final presets = await _channel.invokeMethod<List>('getPresets');
        _systemPresets = presets?.cast<String>() ?? [];
      } catch (_) {
        _systemPresets = [];
      }

      _isBound = true;
      _isBinding = false;

      // 应用已保存的设置
      if (_enabled) {
        await _channel.invokeMethod('setEnabled', {'enabled': true});
      }

      // 应用预设或保存的频段
      if (_currentPreset == '自定义' && _savedBandLevels.isNotEmpty) {
        // 恢复用户自定义的频段增益
        for (int i = 0; i < _bandCount && i < _savedBandLevels.length; i++) {
          final level = _savedBandLevels[i].clamp(_minLevel, _maxLevel);
          _bandLevels[i] = level;
          if (_enabled) {
            await _channel.invokeMethod('setBandLevel', {
              'band': i,
              'level': level,
            });
          }
        }
      } else if (customPresets.containsKey(_currentPreset)) {
        await _applyCustomPreset(_currentPreset);
      }

      notifyListeners();
      return true;
    } on PlatformException catch (e) {
      debugPrint('Equalizer bind failed: ${e.code} - ${e.message}');
      _isBinding = false;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('Equalizer bind error: $e');
      _isBinding = false;
      notifyListeners();
      return false;
    }
  }

  /// 解绑（释放原生 Equalizer）
  Future<void> unbind() async {
    if (!_isBound) return;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
    _isBound = false;
    _bandCount = 0;
    _bandLevels = [];
    _centerFreqs = [];
    _systemPresets = [];
    notifyListeners();
  }

  /// 设置均衡器开关
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (_isBound) {
      try {
        await _channel.invokeMethod('setEnabled', {'enabled': value});
      } catch (e) {
        debugPrint('Equalizer setEnabled error: $e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('eq_enabled', value);
    notifyListeners();
  }

  /// 设置指定频段增益（mB）。
  /// notifyListeners 在 async 操作前同步调用，确保滑块拖动时 UI 即时响应。
  Future<void> setBandLevel(int band, int levelMb) async {
    if (band < 0 || band >= _bandCount) return;
    final clamped = levelMb.clamp(_minLevel, _maxLevel);
    _bandLevels[band] = clamped;
    _currentPreset = '自定义';
    notifyListeners();

    // 原生调用 + 持久化（异步，不阻塞 UI）
    if (_isBound && _enabled) {
      try {
        await _channel.invokeMethod('setBandLevel', {
          'band': band,
          'level': clamped,
        });
      } catch (e) {
        debugPrint('Equalizer setBandLevel error: $e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('eq_band_level_$band', clamped);
    await prefs.setString('eq_preset', '自定义');
  }

  /// 应用预设
  Future<void> applyPreset(String name) async {
    _currentPreset = name;

    if (customPresets.containsKey(name)) {
      await _applyCustomPreset(name);
    } else if (_systemPresets.contains(name)) {
      // 系统预设
      final index = _systemPresets.indexOf(name);
      if (_isBound) {
        try {
          await _channel.invokeMethod('usePreset', {'preset': index});
          // 读取应用后的频段值
          final info = await _channel.invokeMethod<Map>('getBandInfo');
          if (info != null) {
            _bandLevels = (info['bandLevels'] as List?)?.cast<int>() ??
                List.filled(_bandCount, 0);
          }
        } catch (e) {
          debugPrint('Equalizer usePreset error: $e');
        }
      }
    }

    // 持久化
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('eq_preset', name);
    // 保存当前频段值
    for (int i = 0; i < _bandLevels.length; i++) {
      await prefs.setInt('eq_band_level_$i', _bandLevels[i]);
    }
    notifyListeners();
  }

  /// 将自定义预设（5 区域 dB 值）映射到设备实际频段并应用
  Future<void> _applyCustomPreset(String name) async {
    final presetDb = customPresets[name]!;
    if (_bandCount == 0) return;

    for (int i = 0; i < _bandCount; i++) {
      final zoneIndex = _freqToZoneIndex(_centerFreqs[i]);
      final db = presetDb[zoneIndex];
      final levelMb = (db * 100).round().clamp(_minLevel, _maxLevel);
      _bandLevels[i] = levelMb;

      if (_isBound && _enabled) {
        try {
          await _channel.invokeMethod('setBandLevel', {
            'band': i,
            'level': levelMb,
          });
        } catch (e) {
          debugPrint('Equalizer setBandLevel error: $e');
        }
      }
    }
  }

  /// 将频率（milliHz）映射到 5 个区域索引（0-4）
  int _freqToZoneIndex(int milliHz) {
    final hz = milliHz / 1000.0;
    for (int i = 0; i < _zoneBoundaries.length; i++) {
      if (hz < _zoneBoundaries[i]) return i;
    }
    return _zoneBoundaries.length; // treble
  }

  /// 重置所有频段为 0 dB
  Future<void> reset() async {
    for (int i = 0; i < _bandCount; i++) {
      _bandLevels[i] = 0;
      if (_isBound && _enabled) {
        try {
          await _channel.invokeMethod('setBandLevel', {
            'band': i,
            'level': 0,
          });
        } catch (e) {
          debugPrint('Equalizer reset band error: $e');
        }
      }
    }
    _currentPreset = '正常';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('eq_preset', '正常');
    for (int i = 0; i < _bandLevels.length; i++) {
      await prefs.setInt('eq_band_level_$i', 0);
    }
    notifyListeners();
  }

  /// 格式化频率显示：60000 mHz → "60Hz", 1000000 mHz → "1k", 14000000 mHz → "14k"
  static String formatFreq(int milliHz) {
    final hz = milliHz / 1000.0;
    if (hz >= 1000) {
      final khz = hz / 1000.0;
      return khz == khz.roundToDouble()
          ? '${khz.round()}k'
          : '${khz.toStringAsFixed(1)}k';
    }
    return '${hz.round()}Hz';
  }

  /// 将 mB 转换为 dB 显示值
  static double mbToDb(int mb) => mb / 100.0;

  /// 将 dB 转换为 mB
  static int dbToMb(double db) => (db * 100).round();

  @override
  void dispose() {
    _playingSub?.cancel();
    super.dispose();
  }
}

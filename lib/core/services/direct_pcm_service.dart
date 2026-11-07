import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_capabilities.dart';
import 'usb_audio_service.dart';

/// 系统 Direct PCM 输出服务：封装原生 MethodChannel
/// `com.md3music.md3music/direct_pcm`。
///
/// 与 [UsbAudioService] 的分工（互斥，由 `OutputModeCoordinator` 的两层开关仲裁）：
/// - [UsbAudioService] 负责 usbdevfs 直写的**独占**模式（音质最好、兼容性最差）
/// - 本服务负责**系统 Direct PCM** 模式（仍走系统 AudioTrack，但强制高规格编码 +
///   fast 通道 + 效果链旁路，兼容性最好）
///
/// 两者都挂在同一个「USB 独占输出」总开关下（外层），由内层「改用系统 Direct PCM」
/// 选哪一种；总开关关闭即系统默认。
///
/// 效果链旁路的原值保存/恢复、以及直写失败后关闭总开关，都在
/// `OutputModeCoordinator`；本服务只负责「与原生对话」+「子开关持久化」。
class DirectPcmService {
  DirectPcmService._();

  static final DirectPcmService instance = DirectPcmService._();

  static const MethodChannel _channel =
      MethodChannel('com.md3music.md3music/direct_pcm');

  static const String _tag = 'DirectPcmService';

  bool _inited = false;

  /// 原生侧当前是否处于 Direct PCM 模式。
  bool _enabled = false;

  /// 各子开关的用户原始值（未经平台门控），key = `DirectPcmFeature.specKey`。
  final Map<String, bool> _featureUserValues = <String, bool>{};

  Map<String, dynamic> _lastStatus = const <String, dynamic>{};

  final StreamController<Map<String, dynamic>> _statusController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 原生事件推送（设备插拔、路由变化、状态更新）。
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  /// 最近一次事件/查询到的状态快照。
  Map<String, dynamic> get lastStatus => _lastStatus;

  /// 当前是否处于 Direct PCM 模式（与原生一致）。
  bool get isEnabled => _enabled;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 读取某子开关的**用户原始值**（未做平台门控）。
  bool featureUserValue(DirectPcmFeature feature) {
    return _featureUserValues[feature.specKey] ?? feature.defaultOn;
  }

  /// 读取某子开关的**生效值**（用户值 && 平台满足要求）。
  bool featureEffective(DirectPcmFeature feature) {
    return DeviceCapabilities.instance
        .effective(feature, featureUserValue(feature));
  }

  /// 订阅原生事件 + 恢复持久化状态（幂等）。App 启动时调用一次。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (e) {
      debugPrint('[$_tag] setMethodCallHandler 失败: $e');
    }
    await DeviceCapabilities.instance.ensureLoaded();
    await _restoreFeatures();
    await refresh();
    if (_enabled) await pushFeatures();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onStatusChanged') {
      final args = call.arguments;
      if (args is Map) _applyStatus(Map<String, dynamic>.from(args));
      if (!_statusController.isClosed) _statusController.add(_lastStatus);
      return null;
    }
    return null;
  }

  void _applyStatus(Map<String, dynamic> status) {
    _lastStatus = status;
    final enabled = status['enabled'];
    if (enabled is bool) _enabled = enabled;
  }

  Future<void> _restoreFeatures() async {
    for (final DirectPcmFeature f in DirectPcmFeature.values) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _featureUserValues[f.specKey] =
            prefs.getBool(f.specKey) ?? f.defaultOn;
      } catch (e) {
        _featureUserValues[f.specKey] = f.defaultOn;
      }
    }
  }

  /// 主动查询一次原生状态（启动/页面可见时兜底）。
  Future<Map<String, dynamic>> refresh() async {
    if (!_isAndroid) return _lastStatus;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (result != null) _applyStatus(result);
    } catch (e) {
      debugPrint('[$_tag] getStatus 失败: $e');
    }
    return _lastStatus;
  }

  /// 开关 Direct PCM 模式。实际生效需重配 sink，由调用方（协调器）触发重建。
  Future<void> setEnabled(bool value) async {
    if (!_isAndroid) return;
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('setEnabled', {
        'enabled': value,
      });
      if (result != null) _applyStatus(result);
      _enabled = value;
    } catch (e) {
      debugPrint('[$_tag] setEnabled($value) 失败: $e');
    }
  }

  /// 写入某子开关的用户值并推给原生。
  Future<void> setFeature(DirectPcmFeature feature, bool value) async {
    _featureUserValues[feature.specKey] = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(feature.specKey, value);
    } catch (e) {
      debugPrint('[$_tag] 持久化 ${feature.specKey} 失败: $e');
    }
    if (_isAndroid && _enabled) {
      try {
        await _channel.invokeMethod('setFeature', {
          'feature': feature.specKey,
          'enabled': featureEffective(feature),
        });
      } catch (e) {
        debugPrint('[$_tag] setFeature(${feature.specKey}) 失败: $e');
      }
    }
  }

  /// 把全部子开关的**生效值**（已做平台门控）推给原生。
  ///
  /// 必须在每次切换 Direct PCM 档位时调用（不只是 init）：原生侧的
  /// `DirectPcmController` 启动时 features 全为 false，若不推，
  /// `isHighPrecisionOutputEnabled()` / `isLowLatencyEnabled()` /
  /// `isDspBypassEnabled()` / `isUnityVolumeEnabled()` 会全部返回 false，
  /// 表现为「高规格输出/低延迟/unity 音量/效果链旁路」四个开关都不生效。
  Future<void> pushFeatures() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setFeatures', {
        'features': <String, bool>{
          for (final DirectPcmFeature f in DirectPcmFeature.values)
            f.specKey: featureEffective(f),
        },
      });
    } catch (e) {
      debugPrint('[$_tag] setFeatures 失败: $e');
    }
  }

  /// 设备与输出能力快照（原生支持率列表、当前路由、fast 通道相关属性）。
  Future<Map<String, dynamic>> getDeviceInfo() async {
    if (!_isAndroid) return const <String, dynamic>{};
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      return result ?? const <String, dynamic>{};
    } catch (e) {
      debugPrint('[$_tag] getDeviceInfo 失败: $e');
      return const <String, dynamic>{};
    }
  }

  /// 原生环形日志（诊断导出用，形态对齐 `UsbLog.exportAll()`）。
  Future<String> getLogs() async {
    if (!_isAndroid) return '';
    try {
      return await _channel.invokeMethod<String>('getLogs') ?? '';
    } catch (e) {
      debugPrint('[$_tag] getLogs 失败: $e');
      return '';
    }
  }

  /// 导出诊断文本（供 `DiagnosticExporter` 写文件）。
  String exportDiagnostics() {
    return const JsonEncoder.withIndent('  ').convert(_lastStatus);
  }

  void dispose() {
    if (!_statusController.isClosed) _statusController.close();
  }
}

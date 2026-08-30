import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// USB 独占输出服务：封装原生 MethodChannel "com.md3music.md3music/usb_audio"。
///
/// 提供：
/// - 开关：enableExclusive / disableExclusive（原生负责授权、开设备、xHCI 时序）
/// - 查询：listDevices / getStatus / getFormatInfo / isEnabled
/// - 实时状态：原生事件推送（ATTACHED/DETACHED/enable/disable 完成点），通过
///   [statusStream] 广播（设置页/歌曲信息页共用）；启动/页面可见时主动查一次兜底
///
/// Debug 约定：所有关键路径输出 `[UsbAudio]` 前缀日志，便于 logcat 过滤排查。
class UsbAudioService {
  UsbAudioService._();

  static final UsbAudioService instance = UsbAudioService._();

  static const MethodChannel _channel =
      MethodChannel('com.md3music.md3music/usb_audio');

  static const String _tag = 'UsbAudioService';
  static const String _keyAutoDisableForMv = 'usb_auto_disable_for_mv';
  static const String _keyEnable32bit = 'enable_32bit_output';

  final StreamController<Map<String, dynamic>> _statusController =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> _lastStatus = const {};
  bool _inited = false;

  /// 独占从开启→关闭的回调（Dart 侧 PlayerProvider 用它自动恢复 delegate 输出：
  /// 旧 usb HAL 输出流被独占 force disconnect 杀死，需重建 AudioTrack 才能重新出声）。
  void Function()? onExclusiveDisabled;

  /// USB 独占独立音量（0..100），独立持久化（key: usb_volume），仅独占生效。
  double _usbVolumePercent = 100;

  /// USB 音量（0..100），与应用内/系统音量分开记忆。
  double get usbVolumePercent => _usbVolumePercent;

  /// 实时状态流（原生事件推送驱动，稀疏事件）。
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  /// 最近一次事件/查询到的状态。
  Map<String, dynamic> get lastStatus => _lastStatus;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// 订阅原生事件 + 启动时主动查一次（幂等）。App 启动时调用一次。
  void init() {
    if (_inited) return;
    _inited = true;
    if (!_isAndroid) {
      _debug('init skipped (non-Android)');
      return;
    }
    _debug('init: subscribe events + one-shot refresh');
    _channel.setMethodCallHandler(_handleNativeCall);
    // 兜底 c：冷启动先查一次，立即填充 lastStatus（页面首帧即可读）
    refresh();
    // 恢复 USB 独占独立音量（App 重启后保留）
    initUsbVolume();
    // 恢复 32bit 播放开关并下发原生（默认关闭，确保首次播放即按用户选择）
    initEnable32bit();
  }

  /// 从 SharedPreferences 恢复 USB 音量并下发到原生（幂等，可重复调用）。
  Future<void> initUsbVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _usbVolumePercent = (prefs.getDouble('usb_volume') ?? 100).clamp(0.0, 100.0);
      await _channel.invokeMethod('setUsbVolume', {'percent': _usbVolumePercent});
      _debug('initUsbVolume: restored $_usbVolumePercent%');
    } catch (e) {
      _debug('initUsbVolume failed: $e');
    }
  }

  /// 设置 USB 独占独立音量（0..100），实时生效并持久化（重启保留）。
  Future<void> setUsbVolume(double percent) async {
    _usbVolumePercent = percent.clamp(0.0, 100.0);
    try {
      await _channel.invokeMethod('setUsbVolume', {'percent': _usbVolumePercent});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('usb_volume', _usbVolumePercent);
      // slider 拖动高频场景走本地即时广播（原生不为此推送事件）
      _emit(_lastStatus);
      _debug('setUsbVolume: $_usbVolumePercent% (persisted)');
    } catch (e) {
      _debug('setUsbVolume failed: $e');
    }
  }

  /// 「播放 MV 时自动关闭独占」开关（默认开启）：
  /// USB 独占绕过 AudioFlinger，MV 播放无系统音频，开启后进入 MV 页自动关闭独占。
  Future<bool> getAutoDisableForMv() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyAutoDisableForMv) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setAutoDisableForMv(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoDisableForMv, value);
    } catch (_) {}
  }

  // ── 32bit 播放支持开关（默认关闭，无损坏风险） ─────────────────
  /// 是否开启 32bit(float 高解析)输出。默认关闭；开启后部分设备可能变速/变调，需用户自担。
  bool _enable32bit = false;
  bool get enable32bit => _enable32bit;

  /// 启动/进入设置页时恢复持久化的 32bit 开关并下发到原生（幂等）。
  Future<void> initEnable32bit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enable32bit = prefs.getBool(_keyEnable32bit) ?? false;
      await _channel.invokeMethod('setFloatOutputEnabled', {'enabled': _enable32bit});
      _debug('initEnable32bit: $_enable32bit');
    } catch (e) {
      _debug('initEnable32bit failed: $e');
    }
  }

  /// 设置 32bit 播放开关：持久化 + 下发原生。切歌后生效。
  Future<void> setEnable32bit(bool value) async {
    _enable32bit = value;
    try {
      await _channel.invokeMethod('setFloatOutputEnabled', {'enabled': value});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyEnable32bit, value);
      _debug('setEnable32bit: $value (persisted, next track applies)');
    } catch (e) {
      _debug('setEnable32bit failed: $e');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _inited = false;
  }

  /// 统一状态出口：更新 lastStatus + 广播到 statusStream（保留原有变化日志）。
  void _emit(Map<String, dynamic> status) {
    final prev = _lastStatus;
    _lastStatus = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
    // 状态变化 debug 日志（便于排查：开关切换/拔插/采样率切换）
    final prevEnabled = prev['enabled'] == true;
    final nowEnabled = status['enabled'] == true;
    if (prevEnabled != nowEnabled) {
      _debug('status: enabled $prevEnabled → $nowEnabled');
      if (prevEnabled && !nowEnabled) {
        // 独占关闭：通知 PlayerProvider 恢复 delegate 输出（重建 AudioTrack）
        onExclusiveDisabled?.call();
      }
    }
    if (nowEnabled) {
      final prevConn = prev['deviceConnected'] == true;
      final nowConn = status['deviceConnected'] == true;
      if (prevConn != nowConn) {
        _debug('status: deviceConnected $prevConn → $nowConn (${nowConn ? 'attached' : 'detached'})');
      }
    }
  }

  /// 接收原生 onStatusChanged 事件（ATTACHED/DETACHED/enable/disable 完成点推送）。
  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onStatusChanged') return;
    try {
      final s = Map<String, dynamic>.from(
        (call.arguments as Map?) ?? const <String, dynamic>{},
      );
      if (s.isNotEmpty) _emit(s);
    } catch (e) {
      _debug('onStatusChanged parse failed: $e');
    }
  }

  /// 主动查询一次并广播（兜底 c：启动 / 页面可见时调用）。
  Future<void> refresh() async {
    final s = await getStatus();
    if (s.isNotEmpty) _emit(s);
  }

  // ── MethodChannel 封装 ────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listDevices() async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('listDevices');
      return (list ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _debug('listDevices failed: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> getStatus() async {
    try {
      final s = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (s != null) _lastStatus = s;
      return s ?? const {};
    } catch (e) {
      _debug('getStatus failed: $e');
      return const {};
    }
  }

  /// 当前解码输出格式：{sampleRate, channelCount, encoding, hasData}。
  Future<Map<String, dynamic>> getFormatInfo() async {
    try {
      final f = await _channel.invokeMapMethod<String, dynamic>('getFormatInfo');
      return f ?? const {};
    } catch (e) {
      _debug('getFormatInfo failed: $e');
      return const {};
    }
  }

  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (e) {
      _debug('isEnabled failed: $e');
      return false;
    }
  }

  /// 开启 USB 独占。成功返回最新状态；失败抛出 [UsbAudioException]。
  /// 状态广播由原生 pushStatus() 推送（同一份状态），此处只同步 _lastStatus。
  Future<Map<String, dynamic>> enableExclusive() async {
    _debug('enableExclusive()');
    try {
      final s = await _channel.invokeMapMethod<String, dynamic>('enableExclusive');
      if (s != null) _lastStatus = s;
      _debug('enableExclusive → ${_statusSummary(s ?? const {})}');
      return s ?? const {};
    } on PlatformException catch (e) {
      _debug('enableExclusive error: ${e.code} ${e.message}');
      throw UsbAudioException(e.code, e.message ?? '开启失败');
    } catch (e) {
      _debug('enableExclusive error: $e');
      throw UsbAudioException('ENABLE_FAILED', '开启失败: $e');
    }
  }

  /// 关闭 USB 独占。成功返回最新状态；状态广播由原生 pushStatus() 推送。
  Future<Map<String, dynamic>> disableExclusive() async {
    _debug('disableExclusive()');
    try {
      final s = await _channel.invokeMapMethod<String, dynamic>('disableExclusive');
      if (s != null) _lastStatus = s;
      _debug('disableExclusive → ${_statusSummary(s ?? const {})}');
      return s ?? const {};
    } catch (e) {
      _debug('disableExclusive failed: $e');
      return const {};
    }
  }

  // ── 工具 ──────────────────────────────────────────────────────

  void _debug(String msg) {
    // ignore: avoid_print
    print('[$_tag] $msg');
  }

  String _statusSummary(Map<String, dynamic> s) {
    return jsonEncode(s);
  }
}

/// USB 独占操作失败（code 对应原生 errorCode，如 NO_DEVICE / PERMISSION_DENIED）。
class UsbAudioException implements Exception {
  final String code;
  final String message;
  UsbAudioException(this.code, this.message);

  @override
  String toString() => 'UsbAudioException($code): $message';
}

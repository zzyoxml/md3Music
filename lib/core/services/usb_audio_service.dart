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
/// - 实时状态：每秒轮询 getStatus，通过 [statusStream] 广播（设置页/歌曲信息页共用）
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

  Timer? _pollTimer;
  Map<String, dynamic> _lastStatus = const {};
  bool _inited = false;
  String _lastPollError = '';

  /// USB 独占独立音量（0..100），独立持久化（key: usb_volume），仅独占生效。
  double _usbVolumePercent = 100;

  /// USB 音量（0..100），与应用内/系统音量分开记忆。
  double get usbVolumePercent => _usbVolumePercent;

  /// 实时状态流（每秒一帧）。
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  /// 最近一次轮询到的状态。
  Map<String, dynamic> get lastStatus => _lastStatus;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// 启动轮询（幂等）。App 启动时调用一次。
  void init() {
    if (_inited) return;
    _inited = true;
    if (!_isAndroid) {
      _debug('init skipped (non-Android)');
      return;
    }
    _debug('init: start polling (1s)');
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
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
    _pollTimer?.cancel();
    _pollTimer = null;
    _inited = false;
  }

  Future<void> _poll() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (status == null) return;
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
      }
      if (nowEnabled) {
        final prevConn = prev['deviceConnected'] == true;
        final nowConn = status['deviceConnected'] == true;
        if (prevConn != nowConn) {
          _debug('status: deviceConnected $prevConn → $nowConn (${nowConn ? 'attached' : 'detached'})');
        }
      }
    } catch (e) {
      // 错误日志节流：同一错误只打印一次，避免后台 isolate 每秒刷屏
      final err = e.toString();
      if (err != _lastPollError) {
        _lastPollError = err;
        _debug('poll failed: $err');
      }
    }
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

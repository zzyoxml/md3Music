import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 频谱可视化服务：单例，桥接 Kotlin [SpectrumPlugin] 的 FFT 数据流。
///
/// **双模式设计**（兼容 HyperOS 等禁用 Visualizer 的 ROM）：
/// - **真实模式**：通过 MethodChannel 接收原生 Visualizer 的 FFT 回调
/// - **模拟模式**：Visualizer 不可用时，用 sin 波动 + 随机化生成装饰性频谱数据
///
/// 调用 [start] 后自动尝试真实模式；若 1.5 秒内未收到 FFT 回调，自动降级到模拟模式。
/// 收到真实 FFT 回调后自动切换回真实模式。
///
/// 模拟模式视觉上跟随播放节奏（播放时跳动、暂停时静止），但不反映真实音频频谱。
class SpectrumService {
  SpectrumService._();
  static final SpectrumService instance = SpectrumService._();

  static const String _channelName = 'com.md3music.md3music/spectrum';

  final MethodChannel _channel = const MethodChannel(_channelName);

  /// 用户可配置的频谱柱数量（默认 40，范围 20~80）。
  /// 原生端固定采集 40 段，Dart 端根据此值做线性重采样。
  int bandCount = 40;

  /// 频谱数据广播流：每个元素是 [bandCount] 段归一化幅值（0..1）。
  /// 同步分发（sync:true）：listener 在 add() 调用期间同步消费数据，
  /// 从而允许复用输出缓冲（见 [_outBuf]），避免每帧分配新 List。
  final StreamController<List<double>> _controller =
      StreamController<List<double>>.broadcast(sync: true);

  Stream<List<double>> get spectrumStream => _controller.stream;

  bool _running = false;
  bool get isRunning => _running;

  /// 是否正在使用模拟模式（Visualizer 不可用时的降级方案）
  bool _simulated = false;
  bool get isSimulated => _simulated;

  /// 模拟模式状态变化通知（UI 层监听后显示 SnackBar）
  final ValueNotifier<bool> simulatedNotifier = ValueNotifier<bool>(false);

  bool _handlerRegistered = false;

  // ── 模拟模式相关 ──
  Timer? _simulateTimer;
  Timer? _fallbackTimer;
  double _simulateTime = 0;
  final math.Random _rng = math.Random();
  // 每根柱的相位偏移，让模拟频谱更自然（按最大 bandCount 生成，运行时取模索引）
  late final List<double> _phases = List.generate(
    80,
    (i) => i * 0.3 + _rng.nextDouble() * 0.5,
  );
  // 每根柱的随机衰减系数，模拟不同频段的响应差异
  late final List<double> _decays = List.generate(
    80,
    (i) => 0.5 + 0.5 * math.exp(-i * 0.05) + _rng.nextDouble() * 0.2,
  );

  // 复用输出缓冲：避免每帧分配新 List（broadcast 流同步分发，复用安全）
  List<double> _outBuf = List.filled(0, 0.0);
  List<double> _nativeBuf = List.filled(0, 0.0);

  /// 当前播放状态（模拟模式用：播放时生成数据，暂停时静止）
  bool _isPlaying = false;

  /// 启动频谱采集。返回 true 表示服务已运行（真实或模拟模式）。
  Future<bool> start([int? audioSessionId]) async {
    if (!Platform.isAndroid) {
      // 非 Android 平台直接用模拟模式
      _startSimulated();
      return true;
    }
    if (_running) return true;

    // 懒注册 MethodChannel handler
    if (!_handlerRegistered) {
      _channel.setMethodCallHandler(_handleMethodCall);
      _handlerRegistered = true;
    }

    // 尝试启动原生 Visualizer
    bool nativeOk = false;
    try {
      final ok = await _channel.invokeMethod<bool>('start', {
        'audioSessionId': audioSessionId ?? 0,
      });
      nativeOk = ok ?? false;
    } on PlatformException catch (_) {
      nativeOk = false;
    }

    _running = true;

    if (nativeOk) {
      // 原生启动成功，等 1.5 秒看是否有 FFT 回调；无回调则降级到模拟模式
      _fallbackTimer?.cancel();
      _fallbackTimer = Timer(const Duration(milliseconds: 1500), () {
        if (_running && !_receivedFft) {
          // 1.5 秒内无 FFT 回调，降级到模拟模式
          _startSimulated();
        }
      });
    } else {
      // 原生启动失败（如 HyperOS error -3），直接用模拟模式
      _startSimulated();
    }

    return true;
  }

  bool _receivedFft = false;

  /// 暂停门控：暂停时强制频谱复位为 0。
  /// 原因：ExoPlayer 暂停时会 flush 剩余 PCM（尾音），handleBuffer 仍被调用，
  /// 真实 FFT 数据继续到达导致暂停时频谱抽搐。暂停时置 true，丢弃真实数据发全 0。
  bool _gateZero = false;

  /// 设置播放状态（模拟模式用）
  void setPlaying(bool playing) {
    _isPlaying = playing;
    _gateZero = !playing;
    if (!playing) {
      // 暂停：立即发一次全 0，让 UI 复位
      final n = bandCount;
      if (_outBuf.length != n) _outBuf = List<double>.filled(n, 0.0);
      _outBuf.fillRange(0, n, 0.0);
      if (!_controller.isClosed) _controller.add(_outBuf);
    }
  }

  /// 启动模拟频谱生成器
  void _startSimulated() {
    if (_simulated) return;
    _simulated = true;
    simulatedNotifier.value = true;
    _simulateTimer?.cancel();
    // 约 20fps（50ms 一次），与原生 captureRate 对齐
    _simulateTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_running || _controller.isClosed) return;
      final n = bandCount;
      // 复用输出缓冲，避免每帧分配
      if (_outBuf.length != n) _outBuf = List<double>.filled(n, 0.0);
      final bands = _outBuf;
      if (!_isPlaying) {
        // 暂停时：发送静止低柱（与无数据降级一致）
        bands.fillRange(0, n, 0.0);
        _controller.add(bands);
        return;
      }
      _simulateTime += 0.05;
      for (int i = 0; i < n; i++) {
        // sin 波动 + 随机噪声 + 频段衰减
        final phase = _phases[i % _phases.length];
        final decay = _decays[i % _decays.length];
        final wave = (math.sin((_simulateTime * 2.0 + phase) * 2 * math.pi) + 1) / 2;
        final noise = _rng.nextDouble() * 0.3;
        bands[i] = (wave * decay * 0.7 + noise * decay * 0.3).clamp(0.05, 1.0);
      }
      _controller.add(bands);
    });
  }

  /// 停止模拟频谱生成器
  void _stopSimulated() {
    _simulated = false;
    simulatedNotifier.value = false;
    _simulateTimer?.cancel();
    _simulateTimer = null;
  }

  /// 停止采集并释放资源。
  Future<void> stop() async {
    _running = false;
    _receivedFft = false;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _stopSimulated();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('stop');
      } catch (_) {}
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onFft') {
      final raw = call.arguments;
      if (raw is List) {
        _receivedFft = true;
        // 收到真实 FFT 数据，停止模拟模式
        if (_simulated) _stopSimulated();
        // 暂停门控：暂停时丢弃真实数据（UI 已收到全 0 复位，不再更新）
        if (_gateZero) return null;
        // 复用原生缓冲解析，避免每帧分配
        if (_nativeBuf.length != raw.length) {
          _nativeBuf = List<double>.filled(raw.length, 0.0);
        }
        final native = _nativeBuf;
        for (int i = 0; i < native.length; i++) {
          final v = raw[i];
          native[i] = v is num ? v.toDouble().clamp(0.0, 1.0) : 0.0;
        }
        // 重采样到用户配置的 bandCount（长度相等时直接复用 native）
        final bands = _resample(native, bandCount);
        if (!_controller.isClosed) _controller.add(bands);
      }
    }
    return null;
  }

  /// 线性插值重采样：将 [input] 重采样到 [targetCount] 段。
  /// 长度相等时直接返回 [input]（复用缓冲，无分配）。
  List<double> _resample(List<double> input, int targetCount) {
    if (input.isEmpty) return List<double>.filled(targetCount, 0.0);
    if (input.length == targetCount) return input;
    // 复用输出缓冲
    if (_outBuf.length != targetCount) {
      _outBuf = List<double>.filled(targetCount, 0.0);
    }
    final result = _outBuf;
    for (int i = 0; i < targetCount; i++) {
      final srcIdx = i * (input.length - 1) / (targetCount - 1);
      final lo = srcIdx.floor();
      final hi = srcIdx.ceil().clamp(0, input.length - 1);
      final frac = srcIdx - lo;
      result[i] = input[lo] * (1 - frac) + input[hi] * frac;
    }
    return result;
  }

  void dispose() {
    _simulateTimer?.cancel();
    _fallbackTimer?.cancel();
    simulatedNotifier.dispose();
    _controller.close();
  }
}

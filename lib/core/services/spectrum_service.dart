import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'diagnostic_logger.dart';

/// 「频谱总开关」的**同步可读**进程级镜像（默认关）。
///
/// **为什么需要镜像**：播放页的封面/文字连贯资格在 build 期求值，而偏好是异步
/// 读的——播放页在 `initState` 的 post-frame 才去读 SharedPreferences，首帧必然
/// 拿到「还没读」的 false。迷你条上滑展开时跟手覆盖层是**当场新建**的播放页，
/// 它的第一帧就已经在 0<p<1，资格锁存（见 `PlayerCoverMorphBus.resolveCoverEligible`）
/// 会把这份陈旧的 false 锁成「可形变」，于是频谱开着也照飞方封面。
/// 镜像由 `SettingsRepository` 的频谱读写方法维护、`runBootstrap` 在 runApp 前
/// 预热，资格判据从此与异步读取彻底解耦。
///
/// 单独存两个字段而不是一个 `active`：开关与样式是**分别**读写的（各自一个
/// getter/setter），合成一个值会被后写的那次覆盖掉。
bool kSpectrumEnabled = false;

/// 「频谱样式」的同步镜像：0=柱状图（环绕圆盘）、1=曲线（环绕圆盘）、2=背景层。
int kSpectrumStyle = 0;

/// 频谱**圆盘**（style 0/1：圆形旋转封面 + 环形频谱柱）当前是否生效。
///
/// 圆盘下封面形变必须关闭（形变层画不出圆形裁切 + 旋转），但**文字形变照旧**。
bool get kSpectrumDiscCoverActive => kSpectrumEnabled && kSpectrumStyle < 2;

/// 频谱**视觉对齐延迟**（毫秒，默认 580）。
///
/// 与「节奏偏移」（[MusicHapticsService] 的 `_offsetMs`）同一事实源、由其在
/// `load`/`setOffset`/`previewOffset` 三处回填：PCM 在混音前截取，频谱帧天然比
/// 「听到的」早一整个输出缓冲深度——震动靠延后点火补，显示靠把帧延后发布补，
/// 让柱体起落与听到的拍点同相。设置页拖动滑杆下一帧（≈50ms）实时生效；0 关闭。
int kSpectrumVisualOffsetMs = 580;

/// 频谱可视化服务：单例，桥接 Kotlin [SpectrumPlugin] 的 FFT 数据流。
///
/// **双模式设计**（兼容 HyperOS 等禁用 Visualizer 的 ROM）：
/// - **真实模式**：通过 MethodChannel 接收原生 Visualizer 的 FFT 回调
/// - **模拟模式**：Visualizer 不可用时，用 sin 波动 + 随机化生成装饰性频谱数据
///
/// 播放期间超过 1.5 秒未收到 FFT 回调时降级，并低频重试原生采集。
/// 收到真实 FFT 回调后自动切换回真实模式。
///
/// 模拟模式视觉上跟随播放节奏（播放时跳动、暂停时静止），但不反映真实音频频谱。
class SpectrumService with WidgetsBindingObserver {
  SpectrumService._() : _isAndroid = Platform.isAndroid;
  @visibleForTesting
  SpectrumService.forTesting({required bool isAndroid})
    : _isAndroid = isAndroid;
  final bool _isAndroid;
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

  /// 节拍特征向量广播流。布局由原生 `SpectrumFeatures` 定义：
  /// `[0..15]` 16 个对数频带能量（30Hz→16kHz，**未归一化**）、
  /// `[16]` 全带 RMS、`[17]` 低频带(30–300Hz)、`[18]` 高频带(3–8kHz)、
  /// `[19]` 中频带(300Hz–3kHz)。
  ///
  /// **只有 PCM 截取路径会产出特征**（原生 `onFeatures` 只在 `handlePcm` 里发）：
  /// Visualizer 兜底路径拿不到原始时域样本，模拟模式更是凭空生成。
  /// 因此音乐震动必须以本流是否有新鲜帧为闸门，绝不能拿 [spectrumStream] 顶替。
  final StreamController<List<double>> _featuresController =
      StreamController<List<double>>.broadcast(sync: true);

  Stream<List<double>> get featuresStream => _featuresController.stream;

  /// 最近一次收到真实特征帧的时刻；null 表示本次会话还没有过。
  DateTime? _lastFeatureAt;

  /// 特征通路是否真的有真实数据在流（模拟模式/Visualizer 兜底路径恒为 false）。
  bool get hasRealFeatures => _lastFeatureAt != null;

  /// 距最近一帧真实特征过去了多久；从未收到过时返回 null。
  Duration? get featureAge {
    final last = _lastFeatureAt;
    return last == null ? null : DateTime.now().difference(last);
  }

  /// 复用缓冲：特征帧约 20fps，与 `_nativeBuf` 同理由。
  List<double> _featureBuf = List.filled(0, 0.0);

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
  final Set<Object> _owners = {};
  final Object _defaultOwner = Object();
  int _generation = 0;
  DateTime? _lastFftAt;
  DateTime? _lastRecoveryAt;
  int _sessionId = 0;

  /// 原生端是否允许挂 Visualizer 兜底（透传给 Kotlin，重绑时沿用）。
  bool _visualizerFallback = true;
  bool _recovering = false;
  bool _foreground = true;
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

  // 在途延迟帧的定时器：暂停/停止/dispose 必须全部取消，否则旧歌尾帧迟到穿透。
  final Set<Timer> _pendingFrames = <Timer>{};

  /// 当前播放状态（模拟模式用：播放时生成数据，暂停时静止）
  bool _isPlaying = false;

  /// 启动频谱采集。返回 true 表示服务已运行（真实或模拟模式）。
  /// 每个播放器传入独立 owner，仅在最后一个使用者退出时释放原生采集。
  ///
  /// [visualizerFallback] 为 true 时原生端才允许挂 Visualizer 兜底（需要录音权限）；
  /// 为 false 时只走 PCM 截取路径，不需要任何权限。
  ///
  /// 注意：Dart 不允许「可选位置参数 + 可选命名参数」并存，故此处第三个参数
  /// 仍是可选位置参数（`start()` / `start(sessionId, owner)` 的既有调用不受影响）。
  Future<bool> start([
    int? audioSessionId,
    Object? owner,
    bool visualizerFallback = true,
  ]) async {
    _owners.add(owner ?? _defaultOwner);
    if (_running) {
      // 页面交接/切歌会带来新的 sessionId 与兜底开关。真实帧在流时 PCM 路径与
      // sessionId 无关，不打断；已降级到模拟模式说明旧绑定没在工作，
      // 必须带新参数立即重绑，否则 _recoverNative 会永远拿旧 session 重试。
      final sessionId = audioSessionId ?? 0;
      if (_sessionId != sessionId || _visualizerFallback != visualizerFallback) {
        _sessionId = sessionId;
        _visualizerFallback = visualizerFallback;
        if (_isAndroid && _simulated) unawaited(_recoverNative());
      }
      return true;
    }
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _sessionId = audioSessionId ?? 0;
    _visualizerFallback = visualizerFallback;
    _lastRecoveryAt = DateTime.now();
    final generation = ++_generation;
    _lastFftAt = DateTime.now();
    _lastFeatureAt = null;
    _watchData();
    DiagnosticLogger.instance.info(
      '[Spectrum] start generation=$generation session=${audioSessionId ?? 0}',
    );
    if (!_isAndroid) {
      _startSimulated();
      return true;
    }
    if (!_handlerRegistered) {
      _channel.setMethodCallHandler(_handleMethodCall);
      _handlerRegistered = true;
    }
    bool nativeOk = false;
    _recovering = true;
    try {
      nativeOk =
          await _channel
              .invokeMethod<bool>('start', {
                'audioSessionId': audioSessionId ?? 0,
                'visualizerFallback': visualizerFallback,
              })
              .timeout(const Duration(seconds: 4)) ??
          false;
    } catch (error) {
      DiagnosticLogger.instance.warning(
        '[Spectrum] native start failed: ${error.runtimeType}',
      );
    } finally {
      if (generation == _generation) _recovering = false;
    }
    // 退出/重新进入期间，旧启动结果不能恢复已释放的服务；
    // 本页 owner 已登记在案，作废时必须回收，否则 stop() 永远凑不齐空集合。
    if (!_running || generation != _generation) {
      _owners.remove(owner ?? _defaultOwner);
      return false;
    }
    if (!nativeOk) _startSimulated();
    return true;
  }

  /// 持续检查断流，不再仅检查启动后的第一帧；暂停期间不触发降级。
  void _watchData() {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!_running || !_isPlaying || !_foreground) return;
      if (_simulated) {
        if (_isAndroid &&
            !_recovering &&
            DateTime.now().difference(_lastRecoveryAt!) >=
                const Duration(seconds: 5)) {
          unawaited(_recoverNative());
        }
        return;
      }
      final last = _lastFftAt;
      if (last == null ||
          DateTime.now().difference(last) >=
              const Duration(milliseconds: 1500)) {
        DiagnosticLogger.instance.warning(
          '[Spectrum] FFT stream stalled, use simulated fallback',
        );
        _startSimulated();
        if (_isAndroid) {
          unawaited(_logNativeStats());
          unawaited(_recoverNative());
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground || !_running) return;
    // 熄屏期间系统可能回收采集资源，亮屏后主动重绑，不能依赖页面的 started 标记。
    _lastFftAt = DateTime.now();
    DiagnosticLogger.instance.info('[Spectrum] app resumed, restore capture');
    if (_isAndroid && _isPlaying) unawaited(_recoverNative());
  }

  /// 断流后重新注册原生采集；恢复期间保留模拟显示，真实帧到达后自动切回。
  Future<void> _recoverNative() async {
    if (_recovering || !_running) return;
    _recovering = true;
    final generation = _generation;
    _lastRecoveryAt = DateTime.now();
    DiagnosticLogger.instance.info('[Spectrum] rebind native capture');
    try {
      await _channel
          .invokeMethod<bool>('start', {
            'audioSessionId': _sessionId,
            'visualizerFallback': _visualizerFallback,
          })
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // 下一次低频检查再重试，禁止逐帧重连。
    } finally {
      if (generation == _generation) _recovering = false;
    }
  }

  /// 降级当场采集原生投递链三段计数，写入诊断日志。
  /// 旧版 APK 无 stats 方法时静默（MissingPluginException 被吞）。
  Future<void> _logNativeStats() async {
    try {
      final stats = await _channel
          .invokeMethod<Object?>('stats')
          .timeout(const Duration(seconds: 2));
      DiagnosticLogger.instance.info('[Spectrum] native stats: $stats');
    } catch (_) {}
  }

  /// 暂停门控：暂停时强制频谱复位为 0。
  /// 原因：ExoPlayer 暂停时会 flush 剩余 PCM（尾音），handleBuffer 仍被调用，
  /// 真实 FFT 数据继续到达导致暂停时频谱抽搐。暂停时置 true，丢弃真实数据发全 0。
  bool _gateZero = false;

  /// 设置播放状态（模拟模式用）
  void setPlaying(bool playing) {
    if (playing && !_isPlaying) _lastFftAt = DateTime.now();
    _isPlaying = playing;
    _gateZero = !playing;
    if (!playing) {
      // 先清在途延迟帧，再立即归零：否则 0.5s 前的旧帧会在柱体落下后又弹起来
      _cancelPendingFrames();
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
    DiagnosticLogger.instance.info('[Spectrum] simulated fallback active');
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
        final wave =
            (math.sin((_simulateTime * 2.0 + phase) * 2 * math.pi) + 1) / 2;
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
  Future<void> stop([Object? owner]) async {
    _owners.remove(owner ?? _defaultOwner);
    if (_owners.isNotEmpty || !_running) return;
    _running = false;
    WidgetsBinding.instance.removeObserver(this);
    _recovering = false;
    ++_generation;
    DiagnosticLogger.instance.info('[Spectrum] stopped, no consumers');
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _stopSimulated();
    _cancelPendingFrames();
    _lastFeatureAt = null;
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<bool>('stop');
      } catch (_) {}
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (!_running) return null;
    if (call.method == 'onFft') {
      final raw = call.arguments;
      if (raw is List && raw.isNotEmpty) {
        _lastFftAt = DateTime.now();
        // 收到真实 FFT 数据，停止模拟模式
        if (_simulated) {
          DiagnosticLogger.instance.info('[Spectrum] real FFT resumed');
          _stopSimulated();
        }
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
        _emitFrame(bands);
      }
      return null;
    }
    if (call.method == 'onFeatures') {
      final raw = call.arguments;
      if (raw is List && raw.isNotEmpty) {
        // 与 onFft 同一套门控：暂停时 ExoPlayer 会 flush 尾音，特征帧照旧到达，
        // 放着不管就会"暂停了还在震"。
        if (_gateZero) return null;
        _lastFeatureAt = DateTime.now();
        if (_featureBuf.length != raw.length) {
          _featureBuf = List<double>.filled(raw.length, 0.0);
        }
        final buf = _featureBuf;
        for (int i = 0; i < buf.length; i++) {
          final v = raw[i];
          // 特征不做 clamp：它是能量量纲，会超过 1.0，钳到 1 会抹掉鼓点的动态
          buf[i] = v is num ? v.toDouble() : 0.0;
        }
        if (!_featuresController.isClosed) _featuresController.add(buf);
      }
      return null;
    }
    return null;
  }

  /// 面向显示的消费发布：偏移 ≤0 时同步发布（sync 广播 + 复用缓冲的契约仅在
  /// 同帧消费下成立）；>0 时拷贝后经 Timer 延后发布——延后帧**必须**独立拷贝，
  /// `_outBuf`/`_nativeBuf` 会被下一帧覆盖。模拟模式帧不走本方法（装饰数据不
  /// 参与拍点对齐，也不值得每 50ms 起一个定时器）。
  void _emitFrame(List<double> bands) {
    // 无视觉消费者时跳过整条发布链：音乐震动只听 featuresStream（原生仍会送
    // onFft，但那是对端单帧小消息），这里省掉的是每帧一次列表拷贝 + 一个延迟
    // Timer（视觉偏移默认 580ms ≈ 常驻约 25 个定时器）。震动自持采集
    // （频谱显示关闭 / App 内 / 始终档）时视觉流通常无人监听，这是主要省电点。
    if (!_controller.hasListener) return;
    final offsetMs = kSpectrumVisualOffsetMs;
    if (offsetMs <= 0) {
      if (!_controller.isClosed) _controller.add(bands);
      return;
    }
    final copy = List<double>.of(bands);
    late final Timer timer;
    timer = Timer(Duration(milliseconds: offsetMs), () {
      _pendingFrames.remove(timer);
      // 迟到期间可能已暂停/停服/停流：三重守卫缺一不可
      if (_running && !_gateZero && !_controller.isClosed) {
        _controller.add(copy);
      }
    });
    _pendingFrames.add(timer);
  }

  void _cancelPendingFrames() {
    for (final timer in _pendingFrames) {
      timer.cancel();
    }
    _pendingFrames.clear();
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
    WidgetsBinding.instance.removeObserver(this);
    _running = false;
    ++_generation;
    _owners.clear();
    _simulateTimer?.cancel();
    _fallbackTimer?.cancel();
    _cancelPendingFrames();
    simulatedNotifier.dispose();
    _controller.close();
  }
}

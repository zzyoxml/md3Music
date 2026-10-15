import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_haptics.dart';
import 'diagnostic_logger.dart';
import 'music_onset_detector.dart';
import 'spectrum_service.dart';

/// 原生特征向量的下标（与 Kotlin `SpectrumFeatures` 一一对应）。
///
/// 单独列一份而不是散落魔法数字：两边一旦不同步，表现是"功能在但永远不触发"
/// 这种最难查的静默失败。
abstract final class SpectrumFeaturesIndices {
  static const int logBandCount = 16;
  static const int rms = 16;
  static const int low = 17;
  static const int high = 18;
  static const int mid = 19;
}

/// 触感波形档位。`auto`（清脆）= 交互开关同款的系统预定义触感（推荐，起振-刹停
/// 无拖尾）；`pulse` = 短脉冲；`smooth` = 带衰减尾音的自定义波形（需振幅控制，
/// 连续鼓点容易拖成"嗡嗡"声，真机实测）。
enum MusicHapticsWaveform {
  auto('auto', '清脆'),
  pulse('pulse', '脉冲'),
  smooth('smooth', '平滑');

  const MusicHapticsWaveform(this.nativeName, this.label);

  final String nativeName;
  final String label;

  static MusicHapticsWaveform fromNativeName(String? name) {
    for (final w in values) {
      if (w.nativeName == name) return w;
    }
    return MusicHapticsWaveform.auto;
  }
}

/// 震动生效范围三档。
enum MusicHapticsScope {
  /// 全屏播放页在场时（含拖拽覆盖层实例；route 被其他页盖住但未 dispose 也算在场）。
  playerPage('playerPage', '播放页启用'),

  /// App 前台的任意页面（resumed/inactive 都算前台）。
  inApp('inApp', 'App 内启用'),

  /// 不限前后台：熄屏后台播放也跟着震。
  always('always', '始终启用');

  const MusicHapticsScope(this.persistKey, this.label);

  /// 持久化用键值（SharedPreferences 存字符串）。
  final String persistKey;

  /// 设置页下拉显示文本。
  final String label;

  static MusicHapticsScope fromPersistKey(String? key) {
    for (final s in values) {
      if (s.persistKey == key) return s;
    }
    return MusicHapticsScope.playerPage;
  }
}

/// 音乐节奏震动：订阅频谱特征流 → 双频带 onset 判定 → 下发马达点火。
///
/// **被动订阅者**：在 bootstrap 启动一次，之后不再需要显式 stop。
/// 暂停/切歌/退后台由「原生暂停门控 + 特征断流 + 失活看门狗」自动兜住，
/// 因此**不需要改 `full_player.dart` / `full_player_am.dart`**。
class MusicHapticsService with WidgetsBindingObserver {
  MusicHapticsService._({SpectrumService? spectrum, bool? isAndroid})
    : _spectrum = spectrum ?? SpectrumService.instance,
      _isAndroid = isAndroid ?? Platform.isAndroid;

  @visibleForTesting
  factory MusicHapticsService.forTesting({
    required SpectrumService spectrum,
    bool isAndroid = true,
  }) => MusicHapticsService._(spectrum: spectrum, isAndroid: isAndroid);

  static final MusicHapticsService instance = MusicHapticsService._();

  static const String _channelName = 'com.md3music.md3music/music_haptics';
  static const String _keyEnabled = 'settings_music_haptics_enabled';
  static const String _keyStrength = 'settings_music_haptics_strength';
  static const String _keySensitivity = 'settings_music_haptics_sensitivity';
  static const String _keyWaveform = 'settings_music_haptics_waveform';
  static const String _keySnare = 'settings_music_haptics_snare';
  static const String _keyScope = 'settings_music_haptics_scope';
  static const String _keyOffset = 'settings_music_haptics_offset';

  /// 自动校准时叠加的「探针测不到的部分」（毫秒）。
  ///
  /// 探针只能测 AudioTrack 那一段（写入 → 播放头走到）；渲染器/音频处理器链与
  /// HAL/设备输出延迟在它上游，量不到，由本常量吸收。
  /// 初值 0 = 完全信任探针；Task 5 用真机数据（手调总补偿 580ms 作参照）定值。
  static const int upstreamLatencyBudgetMs = 0;

  /// 自动试测的最小间隔。探针是一次 MethodChannel 调用，播放中每 5s 一次可忽略。
  static const Duration _autoProbeInterval = Duration(seconds: 5);

  /// 节奏偏移的**默认**值（毫秒）。
  ///
  /// 580 是本机（小米 25102RKBEC，系统 AudioTrack 输出路径）实测校准出来的：
  /// PCM 在写入输出缓冲那一刻就被分析，比"听到"早约 0.55s，延后 580ms 才踩上拍。
  /// **换输出设备会变**（蓝牙耳机 / USB DAC / 系统 Direct PCM 的缓冲深度都不同），
  /// 那些情况下用设置里的滑块重调即可 —— 这也正是做成可调的原因。
  static const int defaultOffsetMs = 580;

  /// 节奏偏移的最大可调值（毫秒）。输出链路的缓冲深度因设备/ROM/音量而异，
  /// 给到 600ms 足够覆盖绝大多数 AudioTrack 缓冲。
  static const int maxOffsetMs = 600;

  /// 特征帧超过这个年龄就认为数据源已停（暂停 / 切歌 / 频谱关闭）。
  static const Duration _featureStaleAfter = Duration(milliseconds: 500);

  /// snare 能量双门：高频带能量必须同时满足
  /// `> _snareEnergyAbsFloor`（绝对下限，过滤无声歌的底噪）
  /// 与 `> _snareEnergyRatio × low`（相对低频带，过滤"低频轰轰但高频没内容"的歌）。
  /// 真机实测（2026-10-03）：噪声触发时 high≈0.2~3、low≈20~50，
  /// 双门下静默；合成探针里真实军鼓 high≈5+，双门照常通过。
  static const double _snareEnergyAbsFloor = 2.0;
  static const double _snareEnergyRatio = 0.05;

  /// kick 触发后该时段内的 snare 一律抑制：同一拍上两个预定义效果互相打断，
  /// 用户只感到一下——不如只留更重的 kick。
  static const Duration _snareSuppressionAfterKick = Duration(milliseconds: 60);

  /// 特征流断流超过该时长（暂停恢复/切歌/seek）就重建检测器基线，
  /// 避免残留 EMA 与新歌能量形状错配导致的开头误发。
  static const Duration _baselineResetGap = Duration(milliseconds: 400);

  /// 看门狗周期。不是动效，是状态回收，故不挂 `PlayerFrameDriver`（AGENTS.md 0.4）。
  static const Duration _watchdogPeriod = Duration(seconds: 1);

  final SpectrumService _spectrum;
  final bool _isAndroid;
  final MethodChannel _channel = const MethodChannel(_channelName);

  /// 低频（kick）检测器。参数按低频带的能量量纲调过。
  final MusicOnsetDetector _kickDetector = MusicOnsetDetector();

  /// 高频（snare）检测器。高频能量普遍低于低频，故门槛与冷却都更保守。
  final MusicOnsetDetector _snareDetector = MusicOnsetDetector(
    sensitivity: 0.8,
    cooldown: Duration(milliseconds: 160),
    noiseGate: 0.008,
  );

  StreamSubscription<List<double>>? _sub;
  Timer? _watchdog;
  final Stopwatch _clock = Stopwatch();

  // ── 节流/基线状态（见常量区注释） ──
  Duration? _lastFrameAt;
  Duration? _lastKickAt;

  bool _loaded = false;
  bool _nativeAvailable = false;
  bool _hasAmplitudeControl = false;

  // ── 用户偏好（内存态，UI 直接读；持久化由本类负责） ──
  bool _enabled = false;
  double _strength = 0.8;
  double _sensitivity = 1.0;
  MusicHapticsWaveform _waveform = MusicHapticsWaveform.auto;
  bool _snareEnabled = true;
  MusicHapticsScope _scope = MusicHapticsScope.playerPage;

  /// 本服务自行登记的频谱采集 owner（范围允许而播放页未持采集时由我们持有）。
  final Object _hapticsOwner = Object();

  /// 当前是否以自己的 owner 持有频谱采集（SpectrumService._owners 的本地镜像）。
  bool _captureOwned = false;

  /// 播放页在场计数（覆盖层与接管路由并存时 >1；initState/dispose 成对增减）。
  int _playerPageDepth = 0;

  /// App 是否在前台（resumed/inactive 视为在前台）。
  bool _appForeground = true;

  /// 最近一次得知的播放状态（暂停门控用）。
  ///
  /// 默认按「播放中」处理：采集持有与否刻意不看播放状态（见 [_wantsCapture]），
  /// 这里的值只喂给 [_updateCapture] 开门那一下的 `_gateZero`。乐观开门与
  /// 「不掺播放状态」同一逻辑——没接到暂停信号就当在播；真暂停时没有 PCM，
  /// 特征断流闸门本来就拦得住，误开门无副作用。
  bool _playbackActive = true;

  /// 节奏偏移（毫秒，0~[maxOffsetMs]）：点火前额外等待这么久。
  ///
  /// 补偿的是**音频输出链路**的延迟：PCM 在写入 AudioTrack 缓冲那一刻就被
  /// 截取分析，而声音要等缓冲放完才听见 —— 检测比听到早一整个缓冲深度。
  /// 这不是分析慢，而是分析得太早，只能靠延后点火对齐（原生侧定时执行）。
  ///
  /// 默认 [defaultOffsetMs]（真机实测校准值）；换输出设备需重新校准。
  int _offsetMs = defaultOffsetMs;

  /// 最近一次实测的输出排队深度（毫秒）；null = 未测到/不可用。
  int? measuredLatencyMs;

  /// 用户从未手动校准过时为 true：此时由自动校准接管，直到首次测到值。
  bool _autoOffsetPending = false;
  Duration _lastAutoProbeAt = Duration.zero;

  bool get enabled => _enabled;
  double get strength => _strength;
  double get sensitivity => _sensitivity;
  MusicHapticsWaveform get waveform => _waveform;
  bool get snareEnabled => _snareEnabled;
  MusicHapticsScope get scope => _scope;

  /// 当前是否自行持有频谱采集（设置页状态行 / 测试判据用）。
  bool get captureOwned => _captureOwned;

  /// 点火前的延迟补偿（毫秒）。
  int get offsetMs => _offsetMs;

  /// 设备是否支持振幅控制。设置页据此决定「平滑」档是否可选。
  bool get hasAmplitudeControl => _hasAmplitudeControl;

  /// 原生侧是否存在可用马达。
  bool get nativeAvailable => _nativeAvailable;

  /// 两个检测器最近一次的阈值（设置页状态行展示，用于真机排障）。
  double get kickThreshold => _kickDetector.lastThreshold;
  double get snareThreshold => _snareDetector.lastThreshold;

  /// 启动时恢复偏好并订阅特征流。在 `runBootstrap` 的并行初始化里调用。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appForeground = lifecycle == null || _isForegroundState(lifecycle);

    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_keyEnabled) ?? false;
    _strength = (prefs.getDouble(_keyStrength) ?? 0.8).clamp(0.2, 1.0);
    _sensitivity = (prefs.getDouble(_keySensitivity) ?? 1.0).clamp(0.3, 3.0);
    _waveform = MusicHapticsWaveform.fromNativeName(
      prefs.getString(_keyWaveform),
    );
    _snareEnabled = prefs.getBool(_keySnare) ?? true;
    _scope = MusicHapticsScope.fromPersistKey(prefs.getString(_keyScope));
    final storedOffset = prefs.getInt(_keyOffset);
    _offsetMs = (storedOffset ?? defaultOffsetMs).clamp(0, maxOffsetMs);
    kSpectrumVisualOffsetMs = _offsetMs; // 显示与点火共用同一补偿量
    // 从没存过偏移 = 用户没手动校准过 → 交给自动校准（播放中首次测到即套用）
    _autoOffsetPending = storedOffset == null;

    _kickDetector.sensitivity = _sensitivity;
    _snareDetector.sensitivity = _sensitivity * 0.8;

    // 功能关闭时既不订阅特征流、也不起看门狗：这两者才是真正的唤醒源
    //（_clock 是纯被动 Stopwatch，读 elapsed 不产生任何唤醒，故不参与闸门）。
    _clock.start();
    if (_enabled) _subscribeFeatures();

    await _probeCapabilities();
    await _pushConfig();
    WidgetsBinding.instance.addObserver(this);
    // ignore: discarded_futures
    _updateCapture();
  }

  /// `resumed`/`inactive` 都算前台：通知栏下拉、权限弹窗这类瞬时 `inactive`
  /// 不该把采集拆了再建。真正退后台是 paused/hidden/detached。
  static bool _isForegroundState(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = _isForegroundState(state);
    if (foreground == _appForeground) return;
    _appForeground = foreground;
    // ignore: discarded_futures
    _updateCapture();
  }

  void _subscribeFeatures() {
    _sub ??= _spectrum.featuresStream.listen(_onFeatures);
  }

  void _unsubscribeFeatures() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _probeCapabilities() async {
    if (!_isAndroid) return;
    try {
      final caps = await _channel.invokeMapMethod<String, Object?>(
        'capabilities',
      );
      if (caps == null) return;
      _nativeAvailable = caps['hasVibrator'] == true;
      _hasAmplitudeControl = caps['hasAmplitudeControl'] == true;
    } catch (_) {
      // 通道未注册（非 Android / 引擎未就绪）：保持不可用，闸门自然关闭
      _nativeAvailable = false;
    }
  }

  /// 把当前偏好下发原生。**每次改动都重下发**：波形缓存依赖这些参数。
  Future<void> _pushConfig() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('configure', {
        // 下发用户偏好而非五重闸门的合成值：configure 只在偏好变化时重发，
        // 而 bootstrap 时特征尚未到流（featureAge=null），合成的 _shouldFire
        // 恒为 false，原生会永久停在 disabled。每帧的点火闸门由 _shouldFire
        // 在 Dart 侧把守（见 Task 7 设计：「原生只多一层交互避让」）。
        'enabled': _enabled,
        'waveform': _waveform.nativeName,
        'kickStrength': _strength,
        'snareStrength': (_strength * 0.6).clamp(0.0, 1.0),
        'offsetMs': _offsetMs,
      });
    } catch (_) {
      // 原生不可用：闸门已关闭，不阻断 UI
    }
  }

  /// 是否允许点火。**五个条件全部为真**，缺一即静默。
  bool get _shouldFire {
    if (!_enabled) return false;
    // 全站震动总开关：用户关了全站震动就不该再被音乐震动
    if (!AppHaptics.enabled) return false;
    if (!_nativeAvailable) return false;
    if (!_isAndroid) return false;
    // 模拟频谱是凭空生成的 sin 波，绝不能拿它驱动马达
    if (_spectrum.isSimulated) return false;
    // 特征通路必须有新鲜数据（暂停 / 视觉兜底路径 / 未开频谱都是这里拦下）
    final age = _spectrum.featureAge;
    if (age == null || age > _featureStaleAfter) return false;
    return true;
  }

  void _onFeatures(List<double> features) {
    // 帧到来即确保看门狗在跑（见 [_ensureWatchdog]）：看门狗的生命周期因此
    // 完全跟随特征流，而不是常驻。
    _ensureWatchdog();
    if (!_shouldFire) return;
    if (features.length <= SpectrumFeaturesIndices.low) return;

    var now = _clock.elapsed;

    // 断流基线重建：暂停恢复/切歌/seek 后能量形状全变，残留的 EMA
    // 只会误发。重建后本帧只建立基线（检测器首帧不触发）。
    final lastFrame = _lastFrameAt;
    if (lastFrame != null && now - lastFrame > _baselineResetGap) {
      _resetDetectors();
      // 重置会把时钟一并归零，本帧必须用**新**时刻：否则给检测器喂一个
      // 属于旧时钟的 now，下一帧的 dt 会是负数、掩码反而增长
      now = _clock.elapsed;
      _lastFrameAt = now;
      _lastKickAt = null;
    } else {
      _lastFrameAt = now;
    }

    final low = features[SpectrumFeaturesIndices.low];
    final high = _snareEnabled ? features[SpectrumFeaturesIndices.high] : 0.0;

    final kickHit = _kickDetector.process(low, now);
    if (kickHit) {
      _lastKickAt = now;
      _strike('kick');
    }

    // snare 能量双门：门不拦检测器状态（EMA 保持温热），只拦点火
    final snareEnergyOk = high > _snareEnergyAbsFloor &&
        high > _snareEnergyRatio * low;
    final lastKick = _lastKickAt;
    final snareSuppressed =
        lastKick != null && now - lastKick < _snareSuppressionAfterKick;
    if (_snareEnabled && snareEnergyOk && !snareSuppressed) {
      if (_snareDetector.process(high, now)) {
        _strike('snare');
      }
    } else if (_snareEnabled) {
      // 被门拦下的帧照常喂检测器，保持统计温热，但不点火
      _snareDetector.process(high, now);
    }
  }

  void _strike(String kind) {
    try {
      // ignore: discarded_futures
      _channel.invokeMethod<void>('strike', {'kind': kind, 'intensity': 1.0});
    } catch (_) {}
  }

  /// 确保 1s 看门狗在跑（幂等）。由特征帧到来触发。
  ///
  /// 不常驻 `Timer.periodic`：功能关闭时不该有表；即便开着，未播放 / 频谱采集
  /// 未启动时也不会有帧，常驻表只剩每秒白唤醒 CPU（且断流期间 [_reapIfStale]
  /// 会每秒发一次 Binder `stop`）。改为「帧到 → 起表；断流 → 收尾一次即停表」。
  void _ensureWatchdog() {
    _watchdog ??= Timer.periodic(_watchdogPeriod, (_) => _watchdogTick());
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// 一拍照看：特征仍新鲜 → 做自动校准试测；已断流 → 收尾（取消在途波形）
  /// 并停表，不留空转。
  void _watchdogTick() {
    final age = _spectrum.featureAge;
    if (age == null || age > _watchdogPeriod) {
      _reapIfStale();
      _stopWatchdog();
      return;
    }
    // ignore: discarded_futures
    _tryAutoOffset();
  }

  /// 特征断流超过一个周期就取消在途波形：暂停后长衰减波形否则会拖完。
  void _reapIfStale() {
    final age = _spectrum.featureAge;
    if (age == null || age <= _watchdogPeriod) return;
    if (!_nativeAvailable) return;
    try {
      // ignore: discarded_futures
      _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<void> _persist(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is double) await prefs.setDouble(key, value);
    if (value is String) await prefs.setString(key, value);
    if (value is int) await prefs.setInt(key, value);
  }

  /// 播放页在场上报（两个全屏播放页在 initState/dispose 成对调用）。
  ///
  /// 用计数而非布尔：拖拽展开时覆盖层先挂载、接管的页面路由后创建，二者
  /// dispose/initState 时序交错，计数保证交接期不会被误判成「播放页已离场」。
  void setPlayerPageActive(bool active) {
    _playerPageDepth += active ? 1 : -1;
    if (_playerPageDepth < 0) _playerPageDepth = 0;
    // ignore: discarded_futures
    _updateCapture();
  }

  /// 范围是否允许此刻持采集。
  bool get _scopeAllows => switch (_scope) {
        MusicHapticsScope.playerPage => _playerPageDepth > 0,
        MusicHapticsScope.inApp => _appForeground,
        MusicHapticsScope.always => true,
      };

  /// 是否需要由本服务自行持有频谱采集。
  ///
  /// **不**看播放状态：暂停时 ExoPlayer 不再产出 PCM，FFT 线程无活可干，
  /// 采集挂着的开销 ≈ 0；把播放状态掺进来只会在切歌/暂停恢复时反复拆建
  /// 采集（generation 递增 + 分析器基线重建），白白多走弯路。
  bool get _wantsCapture =>
      _enabled &&
      AppHaptics.enabled &&
      _nativeAvailable &&
      _scopeAllows;

  /// 重算是否自持采集。**owner 集合的增删发生在同步段**（SpectrumService
  /// start/stop 的第一行），异步的只有原生通道调用且 MethodChannel 保序，
  /// 因此连续两次重算不会把 owner 永久泄漏在采集上。
  Future<void> _updateCapture() async {
    final wants = _wantsCapture;
    if (wants == _captureOwned) return;
    _captureOwned = wants;
    DiagnosticLogger.instance.info(
      '[MusicHaptics] capture=${wants ? 'acquire' : 'release'} '
      'scope=${_scope.persistKey} page=$_playerPageDepth '
      'foreground=$_appForeground',
    );
    if (wants) {
      // 播放页已在持采集时，start 只是登记 owner，不重复初始化原生。
      // visualizerFallback=false：PCM 截取路径不需要录音权限，也绝不挂
      // Visualizer（挂载会把轨道从 fast track 降级，见 SpectrumPlugin 注释）。
      await _spectrum.start(0, _hapticsOwner, false);
      // start 之后再开门：开启瞬间 ExoPlayer flush 的尾音必须被 _gateZero 拦下。
      _spectrum.setPlaying(_playbackActive);
    } else {
      // 刻意**不**动 setPlaying：sole-owner 释放后本来就没有新帧；若播放页
      // 仍持采集（共 owner 场景），暂停门控归页面管，这里写 false 会把人家的
      // 视觉频谱冻在 0（例如在设置页关「全站震动」而播放页在底下播着）。
      await _spectrum.stop(_hapticsOwner);
    }
  }

  /// 播放状态入口：由 app.dart 在 PlayerProvider 的监听里转发。
  void setPlaybackActive(bool playing) {
    if (_playbackActive == playing) return;
    _playbackActive = playing;
    // 暂停门控只在采集由本服务持有时经手；播放页自己持有时由页面负责
    // setPlaying（页面与服务的值同源于 isPlaying，写谁都是同一个值）。
    if (_captureOwned) _spectrum.setPlaying(playing);
  }

  /// 外部状态变化（全站震动总开关等）后重算采集持有。
  void refreshCapture() {
    // ignore: discarded_futures
    _updateCapture();
  }

  /// 设置生效范围并重算采集持有。
  ///
  /// 例如从「始终」切回「播放页」而页面不在场时，下一次重算就会把后台还
  /// 挂着的采集拆掉。持久化与设置页经 SettingsRepository 的写入是同一键的
  /// 双写（与节奏偏移 setOffset 同款约定），重启后两侧读到的值一致。
  Future<void> setScope(MusicHapticsScope value) async {
    if (_scope == value) return;
    _scope = value;
    await _persist(_keyScope, value.persistKey);
    // ignore: discarded_futures
    _updateCapture();
    DiagnosticLogger.instance.info('[MusicHaptics] scope=${value.persistKey}');
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    // 状态切换要重置检测器：否则上一次残留的均值/方差会污染新一段的阈值
    _resetDetectors();
    if (value) {
      _subscribeFeatures();
    } else {
      // 关闭即撤订阅与看门狗（在途波形由原生 configure(enabled:false) 取消）
      _unsubscribeFeatures();
      _stopWatchdog();
    }
    await _persist(_keyEnabled, value);
    await _pushConfig();
    // ignore: discarded_futures
    _updateCapture();
    DiagnosticLogger.instance.info('[MusicHaptics] enabled=$value');
  }

  Future<void> setStrength(double value) async {
    final v = value.clamp(0.2, 1.0);
    if (_strength == v) return;
    _strength = v;
    await _persist(_keyStrength, v);
    await _pushConfig();
  }

  Future<void> setSensitivity(double value) async {
    final v = value.clamp(0.3, 3.0);
    if (_sensitivity == v) return;
    _sensitivity = v;
    _kickDetector.sensitivity = v;
    _snareDetector.sensitivity = v * 0.8;
    await _persist(_keySensitivity, v);
  }

  Future<void> setWaveform(MusicHapticsWaveform value) async {
    if (_waveform == value) return;
    _waveform = value;
    await _persist(_keyWaveform, value.nativeName);
    await _pushConfig();
  }

  Future<void> setSnareEnabled(bool value) async {
    if (_snareEnabled == value) return;
    _snareEnabled = value;
    if (!value) _snareDetector.reset();
    await _persist(_keySnare, value);
  }

  /// 设置节奏偏移（毫秒）。会自动夹到 `[0, maxOffsetMs]`。
  Future<void> setOffset(int value) async {
    final v = value.clamp(0, maxOffsetMs);
    if (_offsetMs == v) return;
    _offsetMs = v;
    kSpectrumVisualOffsetMs = v;
    await _persist(_keyOffset, v);
    await _pushConfig();
    // 用户显式设过值就不再被自动校准覆盖
    _autoOffsetPending = false;
  }

  /// 拖动预览：只更新内存态并下发原生，**不写持久化**。
  ///
  /// 无极滑块拖动时每帧都会回调，走 [setOffset] 会每秒十几次地写
  /// SharedPreferences 并重发 configure；松手时再由 [setOffset] 落盘。
  Future<void> previewOffset(int value) async {
    final v = value.clamp(0, maxOffsetMs);
    if (_offsetMs == v) return;
    _offsetMs = v;
    kSpectrumVisualOffsetMs = v; // 拖动实时生效靠这一行
    await _pushConfig();
  }

  /// 实测输出排队深度（毫秒）。不可用返回 null。
  ///
  /// 播放中才有意义：没在播音时 AudioTrack 未挂载，原生侧返回 -1。
  Future<int?> refreshMeasuredLatency() async {
    if (!_isAndroid) {
      measuredLatencyMs = null;
      return null;
    }
    try {
      final v = await _channel.invokeMethod<int>('outputLatency');
      measuredLatencyMs = (v != null && v >= 0) ? v : null;
    } catch (_) {
      // 通道未注册 / 原生异常：保持 null，闸门自然不动作
      measuredLatencyMs = null;
    }
    DiagnosticLogger.instance.info(
      '[MusicHaptics] outputLatency=${measuredLatencyMs}ms',
    );
    return measuredLatencyMs;
  }

  /// 自动套用：实测排队深度 + 上游预算。
  ///
  /// 返回 false 表示测不到（无 AudioTrack 的输出路径），此时**不动**用户手调值。
  Future<bool> applyAutoOffset() async {
    final measured = await refreshMeasuredLatency();
    if (measured == null) return false;
    await setOffset(measured + upstreamLatencyBudgetMs);
    return true;
  }

  /// 看门狗里顺带做的自动校准试测：仅在用户从未手动校准过时进行。
  Future<void> _tryAutoOffset() async {
    if (!_autoOffsetPending) return;
    if (_clock.elapsed - _lastAutoProbeAt < _autoProbeInterval) return;
    _lastAutoProbeAt = _clock.elapsed;
    final measured = await refreshMeasuredLatency();
    if (measured == null) return;
    await setOffset(measured + upstreamLatencyBudgetMs);
  }

  void _resetDetectors() {
    _kickDetector.reset();
    _snareDetector.reset();
    _clock
      ..reset()
      ..start();
    _lastKickAt = null;
  }

  @visibleForTesting
  void dispose() {
    _unsubscribeFeatures();
    _stopWatchdog();
    WidgetsBinding.instance.removeObserver(this);
    if (_captureOwned) {
      _captureOwned = false;
      // ignore: discarded_futures
      _spectrum.stop(_hapticsOwner);
    }
  }
}

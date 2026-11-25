import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../platform_capabilities.dart';
import '../../data/repositories/settings_repository.dart';
import 'audio_decoder_capabilities.dart';
import 'audio_offload_capabilities.dart';
import 'equalizer_service.dart';
import 'viper_master_service.dart';

/// 系统音频 Offload（硬件解码直通）决策器：单例 [ChangeNotifier]。
///
/// 与 Direct PCM / USB 独占的分工：本服务只管「要不要把解码与输出整段交给系统
/// 音频服务（Media3 audio offload）」；AudioTrack 的具体配置、DSP 旁路、音量
/// 处理仍归 `OutputModeCoordinator` / PlayerProvider。
///
/// ## 决策模型
/// - **用户开关** [userEnabled]：持久化在 [keyEnabled]，唯一由用户设置页控制；
/// - **让路原因** [yieldReason]：由 PlayerProvider 注入的若干判定器算出。只要
///   有任何一条成立，硬解就不该开（划掉退出 / DSP / 频谱 / 变速 / 独占输出都与 offload 互斥）；
/// - **平台支持** [platformSupported]：原生报告 `apiLevel >= 29` 才成立；
/// - **生效值** [effective] = 三者同时满足。
///
/// ## 下发时机（关键，别改成「一有变化就下发」）
/// - 让路（true → false）：**立即**下发，停掉不安全的直通通路；
/// - 恢复（false → true）：若正在播放，挂 [pendingApply] 等 [beforeSourceLoad]
///   冲刷 —— 播放中途切到 offload 需要重建 AudioTrack，会造成可听见的断音；
///   暂停态则立即下发（本来就没有声音可断）。
///
/// ## 幂等
/// [init] 在主引擎与 headless 播放引擎各调用一次都安全：所有注册都带 `_inited`
/// 闸门，重复调用直接返回。
class AudioOffloadService extends ChangeNotifier {
  AudioOffloadService._();

  static final AudioOffloadService instance = AudioOffloadService._();

  /// 用户开关的持久化键（与 `SettingsRepository` 共用同一字面量）。
  static const String keyEnabled = 'settings_audio_offload_enabled';

  /// 原生通道名。
  static const String channelName = 'com.md3music.md3music/audio_offload';

  /// 平台最低 API（`Media3 audio offload` 的协商前提）。
  static const int kMinApiLevel = 29;

  static const String _tag = 'AudioOffload';

  /// 下发后多久校验「是否真的 offloaded」。
  static const Duration _verifyDelay = Duration(milliseconds: 400);

  static const MethodChannel _channel = MethodChannel(channelName);

  // ── 由 PlayerProvider 注入的判定器（null 视为该条件未命中）──────────

  /// 当前是否**正在播放**。决定「恢复」是否要挂起到下一次起播。
  bool Function()? isPlaying;

  /// 播放速度是否恰为 1.0 倍。
  bool Function()? speedIsNormal;

  /// 蝰蛇母带是否开启。
  bool Function()? dspActive;

  /// 系统均衡器 / 音效链是否开启。
  bool Function()? equalizerActive;

  /// 音量均衡（响度归一）是否开启。
  bool Function()? volumeNormalizationActive;

  /// 音乐频谱原生采集是否在进行。
  bool Function()? spectrumCapturing;

  /// 端侧人声/伴奏分离是否在进行。
  ///
  /// offload 的样本不经过应用进程，分离的 AudioProcessor 根本收不到 PCM，
  /// 两者天然互斥（与 [spectrumCapturing] 同一模式）。
  bool Function()? stemSeparationActive;

  /// USB 独占 / 系统 Direct PCM 是否生效。
  bool Function()? usbOrDirectPcmActive;

  /// 交叉淡化是否开启。
  bool Function()? crossfadeEnabled;

  /// 请求重建输出（offload 下发后 400ms 仍未生效时的兜底）。
  Future<void> Function()? rebuildRequester;

  // ── 内部状态 ────────────────────────────────────────────────────

  bool _inited = false;
  bool _disposed = false;

  bool _userEnabled = false;

  /// 划掉退出开启时禁用 offload，避免进程死亡后 DSP 仍继续输出尾音。
  bool _swipeExitEnabled = true;

  /// 是否已向原生下发过至少一次（区分「默认关闭」与「确认关闭」）。
  bool _hasPushed = false;

  /// 最近一次下发给原生的生效值（用户意图 + 条件的合成结果）。
  bool _pushedEffective = false;

  /// 恢复被挂起：等 [beforeSourceLoad] 冲刷。
  bool _pendingApply = false;

  /// 是否已做过「400ms 未生效 → 重建输出」的兜底（每轮开启只做一次）。
  bool _fallbackApplied = false;

  /// 是否已做过一次「缓存设备指纹 vs 当前设备」校验（避免反复重探测）。
  bool _deviceChecked = false;

  String? _yieldReason;

  /// [forceSuspend] 记下的临时强制让路原因（不写 pref、不动用户开关）。
  String? _forceReason;

  /// [forceSuspend] 的写入时刻（配合 [forceSuspendGrace] 判定宽限窗口）。
  DateTime? _forceSetAt;

  /// [forceSuspend] 的宽限窗口：期间即使条件器还没反映（原生状态滞后），也不解除钉住。
  ///
  /// 为什么需要：USB 独占 / Direct PCM 的「开关意图」先于原生状态生效，若这期间来一次
  /// `refresh()`（频谱停顿、设置读取、页面轮询都会触发），朴素实现会立刻把
  /// force 原因判为「未复现」而解除，硬解在独占建立过程中被重新打开 → 两条输出通路打架。
  /// 宽限有界（默认 3s）保证失败路径仍能自愈。
  @visibleForTesting
  Duration forceSuspendGrace = const Duration(seconds: 3);

  String? _notice;

  Map<String, dynamic> _status = const <String, dynamic>{};

  AudioOffloadCapabilitySnapshot? _capabilities;

  bool _cacheStale = true;

  final AudioOffloadCapabilityStore _store = AudioOffloadCapabilityStore();

  /// 设备解码器能力（MediaCodec 枚举）快照：与 [capabilities] 是两个数据源。
  AudioDecoderCapabilitySnapshot? _decoderCapabilities;

  final AudioDecoderCapabilityStore _decoderStore = AudioDecoderCapabilityStore();

  Timer? _verifyTimer;

  // ── 对外只读状态 ─────────────────────────────────────────────────

  /// 用户是否打开了「硬件解码播放」（持久化值，未做任何平台/条件门控）。
  bool get userEnabled => _userEnabled;

  /// 实际是否应生效：用户开关 + 无让路原因 + 平台支持。
  bool get effective =>
      _userEnabled && _yieldReason == null && platformSupported;

  /// 当前让路原因（中文）；null 表示没有让路。
  String? get yieldReason => _yieldReason;

  /// 原生最近一次上报的状态 map（`getStatus` / `setEnabled` 返回值 / 推送）。
  Map<String, dynamic> get status => _status;

  /// 原生是否报告当前确实在 offload 输出。
  bool get offloaded => _status['offloaded'] == true;

  /// 原生是否报告当前处于「休眠 / 挂起」状态。
  bool get sleeping => _status['sleeping'] == true;

  /// 原生是否报告平台侧失败（解码器拒绝 / 通道建立失败）。
  bool get platformFailed => _status['failed'] == true;

  /// 平台是否支持硬解：原生 `apiLevel >= 29`；尚未拿到状态前按 Android 平台判定
  /// （避免启动首帧把开关误显示为「不可用」）。
  bool get platformSupported {
    final dynamic raw = _status['apiLevel'];
    final int? level = raw is num
        ? raw.toInt()
        : (raw is String ? int.tryParse(raw.trim()) : null);
    if (level != null) return level >= kMinApiLevel;
    return supportsAudioOffload;
  }

  /// 最近一次加载（或探测）到的解码能力快照。
  AudioOffloadCapabilitySnapshot? get capabilities => _capabilities;

  /// 最近一次加载（或探测）到的**设备解码器能力**快照。
  ///
  /// 与 [capabilities] 不是一回事：这里回答「设备上有哪些解码器、各自支持什么
  /// 采样率 / 声道 / 位深」，供设置页矩阵与 [predictDecoderSupported] 使用。
  AudioDecoderCapabilitySnapshot? get decoderCapabilities =>
      _decoderCapabilities;

  // ── 生命周期 ────────────────────────────────────────────────────

  /// 幂等初始化：读开关 → 读能力缓存 → 注册监听与原生回调 → 首次下发。
  ///
  /// 仅用户已开启且缓存缺失/过期时后台重探测；关闭时不触碰厂商解码器。
  /// 能力探测只影响「预测显示」，不阻塞启动。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    // 桌面端 / Web 没有 offload 通路（supportsAudioOffload 仅 Android）：
    // 整个决策器不启动 —— 不读 pref、不注册通道与监听、不下发、不产生
    // 「已让路/已恢复」提示。否则 Windows 上会因本地残留 pref 或划掉退出
    // 默认值弹出「硬件解码播放已让路」这类无意义 Toast。
    if (!supportsAudioOffload) return;

    try {
      // 开关持久化统一走 SettingsRepository（键与 [keyEnabled] 是同一字面量），
      // 避免同一条设置在两个类里各读一遍 prefs、后续改名漏改一处。
      _userEnabled = await SettingsRepository().getAudioOffloadEnabled();
    } catch (e) {
      debugPrint('[$_tag] 读取 $keyEnabled 失败: $e');
    }

    try {
      _swipeExitEnabled =
          await SettingsRepository().getSwipeExitOnTaskRemoved();
    } catch (e) {
      debugPrint('[$_tag] 读取划掉退出开关失败: $e');
    }

    try {
      final cached = await _store.load();
      if (cached != null) {
        _capabilities = cached;
        _cacheStale = _store.stale;
      }
    } catch (e) {
      debugPrint('[$_tag] 读取能力缓存异常: $e');
    }

    try {
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (e) {
      debugPrint('[$_tag] setMethodCallHandler 失败: $e');
    }

    // DSP / 均衡器都是 ChangeNotifier：任一处开关变化都要重算让路原因。
    try {
      ViperMasterService.instance.addListener(_onDspChanged);
    } catch (e) {
      debugPrint('[$_tag] 监听蝰蛇母带失败: $e');
    }
    try {
      EqualizerService.instance.addListener(_onEqChanged);
    } catch (e) {
      debugPrint('[$_tag] 监听均衡器失败: $e');
    }

    await _fetchStatus();
    _checkCachedDeviceKey();

    // 解码器能力缓存放在 getStatus 之后再读：此时设备指纹已就绪，store.load()
    // 才能顺带校验「这份缓存是不是这台设备探的」。
    try {
      final cachedDecoders = await _decoderStore.load();
      if (cachedDecoders != null) _decoderCapabilities = cachedDecoders;
    } catch (e) {
      debugPrint('[$_tag] 读取解码器能力缓存异常: $e');
    }

    await refresh();

    _probeMissingCapabilities();
  }

  void _probeMissingCapabilities() {
    // 探测会触碰厂商解码器，关闭硬解时只读缓存，不能在后台偷偷实配。
    if (!_userEnabled) return;
    if (_capabilities == null || _cacheStale) {
      unawaited(reloadCapabilities(reprobe: true));
    }
    // 用户已明确开启后，才允许后台探测缺失或过期的能力快照。
    if (_decoderCapabilities == null || _decoderStore.stale) {
      unawaited(reloadDecoderCapabilities(reprobe: true));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelVerify();
    try {
      ViperMasterService.instance.removeListener(_onDspChanged);
    } catch (_) {}
    try {
      EqualizerService.instance.removeListener(_onEqChanged);
    } catch (_) {}
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {}
    super.dispose();
  }

  // ── 用户开关与决策 ──────────────────────────────────────────────

  /// 用户切换「硬件解码播放」。写 pref 后立即重算（恢复时播放中会挂起到下一首）。
  Future<void> setEnabled(bool value) async {
    final wasEnabled = _userEnabled;
    if (_userEnabled != value) {
      _userEnabled = value;
      debugPrint('[$_tag] 用户开关 → $value');
      try {
        await SettingsRepository().setAudioOffloadEnabled(value);
      } catch (e) {
        debugPrint('[$_tag] 写入 $keyEnabled 失败: $e');
      }
    }
    await refresh();
    if (!wasEnabled && _userEnabled) _probeMissingCapabilities();
  }

  /// 同步「划掉后台自动退出」状态。持久化由设置页负责，这里只重算输出通路。
  Future<void> setSwipeExitEnabled(bool value) async {
    if (_swipeExitEnabled == value) return;
    _swipeExitEnabled = value;
    await refresh();
  }

  /// 重算让路原因并按时机下发。
  ///
  /// [immediate] 为 true 时即使「正在播放」也立刻下发（用于必须马上让路的场景，
  /// 例如变速切到非 1.0 倍）。恢复路径默认不 immediate，等下一次起播。
  Future<void> refresh({bool immediate = false}) async {
    // 非 Android 平台整个决策器未启动（见 [init]），任何刷新都不产生副作用。
    if (!supportsAudioOffload) return;
    final String? previousReason = _yieldReason;
    final bool previousEffective = effective;

    _yieldReason = _resolveYieldReason();

    if (_yieldReason != previousReason && _userEnabled) {
      if (_yieldReason != null) {
        _notice = '硬件解码播放已让路：$_yieldReason';
      } else if (previousReason != null) {
        _notice = '硬件解码播放已恢复';
      }
    }

    if (!effective) {
      // 让路：立即下发，不等起播。
      _pendingApply = false;
      _cancelVerify();
      if (_pushedEffective) {
        await _push(false);
      } else {
        _hasPushed = true;
      }
    } else if (_hasPushed && _pushedEffective) {
      // 已经是生效态，什么都不用做。
      _pendingApply = false;
    } else {
      // 恢复：播放中挂起到 beforeSourceLoad，暂停态立即下发。
      final bool playing = isPlaying?.call() ?? false;
      if (playing && !immediate) {
        _pendingApply = true;
        debugPrint('[$_tag] 恢复挂起，等下一次起播冲刷');
      } else {
        await _push(true);
      }
    }

    if (previousEffective != effective) {
      debugPrint(
        '[$_tag] effective $previousEffective → $effective '
        'reason=${_yieldReason ?? '-'}',
      );
    }
    _safeNotify();
  }

  /// 起播前冲刷挂起的「恢复」：此时重建 AudioTrack 属于正常起播流程，不会断音。
  Future<void> beforeSourceLoad() async {
    final bool wasPending = _pendingApply;
    _pendingApply = false;
    _yieldReason = _resolveYieldReason();
    if (!effective) {
      if (_pushedEffective) await _push(false);
      return;
    }
    if (_pushedEffective) return;
    if (wasPending) debugPrint('[$_tag] 起播冲刷挂起的硬解恢复');
    await _push(true);
  }

  /// 临时强制让路（不写 pref、不改用户开关），立即下发关闭。
  ///
  /// 用于 USB 独占 / 系统 Direct PCM 打开瞬间：此时对应条件器可能还没反映新状态，
  /// 由调用方先钉一个原因。下一次 [refresh] 若条件器复现同一原因则保留，否则清除。
  Future<void> forceSuspend(String reason) async {
    final String trimmed = reason.trim();
    if (trimmed.isEmpty) return;
    _forceReason = trimmed;
    _forceSetAt = DateTime.now();
    _yieldReason = trimmed;
    _pendingApply = false;
    _cancelVerify();
    debugPrint('[$_tag] forceSuspend: $trimmed');
    if (!_hasPushed || _pushedEffective) {
      await _push(false);
    }
    _safeNotify();
  }

  // ── 能力快照 ────────────────────────────────────────────────────

  /// 重新加载能力快照。
  ///
  /// [reprobe] 为 false 时只读原生存量缓存（不触发探测，很快）；为 true 时触发
  /// 一次真探测（原生在后台线程跑，失败会退回缓存快照）。失败静默，保持旧值。
  Future<void> reloadCapabilities({bool reprobe = false}) async {
    if (!supportsAudioOffload) return;
    if (reprobe && !_userEnabled) return;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        reprobe ? 'probeCapabilities' : 'getCachedCapabilities',
      );
      if (result == null || result.isEmpty) {
        _cacheStale = true;
        debugPrint('[$_tag] 能力快照为空（reprobe=$reprobe）');
        return;
      }
      final snapshot = AudioOffloadCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(result),
      );
      _capabilities = snapshot;
      _cacheStale = false;
      _configureStoreDeviceKey();
      await _store.save(snapshot);
      debugPrint('[$_tag] 能力快照已更新: $snapshot');
      _safeNotify();
    } catch (e) {
      debugPrint('[$_tag] 读取能力快照失败（reprobe=$reprobe）: $e');
    }
  }

  /// 预测「该编码 + 采样率 + 声道」能否走硬件解码。
  ///
  /// 有快照时用 [AudioOffloadCapabilitySnapshot.supportsCodec]（三态）；
  /// 无快照返回 null（未知，绝不能当成「不支持」）。
  bool? predictSupported(String? codec, int sampleRate, int channelCount) {
    final snapshot = _capabilities;
    if (snapshot == null) return null;
    return snapshot.supportsCodec(codec, sampleRate, channelCount);
  }

  // ── 设备解码器能力（MediaCodec 枚举）─────────────────────────────

  /// 重新加载**设备解码器能力**快照。
  ///
  /// [reprobe] 为 false 时只读原生存量缓存（不触发探测，很快）；为 true 时触发
  /// 一次后台探测。失败只记日志、保持旧值 —— 解码器能力只影响展示与预测，
  /// 不能因为它失败而影响播放决策。
  Future<void> reloadDecoderCapabilities({bool reprobe = false}) async {
    if (!supportsAudioOffload) return;
    if (reprobe && !_userEnabled) return;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        reprobe ? 'probeDecoderCapabilities' : 'getCachedDecoderCapabilities',
      );
      if (result == null || result.isEmpty) {
        debugPrint('[$_tag] 解码器能力快照为空（reprobe=$reprobe）');
        return;
      }
      final snapshot = AudioDecoderCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(result),
      );
      _decoderCapabilities = snapshot;
      await _decoderStore.save(snapshot);
      debugPrint('[$_tag] 解码器能力快照已更新: $snapshot');
      _safeNotify();
    } catch (e) {
      debugPrint('[$_tag] 读取解码器能力快照失败（reprobe=$reprobe）: $e');
    }
  }

  /// 同时刷新两个能力数据源（能力页的「重新探测」）。
  ///
  /// 并行发起、互不阻塞：两个方法内部各自 try/catch，任一失败不影响另一个。
  Future<void> reloadAllCapabilities({bool reprobe = false}) async {
    await Future.wait(<Future<void>>[
      reloadCapabilities(reprobe: reprobe),
      reloadDecoderCapabilities(reprobe: reprobe),
    ]);
  }

  /// 预测「该编码 + 采样率 + 声道」能否交给设备硬件解码器。
  ///
  /// 三态：`true` 支持 / `false` 不支持 / `null` 未知。判定顺序：
  /// 1. 没有快照或空快照 → `null`；
  /// 2. 编码短名归一后未命中 [AudioDecoderCapabilitySnapshot.byFormat] → `null`
  ///    （这台设备压根没探测到这个格式，不能谎报「不支持」）；
  /// 3. 命中的格式没有硬件解码器（只有软解）→ `false`；
  /// 4. 采样率 / 声道不在该格式的并集里 → `false`；并集为空（该维度没探测）→
  ///    跳过该维度，不据此判否；
  /// 5. 其余 → `true`。
  bool? predictDecoderSupported(
    String? codec,
    int sampleRate,
    int channelCount,
  ) {
    final snapshot = _decoderCapabilities;
    if (snapshot == null || snapshot.isEmpty) return null;
    final format = snapshot.formatFor(codec);
    if (format == null) return null;
    if (!format.hasHardware) return false;
    if (format.sampleRates.isNotEmpty &&
        !format.sampleRates.contains(sampleRate)) {
      return false;
    }
    if (format.maxChannels > 0 && channelCount > format.maxChannels) {
      return false;
    }
    return true;
  }

  // ── 一次性提示 ──────────────────────────────────────────────────

  /// 取走一次性提示（取走即清空）。UI 层拿到后自行决定怎么提示。
  String? consumeNotice() {
    final String? n = _notice;
    _notice = null;
    return n;
  }

  /// 原生侧已回退到软件解码（播放错误 5003/5004 时由 PlayerProvider 调用）。
  ///
  /// 只记提示 + 标记本轮兜底已用，不擅自关用户开关 —— 是否继续尝试由用户决定。
  void notePlatformFallback() {
    // 非 Android 平台没有硬解通路，不存在「回退到软解」一说。
    if (!supportsAudioOffload) return;
    if (_fallbackApplied) return;
    _fallbackApplied = true;
    _notice = '硬件解码不可用，已回退到软件解码';
    debugPrint('[$_tag] 平台侧回退到软件解码');
    _safeNotify();
  }

  // ── 内部实现 ────────────────────────────────────────────────────

  void _onDspChanged() => unawaited(refresh());

  void _onEqChanged() => unawaited(refresh());

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onStatusChanged') {
      final dynamic args = call.arguments;
      if (args is Map) {
        _applyStatus(Map<String, dynamic>.from(args));
        // 原生推送可能带来首次 apiLevel / failed，需要重算一次生效值。
        unawaited(refresh());
      }
      return null;
    }
    return null;
  }

  Future<void> _fetchStatus() async {
    if (!supportsAudioOffload) return;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getStatus',
      );
      if (result != null && result.isNotEmpty) {
        _applyStatus(Map<String, dynamic>.from(result));
      }
    } catch (e) {
      debugPrint('[$_tag] getStatus 失败: $e');
    }
  }

  void _applyStatus(Map<String, dynamic> status) {
    final bool wasFailed = _status['failed'] == true;
    _status = status;
    _configureStoreDeviceKey();
    if (!wasFailed && status['failed'] == true) {
      _fallbackApplied = true;
      _notice = '硬件解码在当前音频通路上不可用';
      debugPrint('[$_tag] 原生报告 failed: $status');
    }
    _safeNotify();
  }

  /// 记录原生给的设备指纹（用于能力缓存的一致性校验）。
  void _configureStoreDeviceKey() {
    // 原生的设备指纹在 status 里叫 `capabilityDeviceKey`；`deviceKey` /
    // `fingerprint` 是兼容别名（早期协议 / 诊断字段）。
    final dynamic raw =
        _status['capabilityDeviceKey'] ??
        _status['deviceKey'] ??
        _status['fingerprint'];
    if (raw is String && raw.trim().isNotEmpty) {
      _store.currentDeviceKey = raw.trim();
      // 解码器能力缓存用同一套设备指纹校验（原生两个快照的 deviceKey 同源）。
      _decoderStore.currentDeviceKey = raw.trim();
    }
  }

  /// 缓存里的设备指纹与当前设备不一致 → 标记 stale，交由 [init] 触发重探测。
  void _checkCachedDeviceKey() {
    if (_deviceChecked) return;
    _deviceChecked = true;
    final snapshot = _capabilities;
    final String? current = _store.currentDeviceKey;
    if (snapshot == null || current == null || current.isEmpty) return;
    if (snapshot.deviceKey == current) return;
    _cacheStale = true;
    debugPrint(
      '[$_tag] 能力缓存设备指纹不一致（缓存=${snapshot.deviceKey} 当前=$current）',
    );
  }

  /// 让路原因：优先级从高到低，返回文案即 UI 展示文案。
  String? _resolveYieldReason() {
    final String? natural = _computeNaturalReason();
    final String? forced = _forceReason;
    if (forced != null) {
      // 条件器已复现同一原因 → 保留。
      if (natural == forced) return forced;
      // 宽限窗口内条件器还没反映（原生状态滞后）→ 继续钉住；若有其它真实冲突原因，
      // 直接用它（都处于挂起态，只是文案更准确）。
      final DateTime? setAt = _forceSetAt;
      final bool withinGrace = setAt != null &&
          DateTime.now().difference(setAt) < forceSuspendGrace;
      if (withinGrace) {
        return natural ?? forced;
      }
      // 宽限已过且条件没复现：说明那次切换失败/已结束 → 释放钉住。
      _forceReason = null;
      _forceSetAt = null;
    }
    return natural;
  }

  String? _computeNaturalReason() {
    if (_swipeExitEnabled) return '划掉后台自动退出已开启';
    if (_hit(dspActive)) return '蝰蛇母带已开启';
    if (_hit(equalizerActive)) return '均衡器已开启';
    if (_hit(volumeNormalizationActive)) return '音量均衡已开启';
    if (_hit(spectrumCapturing)) return '音乐频谱采集中';
    if (_hit(stemSeparationActive)) return '端侧分离中';
    if (!(speedIsNormal?.call() ?? true)) return '当前不在 1.0 倍速';
    if (_hit(usbOrDirectPcmActive)) return 'USB 独占输出已开启';
    if (_hit(crossfadeEnabled)) return '交叉淡化已开启';
    return null;
  }

  bool _hit(bool Function()? condition) => condition?.call() ?? false;

  /// 下发开关给原生；返回值即原生最新 status map。
  Future<void> _push(bool enabled) async {
    _cancelVerify();
    _pendingApply = false;
    _hasPushed = true;
    _pushedEffective = enabled;
    if (!supportsAudioOffload) return;
    if (enabled) _fallbackApplied = false;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'setEnabled',
        <String, dynamic>{'enabled': enabled},
      );
      if (result != null && result.isNotEmpty) {
        _applyStatus(Map<String, dynamic>.from(result));
      }
      debugPrint(
        '[$_tag] setEnabled=$enabled offloaded=$offloaded '
        'failed=$platformFailed sleeping=$sleeping',
      );
    } catch (e) {
      debugPrint('[$_tag] setEnabled($enabled) 失败: $e');
      return;
    }
    if (enabled) _scheduleVerify();
  }

  /// 400ms 后校验：开了但既没 offloaded 也没 failed → 请求重建输出兜底一次。
  void _scheduleVerify() {
    _verifyTimer?.cancel();
    _verifyTimer = Timer(_verifyDelay, () {
      _verifyTimer = null;
      if (!_pushedEffective) return;
      if (offloaded || platformFailed) return;
      if (_fallbackApplied) return;
      _fallbackApplied = true;
      debugPrint('[$_tag] 400ms 未 offloaded，请求重建输出兜底: status=$_status');
      unawaited(_requestRebuild());
    });
  }

  Future<void> _requestRebuild() async {
    final requester = rebuildRequester;
    if (requester == null) return;
    try {
      await requester();
    } catch (e) {
      debugPrint('[$_tag] 重建输出失败: $e');
    }
  }

  void _cancelVerify() {
    _verifyTimer?.cancel();
    _verifyTimer = null;
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }
}

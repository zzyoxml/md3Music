import 'dart:async';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_models.dart'
    show loudnessForUrl, warmLoudnessCache;
import 'volume_normalization_service.dart';

/// 短暂失去音频焦点（如来电、语音助手等临时中断）时的处理策略。
enum AudioFocusInterruptionMode {
  /// 保持当前音量与播放状态：不暂停、不降音量、不做任何响应。
  keepPlaying,

  /// 暂停播放，重新获得焦点后自动恢复（仅恢复被中断打断的播放，不覆盖用户主动暂停）。
  pauseAndResume,

  /// 临时降低音量（降到 [AudioService] 的 duck 音量），重新获得焦点后恢复原音量。
  duckAndRestore,
}

/// 音频焦点中断的决策动作（纯逻辑层，便于单测）。
sealed class AudioFocusAction {
  const AudioFocusAction();
}

/// 不做任何响应：保持当前音量与播放状态。
class KeepPlayingAction extends AudioFocusAction {
  const KeepPlayingAction();
}

/// 降低音量到 [targetVolume]（相对当前音量的 [kDuckVolumeRatio] 倍）。
class DuckVolumeAction extends AudioFocusAction {
  const DuckVolumeAction(this.targetVolume);
  final double targetVolume;
}

/// 恢复 [targetVolume]（中断前记录的原始音量）。
class RestoreVolumeAction extends AudioFocusAction {
  const RestoreVolumeAction(this.targetVolume);
  final double targetVolume;
}

/// 暂停播放（调用方仅在正在播放时执行）。
class PausePlaybackAction extends AudioFocusAction {
  const PausePlaybackAction();
}

/// 尝试恢复播放（调用方内部校验「中断暂停」标志与播放器就绪态）。
class ResumePlaybackAction extends AudioFocusAction {
  const ResumePlaybackAction();
}

/// duck 降音量的相对比例（当前音量的 0.5 倍）。
const double kDuckVolumeRatio = 0.5;

/// 决策函数：按 [mode] 策略与中断事件，返回应执行的动作。
///
/// 纯函数（无副作用、不触碰播放器），由 AudioService 的
/// interruptionEventStream 监听器调用并执行返回的动作，
/// 使三模式策略逻辑可独立单测。
AudioFocusAction decideInterruptionAction({
  required AudioFocusInterruptionMode mode,
  required bool begin,
  required AudioInterruptionType type,
  required bool isPlaying,
  required double currentVolume,
  double? volumeBeforeDuck,
}) {
  if (!begin) {
    // —— 中断结束 ——
    if (type == AudioInterruptionType.duck) {
      switch (mode) {
        case AudioFocusInterruptionMode.keepPlaying:
          return const KeepPlayingAction();
        case AudioFocusInterruptionMode.pauseAndResume:
          // duck 型中断（如导航提示）结束时同样尝试恢复被中断的播放
          return const ResumePlaybackAction();
        case AudioFocusInterruptionMode.duckAndRestore:
          return RestoreVolumeAction(volumeBeforeDuck ?? currentVolume);
      }
    }
    switch (mode) {
      case AudioFocusInterruptionMode.keepPlaying:
        return const KeepPlayingAction();
      case AudioFocusInterruptionMode.pauseAndResume:
        return const ResumePlaybackAction();
      case AudioFocusInterruptionMode.duckAndRestore:
        return RestoreVolumeAction(volumeBeforeDuck ?? currentVolume);
    }
  }

  // —— 中断开始 ——
  if (type == AudioInterruptionType.duck) {
    switch (mode) {
      case AudioFocusInterruptionMode.keepPlaying:
        // 保持播放、保持音量
        return const KeepPlayingAction();
      case AudioFocusInterruptionMode.pauseAndResume:
        // 「暂停后自动恢复」对 duck 型中断（导航提示音等）同样暂停，
        // 中断结束后自动恢复（用户明确预期：选了暂停就暂停）
        return isPlaying
            ? const PausePlaybackAction()
            : const KeepPlayingAction();
      case AudioFocusInterruptionMode.duckAndRestore:
        return isPlaying
            ? DuckVolumeAction(currentVolume * kDuckVolumeRatio)
            : const KeepPlayingAction();
    }
  }
  // pause / unknown 开始
  switch (mode) {
    case AudioFocusInterruptionMode.keepPlaying:
      return const KeepPlayingAction(); // 保持播放、保持音量
    case AudioFocusInterruptionMode.pauseAndResume:
      return isPlaying
          ? const PausePlaybackAction()
          : const KeepPlayingAction();
    case AudioFocusInterruptionMode.duckAndRestore:
      // 暂停型中断也改为降音量处理：播放不中断，仅压低音量
      return isPlaying
          ? DuckVolumeAction(currentVolume * kDuckVolumeRatio)
          : const KeepPlayingAction();
  }
}

/// —— 交叉淡化（crossfade）纯逻辑层 ——
/// 与 [decideInterruptionAction] 同风格：无副作用、不触碰播放器，便于单测。

/// 交叉淡化的等功率（equal-power）增益。[t] 为淡化进度（0 = 刚开始，1 = 完成）。
///
/// 用 cos/sin 而非线性斜坡：两路互不相关的音频叠加时功率相加，线性淡化在中点
/// 幅度只有 0.5+0.5，听感上是一个约 -3dB 的音量塌陷。cos/sin 让
/// outGain² + inGain² 恒为 1，整段淡化的响度保持平稳。
({double outGain, double inGain}) crossfadeGains(double t) {
  final clamped = t.clamp(0.0, 1.0);
  final angle = clamped * math.pi / 2;
  return (outGain: math.cos(angle), inGain: math.sin(angle));
}

/// 当前 position tick 应进入的 crossfade 阶段。
enum CrossfadePhase {
  /// 什么都不做。
  idle,

  /// 解析下一首播放地址并加载到备用播放器预缓冲（不出声）。
  prepare,

  /// 立即开始双路音量斜坡。
  start,
}

/// 预加载提前量：真正开始淡化之前多留这么久用于解析链接 + 缓冲。
const Duration kCrossfadePrepareLead = Duration(seconds: 3);

/// 曲子短于 `crossfadeDuration * 2 + kCrossfadeMinTailroom` 时不做叠加
/// （否则淡化会吃掉大半首歌）。
const Duration kCrossfadeMinTailroom = Duration(seconds: 2);

/// 「当前歌曲」在淡化进度到达该比例时切给新歌（0.5 = 等响度交叉点）。
///
/// 一开始就切会让界面/歌词写着下一首、而听到的主体还是正在淡出的上一首；
/// 等到彻底淡完才切又会让歌词明显滞后。取中点：哪首声音大就显示哪首。
const double kCrossfadeCrossoverProgress = 0.5;

/// 按当前播放进度决定 crossfade 阶段。
///
/// [enabled] 由调用方汇总所有前置条件（设置开关、平台、循环模式、
/// 是否列表末尾、USB 独占是否开启等）；本函数只负责时间轴上的判断。
CrossfadePhase decideCrossfadePhase({
  required Duration position,
  required Duration? duration,
  required Duration crossfadeDuration,
  required bool enabled,
  required bool prepared,
  required bool fading,
}) {
  if (!enabled || fading) return CrossfadePhase.idle;
  if (crossfadeDuration <= Duration.zero) return CrossfadePhase.idle;
  if (duration == null || duration <= Duration.zero) return CrossfadePhase.idle;
  if (duration < crossfadeDuration * 2 + kCrossfadeMinTailroom) {
    return CrossfadePhase.idle;
  }
  final remaining = duration - position;
  // 已经越过结尾（异常/兜底路径）：交给原有 completed 流程处理
  if (remaining <= Duration.zero) return CrossfadePhase.idle;
  if (remaining <= crossfadeDuration) {
    // 到点了。预加载没来得及完成就先补一次 prepare，下一 tick 再开始。
    return prepared ? CrossfadePhase.start : CrossfadePhase.prepare;
  }
  if (!prepared && remaining <= crossfadeDuration + kCrossfadePrepareLead) {
    return CrossfadePhase.prepare;
  }
  return CrossfadePhase.idle;
}

/// 音频焦点 / 音频会话管理。
///
/// 关键设计：
/// - [_pausedByInterruption]：标记“暂停是由音频焦点丢失引起的”。
///   仅在这种情况下才在重新获得焦点时自动恢复播放，
///   避免覆盖用户主动的暂停。
/// - 区分临时中断（pause / unknown → 之后会自动恢复）和永久丢失
///   （如电话来电、强制中断），后者由 audio_session 标记 `dispose` 状态。
/// - 交叉淡化需要两路音频同时出声，因此内部持有**两个** [AudioPlayer]
///   （主 + 辅），轮流承担"当前歌曲"。对外暴露的所有 stream 都从
///   [_activePlayer] 转发，上层（PlayerProvider）一次订阅、角色互换时无需重连。
class AudioService {
  static final AudioService _instance = AudioService._internal();

  factory AudioService() => _instance;

  AudioService._internal() {
    _mainPlayer = _createPlayer(enhancer: _mainEnhancer);
    _activePlayer = _mainPlayer;
    _bindActiveStreams();
    _watchSessionIds(_mainPlayer);
    _restoreVolumeNormalizationFromPrefs();
  }

  /// 启动时从持久化设置恢复音量均衡开关/参考响度并应用（不依赖打开设置页）。
  Future<void> _restoreVolumeNormalizationFromPrefs() async {
    try {
      // 预热历史响度缓存（url→响度），使历史回放也能取到响度。
      await warmLoudnessCache();
      final prefs = await SharedPreferences.getInstance();
      _vnEnabled = prefs.getBool('settings_volume_normalization_enabled') ?? false;
      _vnReferenceLufs =
          (prefs.getDouble('settings_volume_normalization_lufs') ??
                  VolumeNormalizationService.defaultReferenceLufs)
              .clamp(-20.0, -8.0);
      await _applyNormalizationGainActive();
    } catch (_) {}
  }

  /// 创建播放器实例。[aux] 为交叉淡化用的辅播放器。
  static AudioPlayer _createPlayer({
    bool aux = false,
    AndroidLoudnessEnhancer? enhancer,
  }) =>
      AudioPlayer(
        // 关闭 just_audio 内置的中断处理（handleInterruptions=false）：
        // 所有音频焦点策略统一由本服务按 AudioFocusInterruptionMode 处理，
        // 避免两套逻辑叠加导致重复暂停/恢复。
        handleInterruptions: false,
        // MD3Music fork: 关闭 just_audio 对 audio_session 的自动激活。
        // 焦点由 Media3 的 AudioFocusManager 唯一管理（handleAudioFocus=true），
        // audio_session 保持 setActive(false)；否则播放时会重新激活 audio_session
        // 抢回焦点，与 Media3 交替 request/abandon 导致播放反复暂停。
        handleAudioSessionActivation: false,
        // 辅播放器不下发 AndroidAudioAttributes → fork 的 Java 侧永不执行
        // player.setAudioAttributes(attrs, /* handleAudioFocus */ true)，
        // 因此辅播放器**不请求音频焦点**：否则同一个 app 的第二次焦点请求会让
        // 主播放器收到 AUDIOFOCUS_LOSS，淡出的那一路会被 Media3 直接掐掉。
        androidApplyAudioAttributes: !aux,
        // MD3Music fork: 辅播放器跳过 MediaSession 创建（避免系统看到两个活跃
        // 媒体会话），并与主播放器共享同一个 audioSessionId（均衡器/频谱在
        // 淡化全程对两路音频同时生效）。
        androidAuxPlayer: aux,
        // 音量均衡：挂一个 LoudnessEnhancer 用于放大安静歌（跨引擎、Dart 侧可靠）。
        audioPipeline: enhancer != null
            ? AudioPipeline(androidAudioEffects: [enhancer])
            : null,
        // Media3 (just_audio 0.10.x) 下缓冲区默认值已较合理，
        // 这里适度收紧：maxBuffer 从 60s 降到 30s（减少内存占用），
        // rebuffer 从 10s 降到 3s（缩短欠载后恢复等待，用户体验更流畅）。
        audioLoadConfiguration: AudioLoadConfiguration(
          androidLoadControl: AndroidLoadControl(
            minBufferDuration: Duration(seconds: 15),
            maxBufferDuration: Duration(seconds: 30),
            bufferForPlaybackDuration: Duration(seconds: 2),
            bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
          ),
        ),
        // 注意：关闭 float 输出由 fork Java 侧统一处理
      );

  /// 主播放器：始终存在，是音频焦点与 MediaSession 的持有者。
  // 音量均衡放大用 LoudnessEnhancer（先声明，供主播放器创建时注入）。
  final AndroidLoudnessEnhancer _mainEnhancer = AndroidLoudnessEnhancer();
  late final AudioPlayer _mainPlayer;

  /// 辅播放器：首次交叉淡化时才创建（未开启该功能的用户零开销）。
  AudioPlayer? _auxPlayer;

  /// 当前承担"当前歌曲"的播放器，对外 stream / position / duration 的来源。
  late AudioPlayer _activePlayer;

  /// 当前活动播放器的队列源。每次 [setPlaylist] 新建一个实例：
  /// 一个 ConcatenatingAudioSource 不能同时 attach 到两个播放器上。
  ConcatenatingAudioSource? _activeSource;

  /// 用户设置的音量（0..1）。淡化斜坡以它为上限。
  double _userVolume = 1.0;

  // ── 音量均衡（响度归一）状态与增益应用 ──
  /// 当前曲目集总响度（LUFS），无则 null。
  double? _vnLufs;
  /// 当前曲目真峰值（dBTP/dBFS），无则 null。
  double? _vnPeakDb;
  /// 音量均衡开关。
  bool _vnEnabled = false;
  /// 参考响度（LUFS），默认 -14。
  double _vnReferenceLufs = VolumeNormalizationService.defaultReferenceLufs;

  /// 设置当前曲目的响度元数据并重新计算增益。
  Future<void> setTrackLoudness({double? lufs, double? peakDb}) async {
    _vnLufs = lufs;
    _vnPeakDb = peakDb;
    await _applyNormalizationGainActive();
  }

  /// 音量均衡开关/参考响度变化时，对当前曲目重新计算并应用增益。
  Future<void> setVolumeNormalization({bool? enabled, double? referenceLufs}) async {
    if (enabled != null) _vnEnabled = enabled;
    if (referenceLufs != null) _vnReferenceLufs = referenceLufs;
    await _applyNormalizationGainActive();
  }

  /// 计算当前应生效的归一增益（dB）；未开启或无响度时为 0（旁路）。
  double _currentNormalizationGainDb() => _vnEnabled
      ? VolumeNormalizationService.calcGainDb(
          lufs: _vnLufs,
          peakDb: _vnPeakDb,
          referenceLufs: _vnReferenceLufs,
        )
      : 0;

  /// 音量均衡衰减倍率（gainDb<0 时折进音量，ExoPlayer 只能衰减；>0 留给 enhancer 放大）。
  double _vnAttenLinear = 1.0;

  /// 应用增益：正增益（放大）走 native LoudnessEnhancer，负增益（衰减）折进音量。
  /// 只用一个 enhancer：主/辅播放器共享同一 audio session，一个 LoudnessEnhancer
  /// 作用于该 session 即可覆盖两路音频（避免同 session 创建第二个 enhancer 冲突）。
  Future<void> _applyGain(double gainDb) async {
    final boost = gainDb > 0 ? gainDb : 0.0;
    _vnAttenLinear = gainDb < 0 ? math.pow(10, gainDb / 20).toDouble() : 1.0;
    // effect 默认 disabled，需先 enable 才真正生效（未激活时仅记录标志，加载后应用）
    try {
      await _mainEnhancer.setEnabled(true);
      await _mainEnhancer.setTargetGain(boost);
    } catch (e) {
      // ignore: avoid_print
      print('[音量均衡] enhancer apply failed: $e');
    }
  }

  Future<void> _applyNormalizationGainActive() async {
    await _applyGain(_currentNormalizationGainDb());
    // 非淡化中才落音量衰减，避免打断跨 fade 的斜坡
    if (!_crossfading) {
      await _activePlayer.setVolume(_userVolume * _vnAttenLinear);
    }
  }

  Future<void> _applyNormalizationGainTo(AudioPlayer p) async {
    await _applyGain(_currentNormalizationGainDb());
  }

  AudioPlayer get player => _activePlayer;

  // —— 对外 stream：从 _activePlayer 转发 ——
  // just_audio 的这些流都是 ValueStream（订阅即回放当前值），
  // 因此角色互换后重新订阅能立刻拿到新播放器的 position/duration/playing。
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration?>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();
  final _playerStateCtl = StreamController<PlayerState>.broadcast();
  final _sequenceStateCtl = StreamController<SequenceState?>.broadcast();
  final _speedCtl = StreamController<double>.broadcast();
  final List<StreamSubscription<dynamic>> _activeSubs = [];

  void _bindActiveStreams() {
    for (final sub in _activeSubs) {
      // ignore: discarded_futures
      sub.cancel();
    }
    _activeSubs.clear();
    final p = _activePlayer;
    void ignoreError(Object _) {}
    _activeSubs.addAll(<StreamSubscription<dynamic>>[
      p.positionStream.listen(_positionCtl.add, onError: ignoreError),
      p.durationStream.listen(_durationCtl.add, onError: ignoreError),
      p.playingStream.listen(_forwardPlaying, onError: ignoreError),
      p.playerStateStream.listen(_playerStateCtl.add, onError: ignoreError),
      p.sequenceStateStream.listen(_sequenceStateCtl.add, onError: ignoreError),
      p.speedStream.listen(_speedCtl.add, onError: ignoreError),
    ]);
  }

  /// 转发 playing。淡化刚开始时会短暂读到 `false`：`play()` 在 Dart 层是
  /// 先 add(playing:true) 再异步落到 playingSubject，而角色互换紧随其后，
  /// 重新订阅时回放到的可能还是互换前的 false。淡化期间新播放器必然在播，
  /// 直接吞掉这个瞬时 false，避免上层出现「暂停一帧」（通知栏闪、WakeLock 抖动）。
  /// 淡化中被真正暂停的路径都会先 [abortCrossfade] 清掉标志，不受影响。
  void _forwardPlaying(bool playing) {
    if (!playing && _crossfading) return;
    _playingCtl.add(playing);
  }

  Stream<Duration> get positionStream => _positionCtl.stream;

  Stream<Duration?> get durationStream => _durationCtl.stream;

  Stream<bool> get playingStream => _playingCtl.stream;

  Stream<PlayerState> get playerStateStream => _playerStateCtl.stream;

  ProcessingState get processingState => _activePlayer.processingState;

  Stream<SequenceState?> get sequenceStateStream => _sequenceStateCtl.stream;

  Stream<double> get speedStream => _speedCtl.stream;

  bool get playing => _activePlayer.playing;

  Duration get position => _activePlayer.position;

  Duration? get duration => _activePlayer.duration;

  double get speed => _activePlayer.speed;

  /// Android 音频会话 ID，供均衡器绑定使用。
  /// just_audio 0.9.x 在播放器初始化后才会有值。
  int? get androidAudioSessionId => _mainPlayer.androidAudioSessionId;

  /// 主 / 辅播放器各自的 audio session ID（已就绪、去重）。
  ///
  /// 主辅播放器**不共用会话**（见 fork 内 AudioPlayer.ensurePlayerInitialized
  /// 注释：共用会话时 MIUI 会让两路音量斜坡串台），因此均衡器必须为每个 id 各挂
  /// 一个实例，淡化全程两路才都走音效。
  List<int> get androidAudioSessionIds {
    final ids = <int>[];
    final aux = _auxPlayer;
    for (final p in <AudioPlayer>[_mainPlayer, if (aux != null) aux]) {
      final id = p.androidAudioSessionId;
      if (id != null && id != 0 && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  /// [androidAudioSessionIds] 变化时广播：辅播放器首次创建、
  /// 或某个播放器的平台重新激活换了 id（此时旧 id 上的音效需要重绑）。
  final _sessionIdsCtl = StreamController<List<int>>.broadcast();
  Stream<List<int>> get androidAudioSessionIdsStream => _sessionIdsCtl.stream;

  final List<StreamSubscription<int?>> _sessionIdSubs = [];

  void _watchSessionIds(AudioPlayer p) {
    _sessionIdSubs.add(p.androidAudioSessionIdStream.listen(
      (_) {
        if (!_sessionIdsCtl.isClosed) _sessionIdsCtl.add(androidAudioSessionIds);
      },
      onError: (Object _) {},
    ));
  }

  /// 是否完全忽略音频焦点：开启后不响应任何中断事件
  /// （来电 / 导航 / 拔耳机等），保持音量与播放状态不变。
  bool _ignoreAudioFocus = false;
  bool get ignoreAudioFocus => _ignoreAudioFocus;
  void setIgnoreAudioFocus(bool value) {
    _ignoreAudioFocus = value;
    // native：忽略模式跳过 Media3 内置焦点处理（不 duck/不暂停/不 abandon），
    // 播放与音量完全保持——否则独占型中断（如 B 站视频 GAIN → 本端 LOSS）
    // 会被 Media3 强制暂停，忽略开关形同虚设。
    // ignore: discarded_futures
    _mainPlayer.setIgnoreAudioFocus(value);
    // 同步 forced / keepPlaying 标志（忽略时强制不自动 duck）
    _syncNativeFocusFlags();
  }

  /// 短暂失去音频焦点时的处理策略（默认：暂停后自动恢复）。
  AudioFocusInterruptionMode _interruptionMode =
      AudioFocusInterruptionMode.pauseAndResume;
  AudioFocusInterruptionMode get interruptionMode => _interruptionMode;
  void setInterruptionMode(AudioFocusInterruptionMode mode) {
    _interruptionMode = mode;
    _syncNativeFocusFlags();
  }

  /// 同步 native 焦点处理标志（Media3 AudioFocusManager）。
  ///
  /// 只发给主播放器：fork 的 Java 侧这两个标志是全进程 static，
  /// 辅播放器本身也不请求焦点，重复下发没有意义。
  ///
  /// - [AudioFocusInterruptionMode.keepPlaying]（非忽略时）：skip Media3 内置处理，
  ///   播放与进度完全保持——避免 suppression 无声导致 MediaSession 进度错开
  /// - forced willPauseWhenDucked：忽略 / keepPlaying / pauseAndResume → true
  ///   （系统派发 LOSS_TRANSIENT 事件而非自动 duck 音量）；duckAndRestore → false
  ///   （系统级自动 duck 0.2 → 自动恢复）
  void _syncNativeFocusFlags() {
    final keepPlayingActive = !_ignoreAudioFocus &&
        _interruptionMode == AudioFocusInterruptionMode.keepPlaying;
    // ignore: discarded_futures
    _mainPlayer.setForceKeepPlaying(keepPlayingActive);
    // ignore: discarded_futures
    _mainPlayer.setForceWillPauseWhenDucked(
        _ignoreAudioFocus ||
            _interruptionMode != AudioFocusInterruptionMode.duckAndRestore);
  }

  /// Media3 AudioFocusManager 原始焦点事件订阅（真实系统事件，先于 Media3
  /// 自动 duck/pause 处理发出）。keepPlaying 模式据此对抗自动暂停。
  ///
  /// 焦点永远由主播放器持有（辅播放器 androidApplyAudioAttributes=false，
  /// 不请求焦点），所以事件源固定是主播放器，不随角色互换改变。
  StreamSubscription<int>? _media3FocusSub;

  Future<void> init() async {
    await _mainPlayer.setLoopMode(LoopMode.off);
    await _configureAudioSession();
    // MD3Music fork: 焦点事件源改为 Media3 AudioFocusManager 转发
    // （audio_session 的 interruptionEventStream 已停用，见 _configureAudioSession）
    _media3FocusSub =
        _mainPlayer.audioFocusChangeStream.listen(_handleMedia3FocusChange);
  }

  /// 是否因为音频焦点中断而暂停（pauseAndResume 模式）。
  /// 仅中断引起的暂停在 GAIN 时自动恢复；用户主动暂停会清除该标记。
  bool _pausedByInterruption = false;

  /// Media3 焦点事件入口（Android AudioManager 原始 focusChange 值）：
  /// 1=GAIN, -1=LOSS, -2=LOSS_TRANSIENT, -3=LOSS_TRANSIENT_CAN_DUCK。
  ///
  /// 三模式行为（Android 15 机制）：
  /// - keepPlaying：Media3 抑制播放（playbackSuppressionReason，音量不变），
  ///   Dart 不干预（playWhenReady 保持），GAIN 自动恢复。
  /// - pauseAndResume：主动 pause() 让 UI 正确显示暂停并标记「中断暂停」，
  ///   GAIN 时恢复播放（不覆盖用户主动暂停）。
  /// - duckAndRestore：forced=false → 系统级自动 duck（VolumeShaper 0.2→恢复），无需干预。
  ///
  /// 暂停/恢复一律作用于 [_activePlayer]：交叉淡化后活动播放器可能是辅播放器，
  /// 而焦点事件仍从主播放器来，作用于主播放器只会暂停一路已静音的音频。
  /// 中断时先 [abortCrossfade]，否则被淡出的那一路会继续响。
  void _handleMedia3FocusChange(int focusChange) {
    // 忽略模式：native 已跳过 Media3 内置处理（不 duck/不暂停/不 abandon），
    // 播放与音量完全保持，此处不干预。独占型中断（B 站等）的系统级强制
    // interruptMusicPlayback 依赖「播放器与 MediaSession 关联」（audioSessionId
    // 固定已由 fork 处理）；不在此对抗 play()——实测会与对方 app 反复抢焦点
    // 导致音频叠加错乱。
    if (_ignoreAudioFocus) return;
    if (_interruptionMode == AudioFocusInterruptionMode.keepPlaying) {
      // keepPlaying：短暂中断（导航等 transient/duck）native 已 skip（保持播放
      // 有声、进度一致）。独占型 LOSS（B 站视频 / 来电等）主动暂停让路——
      // native 对 LOSS 正常走 Media3 DO_NOT_PLAY；此处同步 Dart 状态并留痕，
      // 确认独占中断事件是否可达（小米可能直接 interrupt AudioTrack 不派发事件）。
      if (focusChange == -1) {
        // ignore: avoid_print
        print('[AudioFocus] keepPlaying LOSS, playing=${_activePlayer.playing}');
        abortCrossfade();
        if (_activePlayer.playing) {
          // ignore: discarded_futures
          _activePlayer.pause();
        }
      }
      return;
    }
    if (_interruptionMode == AudioFocusInterruptionMode.pauseAndResume) {
      if (focusChange != 1) {
        abortCrossfade();
        if (_activePlayer.playing) {
          _pausedByInterruption = true;
          // ignore: discarded_futures
          _activePlayer.pause();
        }
      } else if (_pausedByInterruption) {
        _pausedByInterruption = false;
        // ignore: discarded_futures
        _activePlayer.play();
      }
    }
  }

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      // MD3Music fork: 停用 audio_session 的音频焦点请求（setActive(false)）。
      // 焦点由 Media3 的 AudioFocusManager 唯一持有（handleAudioFocus=true），
      // 原始事件经 just_audio fork 转发到 audioFocusChangeStream；避免双焦点
      // 内斗（Media3 与 audio_session 交替 request/abandon 导致播放反复暂停）。
      // 拔耳机由 Media3 的 becomingNoisy 自动暂停（不标记可自动恢复）。
      await session.setActive(false);
    } catch (e) {
      // P2-2: 焦点/会话配置失败必须留痕，否则无法用 logcat 排障
      // ignore: avoid_print
      print('[AudioFocus] configure audio session failed: $e');
    }
  }

  Future<void> play() async {
    // 用户主动播放：清除中断暂停标记（避免后续无关 GAIN 误恢复）
    _pausedByInterruption = false;
    await _activePlayer.play();
  }

  Future<void> pause() async {
    // 用户主动暂停：清除中断暂停标记（中断引起的暂停不在 GAIN 时自动恢复）
    _pausedByInterruption = false;
    // 淡化进行中被暂停：先收掉正在淡出的那一路，否则它会继续响
    abortCrossfade();
    await _activePlayer.pause();
  }

  Future<void> stop() async {
    abortCrossfade();
    await _mainPlayer.stop();
    final aux = _auxPlayer;
    if (aux != null) await aux.stop();
  }

  Future<void> seek(Duration position) async {
    abortCrossfade();
    await _activePlayer.seek(position);
  }

  Future<void> setUrl(
    String url, {
    double? loudnessLufs,
    double? loudnessPeakDb,
  }) async {
    abortCrossfade();
    // 音量均衡响度：歌曲未带响度时，回退查「url → 响度」缓存（KugouPlayUrl 解析时记录）
    if (loudnessLufs == null) {
      final cached = loudnessForUrl(url);
      loudnessLufs = cached?.lufs;
      loudnessPeakDb = cached?.peak;
    }
    _vnLufs = loudnessLufs;
    _vnPeakDb = loudnessPeakDb;
    await _activePlayer.setUrl(url, headers: const {});
    await _applyNormalizationGainActive();
  }

  /// 设置用户音量（0..1）。淡化斜坡以它为上限。
  Future<void> setVolume(double volume) async {
    _userVolume = volume.clamp(0.0, 1.0);
    // 淡化中不要打断斜坡：新音量在斜坡结束时自然生效
    // 叠加音量均衡的衰减倍率（响歌压低）
    if (_crossfading) return;
    await _activePlayer.setVolume(_userVolume * _vnAttenLinear);
  }

  Future<void> setPlaylist(
    List<UriAudioSource> sources, {
    int startIndex = 0,
  }) async {
    abortCrossfade();
    // 每次新建实例：一个 ConcatenatingAudioSource 不能同时 attach 到两个
    // 播放器上，而活动播放器会在交叉淡化时互换。
    final playlistSource = ConcatenatingAudioSource(children: []);
    if (sources.isNotEmpty) {
      playlistSource.addAll(sources);
    }
    _activeSource = playlistSource;
    await _activePlayer.setAudioSource(
      playlistSource,
      initialIndex: startIndex,
      initialPosition: Duration.zero,
    );
  }

  Future<void> addAudioSource(UriAudioSource source) async {
    await _activeSource?.add(source);
  }

  Future<void> addAllAudioSources(List<UriAudioSource> sources) async {
    await _activeSource?.addAll(sources);
  }

  /// 在指定位置插入音频源，不打断当前播放。
  /// 用于"下一首播放"等需要在队列中间插入的场景。
  Future<void> insertAudioSourceAt(int index, UriAudioSource source) async {
    await _activeSource?.insert(index, source);
  }

  Future<void> setSpeed(double speed) async {
    await _activePlayer.setSpeed(speed);
    // 辅播放器同步倍速，避免淡入的那一首用回默认 1.0
    final aux = _auxPlayer;
    if (aux != null && aux != _activePlayer) {
      try {
        await aux.setSpeed(speed);
      } catch (_) {}
    }
  }

  Future<void> seekToNext() async {
    abortCrossfade();
    await _activePlayer.seekToNext();
  }

  Future<void> seekToPrevious() async {
    abortCrossfade();
    await _activePlayer.seekToPrevious();
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _activePlayer.setLoopMode(mode);
  }

  Future<void> setShuffleModeEnabled(bool enabled) async {
    await _activePlayer.setShuffleModeEnabled(enabled);
  }

  // ===================== 交叉淡化（crossfade） =====================

  /// 竞态 token：每次新的淡化/中止自增，进行中的斜坡循环检测到过期即中止。
  int _crossfadeToken = 0;
  bool _crossfading = false;

  /// 外部可订阅的 crossfade 状态流（sync 广播）。
  /// 供 EqualizerService 在小米设备上实现旁路：淡化开始前置位 true、结束复位 false，
  /// bypass 先于出声。
  final _crossfadingCtl = StreamController<bool>.broadcast();
  Stream<bool> get crossfadingStream => _crossfadingCtl.stream;

  /// 正在淡出的播放器（淡化结束或中止时回收）。
  AudioPlayer? _fadingOutPlayer;

  /// 正在淡入的播放器（中点前被中止时要把它收掉）。
  AudioPlayer? _fadingInPlayer;

  /// 是否已经过了交叉点（活动播放器已切给新歌）。
  bool _crossedOver = false;

  /// 已经 [prepareCrossfade] 成功、等待起播的播放器。
  AudioPlayer? _preparedPlayer;



  /// abortCrossfade 里 fire-and-forget 的 retire 链（pause→seek0→恢复音量）。
  /// prepareCrossfade 复用同一播放器前必须先等它收尾：否则迟到的
  /// setVolume(_userVolume) 可能落在 prepare 的 setVolume(0) 之后，
  /// 新歌以全音量起播再被斜坡压回——听感像淡化反向的开端。
  Future<void>? _retireInFlight;

  bool get isCrossfading => _crossfading;

  void _setCrossfading(bool v) {
    if (_crossfading == v) return;
    _crossfading = v;
    _crossfadingCtl.add(v);
  }

  /// 当前不承担"当前歌曲"的那个播放器（首次使用时创建辅播放器）。
  AudioPlayer _standbyPlayer() {
    if (_activePlayer == _mainPlayer) {
      final existing = _auxPlayer;
      if (existing != null) return existing;
      final aux = _createPlayer(aux: true);
      _auxPlayer = aux;
      // 辅播放器有独立会话，它的 id 一就绪就要通知均衡器去挂第二个实例
      _watchSessionIds(aux);
      return aux;
    }
    return _mainPlayer;
  }

  /// 把 [url] 加载到备用播放器并预缓冲，音量 0、不出声。
  ///
  /// 返回 true 表示可以随后立即调用 [startCrossfade]。
  /// [title]/[artist]/[artUri]：新歌元数据，加载到备用播放器时带 artUri，
  Future<bool> prepareCrossfade(
    String url, {
    double speed = 1.0,
    String? id,
    String? title,
    String? artist,
    String? artUri,
    double? loudnessLufs,
    double? loudnessPeakDb,
  }) async {
    if (_crossfading) return false;
    try {
      final standby = _standbyPlayer();
      // 淡入段响度即正确：预加载时设置新歌的归一增益（旧歌保持各自增益直至淡出）。
      _vnLufs = loudnessLufs;
      _vnPeakDb = loudnessPeakDb;
      await _applyNormalizationGainTo(standby);
      // 上一次 abort 留下的 retire 链（pause→seek0→恢复音量）若还在飞，
      // 必须先等它收尾再把这个播放器重新拉去当淡入方——否则 retire 末尾的
      // setVolume(_userVolume) 会落在下面的 setVolume(0) 之后，新歌以全音量
      // 起播再被斜坡压回，听感像淡化反向。
      final retire = _retireInFlight;
      if (retire != null) {
        _retireInFlight = null;
        await retire;
      }
      final isAux = standby != _mainPlayer;
      // ignore: avoid_print
      print('[Crossfade] 预加载到${isAux ? '辅' : '主'}播放器 …');
      await standby.setVolume(0);
      await standby.setLoopMode(LoopMode.off);
      await standby.setSpeed(speed);
      // setUrl 在加载完成后才返回，返回即可立即起播
      // 用带 artUri 的 AudioSource 加载：MediaSession 仅在 onMediaItemTransition 时
      // 同步系统封面（SystemUI 从 artUri 下载显示）；setUrl 无 artUri 时通知栏缺失封面，
      // 而 applySessionMetadata 的 bitmap 经 replaceMediaItem 注入不触发 MediaSession 同步。
      final artUriParsed = artUri != null ? Uri.tryParse(artUri) : null;
      final loaded = await standby.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          tag: {
            'id': id,
            'title': title ?? '',
            'artist': artist,
            'album': null,
            'artUri': artUriParsed?.toString(),
          },
        ),
      );
      _preparedPlayer = standby;
      // ignore: avoid_print
      print('[Crossfade] 预加载完成 dur=${loaded?.inSeconds}s');
      return true;
    } catch (e) {
      _preparedPlayer = null;
      // ignore: avoid_print
      print('[Crossfade] prepare 失败: $e');
      return false;
    }
  }

  /// 丢弃已预加载但尚未使用的备用播放器状态（手动切歌等场景）。
  void discardPreparedCrossfade() {
    _preparedPlayer = null;
  }

  /// 启动交叉淡化：备用播放器以 0 音量起播 → 新歌等功率渐入、旧歌等功率渐出
  /// → 进度到 [kCrossfadeCrossoverProgress] 时把活动播放器切给新歌并回调
  /// [onCrossover] → 结束后回收旧播放器。
  ///
  /// 活动播放器**在交叉点才切**，不是一开始就切：对外的 position / duration /
  /// playing 在中点前仍来自旧歌，上层显示的「当前歌曲」才能和听到的主体一致。
  /// 代价是旧歌若在中点前就播完，它的 completed 会被转发出去 —— 上层必须在
  /// 淡化进行中忽略 completed（见 PlayerProvider._handlePlaybackCompleted）。
  ///
  /// 必须先 [prepareCrossfade] 成功。[targetVolume] 是斜坡上限（用户音量）。
  Future<void> startCrossfade({
    required Duration duration,
    required double targetVolume,
    void Function()? onCrossover,
  }) async {
    final incoming = _preparedPlayer;
    if (incoming == null || _crossfading) return;
    final outgoing = _activePlayer;
    if (incoming == outgoing) return;
    _preparedPlayer = null;
    _userVolume = targetVolume;
    final token = ++_crossfadeToken;
    _setCrossfading(true);
    _crossedOver = true; // MD3Music fork：fade 起点即视为已过交叉点，循环内不再切换
    _fadingOutPlayer = outgoing;
    _fadingInPlayer = incoming;
    // ignore: avoid_print
    print('[Crossfade] start dur=${duration.inMilliseconds}ms vol=$targetVolume');
    try {
      await incoming.setVolume(0);
      if (token != _crossfadeToken) return;
      // 不 await play()：它的 Future 直到播放结束/暂停才完成
      // ignore: discarded_futures
      incoming.play();
      // MD3Music fork（方案A·fade 起点切歌）：起播后立即把活动播放器切给新歌（incoming），
      // 使对外的 currentSong/媒体卡片/蓝牙歌词/Lyricon 在 fade 一开始就基于下一首，
      // 避免切歌后媒体卡片/歌词卡在旧歌（原实现等到交叉点 t=0.5 才切）。
      _promoteIncoming(incoming, onCrossover);

      final steps = (duration.inMilliseconds / 100).clamp(20, 80).round();
      final stepMs = (duration.inMilliseconds / steps).round();
      final totalMs = duration.inMilliseconds;
      final started = DateTime.now();
      final outLabel = outgoing == _mainPlayer ? 'main' : 'aux';
      final inLabel = incoming == _mainPlayer ? 'main' : 'aux';
      int loggedQuartile = -1;
      while (true) {
        await Future<void>.delayed(Duration(milliseconds: stepMs));
        if (token != _crossfadeToken) return;
        // 进度按**真实经过时间**算，不是累加步数。切歌那一瞬 Dart 事件循环要
        // 跑 UI 重建 / 封面取色 / 预取，Future.delayed 会显著超时；累加步数会
        // 把斜坡越拖越长，表现为"规定时间到了还没淡完，最后突然跳回正常音量"。
        // 用 wall clock 后事件循环卡顿只让步子变粗，淡化始终按时收尾。
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        final t = totalMs <= 0 ? 1.0 : (elapsed / totalMs).clamp(0.0, 1.0);
        final gains = crossfadeGains(t);
        // 不 await：每步两次 MethodChannel 调用，串行 await 会把步长拉长
        // ignore: discarded_futures
        outgoing.setVolume(targetVolume * gains.outGain);
        // ignore: discarded_futures
        incoming.setVolume(targetVolume * gains.inGain);
        final quartile = (t * 4).floor();
        if (quartile != loggedQuartile) {
          loggedQuartile = quartile;
          // ignore: avoid_print
          print('[Crossfade] t=${t.toStringAsFixed(2)} '
              '$outLabel(out)=${(gains.outGain * targetVolume).toStringAsFixed(2)} '
              '$inLabel(in)=${(gains.inGain * targetVolume).toStringAsFixed(2)}');
        }
        if (t >= 1.0) break;
      }
      if (token != _crossfadeToken) return;
      // 用 _userVolume 而非入口捕获的 targetVolume：斜坡进行中用户调过音量
      // 时（AudioService.setVolume 淡化中只更新 _userVolume 提前返回），
      // 结束以最新音量收尾，否则会回跳淡化开始时的旧音量
      // ignore: avoid_print
      print('[Crossfade] 收尾 setVolume 后 activeIsMain=' + (_activePlayer == _mainPlayer).toString());
      await incoming.setVolume(_userVolume);
      await _retireFadedPlayer(outgoing);
      // ignore: avoid_print
      print('[Crossfade] 收尾 retire 后 activeIsMain=' + (_activePlayer == _mainPlayer).toString());
      // ignore: avoid_print
      print('[Crossfade] done');
    } catch (e) {
      // ignore: avoid_print
      print('[Crossfade] start 失败: $e');
    } finally {
      if (token == _crossfadeToken) {
        _setCrossfading(false);
        _fadingOutPlayer = null;
        _fadingInPlayer = null;
      }
    }
  }

  /// 交叉点：把活动播放器切给淡入方，对外 stream 改为跟随新歌，
  /// 并让上层同步「当前歌曲」账目（界面 / 歌词 / 通知栏）。
  void _promoteIncoming(AudioPlayer incoming, void Function()? onCrossover) {
    _crossedOver = true;
    _activePlayer = incoming;
    _bindActiveStreams();
    // ignore: avoid_print
    print('[Crossfade] crossover：当前歌曲切给新歌');
    try {
      onCrossover?.call();
    } catch (e) {
      // ignore: avoid_print
      print('[Crossfade] crossover 回调失败: $e');
    }
  }

  /// 中止进行中的淡化。幂等，没有淡化在进行时是空操作。
  ///
  /// 分两种情形，决定「保留哪一首」：
  /// - 已过交叉点：上层账目已经是新歌，收掉旧歌。
  /// - 未过交叉点：上层账目还在旧歌上，收掉那个已经静音起播的新歌，
  ///   让旧歌继续播下去（看到的和听到的都还是它）。旧歌之后自然播完时
  ///   走原有 completed → next() 流程。
  void abortCrossfade() {
    if (!_crossfading) return;
    _crossfadeToken++;
    final outgoing = _fadingOutPlayer;
    final incoming = _fadingInPlayer;
    final crossed = _crossedOver;
    _setCrossfading(false);
    _fadingOutPlayer = null;
    _fadingInPlayer = null;
    // ignore: avoid_print
    print('[Crossfade] aborted crossed=$crossed');
    final discard = crossed ? outgoing : incoming;
    if (discard != null && discard != _activePlayer) {
      // 记录 in-flight 的 retire 链，prepareCrossfade 复用该播放器前 await 它
      final future = _retireFadedPlayer(discard);
      _retireInFlight = future;
      // 收尾后仅在未被更新的 retire 覆盖时清指针
      // ignore: discarded_futures
      future.whenComplete(() {
        if (identical(_retireInFlight, future)) _retireInFlight = null;
      });
    }
    // ignore: discarded_futures
    _activePlayer.setVolume(_userVolume);
  }

  /// 回收淡出结束的播放器：pause + seek(0)，**绝不 stop()**。
  ///
  /// stop() 会让 ExoPlayer 进入 STATE_IDLE，Media3 的 AudioFocusManager 随即
  /// abandonAudioFocus（见 fork 内 AudioFocusManager.shouldHandleAudioFocus：
  /// 只有 STATE_IDLE 才放弃焦点）。主播放器一旦放弃焦点，
  /// audioFocusChangeStream 就再也收不到系统事件，整套三模式焦点策略失效。
  /// pause 时状态仍是 READY，焦点保留。
  Future<void> _retireFadedPlayer(AudioPlayer p) async {
    try {
      await p.pause();
      await p.seek(Duration.zero);
    } catch (_) {}
    // 恢复音量，供它下次作为淡入方使用
    try {
      await p.setVolume(_userVolume);
    } catch (_) {}
  }


  Future<void> dispose() async {
    abortCrossfade();
    await _media3FocusSub?.cancel();
    for (final sub in _activeSubs) {
      await sub.cancel();
    }
    _activeSubs.clear();
    for (final sub in _sessionIdSubs) {
      await sub.cancel();
    }
    _sessionIdSubs.clear();
    await _sessionIdsCtl.close();
    await _crossfadingCtl.close();
    await _auxPlayer?.dispose();
    await _mainPlayer.dispose();
  }
}

UriAudioSource createAudioSource({
  required String id,
  required String url,
  required String title,
  String? artist,
  String? album,
  Uri? artUri,
}) {
  return AudioSource.uri(
    Uri.parse(url),
    tag: {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'artUri': artUri?.toString(),
    },
  );
}

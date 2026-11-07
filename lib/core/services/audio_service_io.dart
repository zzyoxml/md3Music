import 'dart:async';
import 'music_haptics_service.dart';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_logger.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/kugou_api/kugou_models.dart'
    show loudnessForUrl, warmLoudnessCache;
import 'accompany_mix.dart';
import 'stem_separation_service.dart';
import 'playback_command_dispatcher.dart';
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
      _vnEnabled =
          prefs.getBool('settings_volume_normalization_enabled') ?? false;
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
  }) => AudioPlayer(
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
    // MD3Music fork: 辅播放器与主播放器由同一个 MediaSession host 收敛；原生侧
    // 每个播放器各自生成 audioSessionId（伴唱轨需要时由 Dart 侧显式共享，
    // 见 setSharedAudioSessionId）。
    androidAuxPlayer: aux,
    // 音量均衡：挂一个 LoudnessEnhancer 用于放大安静歌（跨引擎、Dart 侧可靠）。
    audioPipeline: enhancer != null
        ? AudioPipeline(androidAudioEffects: [enhancer])
        : null,
    // Hi-Res 码率可达 ~4600kbps，30s 缓冲区（~17MB）在高码率下极易耗尽，
    // 导致播放到 ~60s 时反复进入 rebuffer 死循环（进度条在 1:00~1:01 弹跳、
    // 无声音）。恢复 maxBuffer 到 60s 并加大 rebuffer 恢复窗口到 5s，
    // 确保高码率流有足够的缓冲余量应对网络波动。
    audioLoadConfiguration: AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 60),
        bufferForPlaybackDuration: Duration(seconds: 2),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
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

  /// 伴唱播放器：开启伴唱模式时才创建（未开启的用户零开销）。
  ///
  /// 与 [_auxPlayer] 是**不同的角色**：辅播放器用于交叉淡化（会接管
  /// 「当前歌曲」），伴唱播放器只作为一路并行出声的背景轨——它不抢系统
  /// 媒体会话（native 侧置静默会话角色），因此通知栏/媒体卡片/锁屏始终
  /// 跟随原曲。
  AudioPlayer? _accompanyPlayer;

  /// 伴唱混音状态（null = 在线伴唱未开启）。
  ///
  /// 伴唱固定为**纯伴奏**：非 null 时主播放器静音、伴奏轨按用户音量出声。
  /// 不再有比例调节（两路同时出声必然错位，见 [AccompanyMix] 的说明）。
  AccompanyMix? _accompanyMix;

  /// 端侧分离是否已开启（**只有一条输出管线**，没有第二路播放器）。
  ///
  /// 与 [_accompanyMix] 互斥：同一时刻只有一种伴奏来源。之所以分开存，是因为
  /// 端侧模式下主播放器**不能被折减音量**（它就是那条唯一的输出），若复用
  /// [_accompanyMix] 的 `originalVolumeScale = 0` 就会把原曲压成静音、
  /// 却又没有人补上伴奏。
  bool _stemActive = false;

  /// 端侧分离是否已开启。
  bool get stemSeparationActive => _stemActive;

  /// 伴唱模式是否已开启（在线伴奏轨 或 端侧分离）。
  bool get accompanyActive => _accompanyMix != null || _stemActive;

  /// 当前伴唱混音比例（在线伴奏未开启时返回 null）。
  AccompanyMix? get accompanyMix => _accompanyMix;

  /// 原曲在伴唱模式下的音量占比。
  ///
  /// - 未开启伴唱：1.0
  /// - 在线伴唱（纯伴奏）：0.0（原曲静音，让位给独立的伴奏轨）
  /// - 端侧分离：1.0 —— 分离发生在同一条输出管线里，混音由处理器完成，
  ///   上层**不能再折减**原曲音量。
  ///
  /// 上层（PlayerProvider 的淡入淡出收尾）直写播放器音量时必须乘上这个值，
  /// 否则暂停淡出收尾会把原曲音量拉回满值，纯伴奏就破了。
  double get originalVolumeScale =>
      _accompanyMix == null ? 1.0 : 0.0;

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
  Future<void> setVolumeNormalization({
    bool? enabled,
    double? referenceLufs,
  }) async {
    if (enabled != null) _vnEnabled = enabled;
    if (referenceLufs != null) _vnReferenceLufs = referenceLufs;
    await _applyNormalizationGainActive();
  }

  /// 音量均衡（响度归一）当前是否开启。
  ///
  /// 供「硬件解码播放」让路判定读取：音量均衡会对样本施加增益，与 audio offload
  /// 的「逐字节直通解码器」互斥，开启时必须让硬解让路。
  bool get volumeNormalizationEnabled => _vnEnabled;

  /// 用 AutoMix 实测响度补上缺失的上游响度。
  ///
  /// **为什么需要**：真机上酷狗 `/song/url` 不返回响度字段，`_vnLufs` 恒为 null，
  /// 「音量均衡」拿不到任何数据 → 相邻曲目的原始响度差原样透出，实测可达 13.7 dB
  /// （用户报的「切歌时音量突然变大」）。AutoMix 分析每首歌时会实测响度，
  /// 在分析完成时（起播后几秒）回调这里补上。
  ///
  /// **是否真的施加补偿由「音量均衡」开关决定**（[_currentNormalizationGainDb] 判
  /// `_vnEnabled`），本方法只负责提供数据，不改变开关语义。
  ///
  /// 上游已提供权威响度时不覆盖；[measuredDbfs] 非法或不合理时静默忽略。
  Future<void> applyMeasuredLoudness(double? measuredDbfs) async {
    if (_vnLufs != null) return;
    final lufs = VolumeNormalizationService.loudnessFromMeasuredDbfs(
      measuredDbfs,
    );
    if (lufs == null) return;
    _vnLufs = lufs;
    // 只测了响度、没测真峰值 → 不做峰值钳制（calcGainDb 的 peakDb 传 null）
    _vnPeakDb = null;
    // ignore: avoid_print
    print(
      '[音量均衡] 采用 AutoMix 实测响度 ${lufs.toStringAsFixed(1)}dBFS '
      '（上游未提供，参考 ${_vnReferenceLufs.toStringAsFixed(1)}）',
    );
    // 淡化中不会落音量（_applyNormalizationGainActive 自带 _crossfading 保护），
    // 因此不会打断正在跑的交叉淡化斜坡。
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

  /// **备用（淡入方）**播放器的衰减倍率。
  ///
  /// 必须与 [_vnAttenLinear] 分开：交叉淡化期间两路是**不同的歌**、响度不同，
  /// `prepareCrossfade` 会为 standby 算出一份新衰减。若共用一个字段，
  /// 正在播放的旧歌会被新歌的衰减值改写音量 —— 这正是「切歌时音量突然变大」
  /// 的一类成因。降级路径：两者都只在「音量均衡」开启且该曲需要衰减时才 ≠ 1.0。
  double _vnAttenLinearStandby = 1.0;

  /// 应用增益：正增益（放大）走 native LoudnessEnhancer，负增益（衰减）折进音量。
  /// 只用一个 enhancer：主/辅播放器共享同一 audio session，一个 LoudnessEnhancer
  /// 作用于该 session 即可覆盖两路音频（避免同 session 创建第二个 enhancer 冲突）。
  Future<void> _applyGain(double gainDb) async {
    final boost = gainDb > 0 ? gainDb : 0.0;
    _vnAttenLinear = gainDb < 0 ? math.pow(10, gainDb / 20).toDouble() : 1.0;
    // 没有正增益时不需要 LoudnessEnhancer。始终启用 0 dB enhancer 会让
    // 小米等 ROM 把它加入音效链；反复切歌时可能与系统/用户均衡器叠加，
    // 表现为音量突然变大。负增益已经折进播放器音量，同样保持 enhancer 关闭。
    try {
      await _mainEnhancer.setTargetGain(boost);
      await _mainEnhancer.setEnabled(_vnEnabled && boost > 0);
    } catch (e) {
      // ignore: avoid_print
      print('[音量均衡] enhancer apply failed: $e');
    }
  }

  Future<void> _applyNormalizationGainActive() async {
    await _applyGain(_currentNormalizationGainDb());
    // 伴唱开启时由 _applyVolumes 统一下发两路（音量要按比例折减）。
    if (_accompanyMix != null) {
      await _applyVolumes();
      return;
    }
    // 非淡化中才落音量衰减，避免打断跨 fade 的斜坡
    if (!_crossfading) {
      await _activePlayer.setVolume(_userVolume * _vnAttenLinear);
    }
  }

  Future<void> _applyNormalizationGainTo(AudioPlayer p) async {
    await _applyGain(_currentNormalizationGainDb());
  }

  AudioPlayer get player => _activePlayer;

  /// 已分配的播放引擎数量，用于低频诊断快照。
  int get diagnosticPlayerCount => _auxPlayer == null ? 1 : 2;
  String get diagnosticActiveEngine =>
      _activePlayer == _mainPlayer ? 'main' : 'aux';

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
      // 主播放器位置前进时也校正伴唱轨：伴唱轨自身在 loading / paused 时
      // positionStream 不发事件，只靠伴唱侧回调会漏掉「原曲走了、伴奏没走」
      // 这一类静默错位。
      p.positionStream.listen(
        (_) => _resyncAccompany(),
        onError: ignoreError,
      ),
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
    _sessionIdSubs.add(
      p.androidAudioSessionIdStream.listen((_) {
        if (!_sessionIdsCtl.isClosed)
          _sessionIdsCtl.add(androidAudioSessionIds);
      }, onError: (Object _) {}),
    );
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

  /// 短暂失去音频焦点时的处理策略（默认：保持播放）。
  AudioFocusInterruptionMode _interruptionMode =
      AudioFocusInterruptionMode.keepPlaying;
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
    final keepPlayingActive =
        !_ignoreAudioFocus &&
        _interruptionMode == AudioFocusInterruptionMode.keepPlaying;
    // ignore: discarded_futures
    _mainPlayer.setForceKeepPlaying(keepPlayingActive);
    // ignore: discarded_futures
    _mainPlayer.setForceWillPauseWhenDucked(
      _ignoreAudioFocus ||
          _interruptionMode != AudioFocusInterruptionMode.duckAndRestore,
    );
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
    _media3FocusSub = _mainPlayer.audioFocusChangeStream.listen(
      _handleMedia3FocusChange,
    );
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
    // 取证：logcat 显示 MIUI 侧频繁处理焦点丢失
    // （plgin_MiuiAudioPlaybackManager: currentTime - mLossAudioFocusTime）。
    // 若焦点事件落在交叉淡化期间，pauseAndResume 模式会走 abortCrossfade() + pause()，
    // 而 abort 会把**已 promote 成活动播放器**的 incoming 音量从斜坡中的低值
    // 一次性拉到 _userVolume —— 听感正是「切歌时音量突然变大」。
    // 这条日志是坐实/排除该路径的唯一判据（abort 自身只打 crossed=…，看不出触发原因）。
    if (_crossfading) {
      // ignore: avoid_print
      print('[VolAudit] 淡化中收到焦点变化 focusChange=$focusChange '
          'mode=${_interruptionMode.name} playing=${_activePlayer.playing}');
    }
    if (_interruptionMode == AudioFocusInterruptionMode.keepPlaying) {
      // keepPlaying：短暂中断（导航等 transient/duck）native 已 skip（保持播放
      // 有声、进度一致）。独占型 LOSS（B 站视频 / 来电等）主动暂停让路——
      // native 对 LOSS 正常走 Media3 DO_NOT_PLAY；此处同步 Dart 状态并留痕，
      // 确认独占中断事件是否可达（小米可能直接 interrupt AudioTrack 不派发事件）。
      if (focusChange == -1) {
        // ignore: avoid_print
        print(
          '[AudioFocus] keepPlaying LOSS, playing=${_activePlayer.playing}',
        );
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
    await _playAccompany();
  }

  /// 派发播放命令后立即返回；底层Future会持续到暂停/曲目结束，不能阻塞切歌流程。
  /// 异步错误仍由本方法接收，并交给当前调用方按播放请求归属处理。
  Future<void> playCommand({
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    _pausedByInterruption = false;
    final player = _activePlayer;
    await dispatchPlaybackCommand(
      player.play(),
      onError: (error, stackTrace) {
        DiagnosticLogger.instance.e(
          '[Playback] play command future failed: ${error.runtimeType}',
        );
        try {
          onError?.call(error, stackTrace);
        } catch (callbackError) {
          DiagnosticLogger.instance.e(
            '[Playback] play error handler failed: ${callbackError.runtimeType}',
          );
        }
      },
    );
    // 伴唱轨同步恢复：原曲起播后伴奏也必须跟上，否则两路时轴分叉。
    await _playAccompany();
  }

  /// 伴唱轨跟随原曲起播（伴唱未开启时是空操作）。
  Future<void> _playAccompany() async {
    final player = _accompanyPlayer;
    if (player == null || _accompanyMix == null) return;
    // 起播前再对齐一次 session id：输出通路重建后活动播放器可能换了 session。
    await _shareActiveAudioSession(player);
    try {
      if (!player.playing) {
        // ignore: discarded_futures
        player.play();
      }
    } catch (_) {}
  }

  Future<void> pause() async {
    // 用户主动暂停：清除中断暂停标记（中断引起的暂停不在 GAIN 时自动恢复）
    _pausedByInterruption = false;
    // 淡化进行中被暂停：先收掉正在淡出的那一路，否则它会继续响。
    // keepVolume：紧接着就 pause，恢复音量只会让淡入中的一路先"升上去"再停
    // （用户实测报的「点暂停时音量突然变大」）。
    abortCrossfade(keepVolume: true);
    await _activePlayer.pause();
    // 伴唱轨同步暂停：否则伴奏继续响，表现为「暂停后还有伴奏声」。
    final accompany = _accompanyPlayer;
    if (accompany != null && _accompanyMix != null) {
      try {
        await accompany.pause();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    abortCrossfade(keepVolume: true);
    await _mainPlayer.stop();
    final aux = _auxPlayer;
    if (aux != null) await aux.stop();
    // 停止播放即结束伴唱会话（伴唱状态由上层另行清理）。
    final accompany = _accompanyPlayer;
    if (accompany != null) {
      _accompanyMix = null;
      try {
        await accompany.stop();
      } catch (_) {}
    }
    // 端侧分离也要一起关掉，否则下次起播会带着旧的流式状态
    if (_stemActive) {
      _stemActive = false;
      await StemSeparationService.instance.setEnabled(false);
    }
  }

  Future<void> seek(Duration position) async {
    abortCrossfade();
    await _activePlayer.seek(position);
    // 伴唱轨同步定位：两路必须指向同一时刻，否则歌词与伴奏错位。
    await _seekAccompany(position);
    // 端侧分离：seek 后必须让模型丢弃旧音频的流式状态。
    //
    // 主路径已经在原生侧做了（`DefaultAudioSink.flush()` 补调
    // `audioProcessingPipeline.flush()` → `StemSeparateProcessor.onFlush()`
    // → `session.flush()` 置重置标志）。这里再显式调一次是**兜底**：
    // 个别 ROM / 低版本上 `onPositionReset` 未必走同一条路径，而残留旧状态
    // 的后果是「拖动进度后分离失效 + 串音」，很难让用户自行恢复。
    // 该调用幂等且极廉价（原生只置一个 volatile 标志），重复调用无副作用。
    if (_stemActive) {
      await StemSeparationService.instance.reset();
    }
  }

  // ==== 伴唱（伴奏轨）====

  /// 伴唱播放器（懒创建）。
  ///
  /// 用 `_createPlayer(aux: true)` 的同款配置：`androidApplyAudioAttributes: false`
  /// → 不请求音频焦点（否则同 app 的第二次焦点请求会让主播放器收到
  /// AUDIOFOCUS_LOSS，把正在播的原曲掐掉）。
  ///
  /// 额外在 native 侧置「静默会话」角色（[AudioPlayer.setSilentSession]）：
  /// 伴唱只出声、不进系统媒体会话，通知栏/媒体卡片/锁屏始终跟随原曲。
  /// 同时通过 setSharedAudioSessionId 共享活动播放器的 audioSessionId：没有自己的
  /// MediaSession 时，小米/HyperOS 会在原曲出声时把伴奏轨自动 duck 到无声；挂到
  /// 主播放器已关联 MediaSession 的 session 上（hasUid=true）即可避免。
  AudioPlayer _accompanyInstance() {
    final existing = _accompanyPlayer;
    if (existing != null) return existing;
    final player = _createPlayer(aux: true);
    _accompanyPlayer = player;
    _watchSessionIds(player);
    // 静默会话标志必须在第一次 play() 之前下发，否则 native 的 play() 已经
    // 把本实例设为系统活跃会话（通知栏会跳到伴奏）。
    // ignore: discarded_futures
    player.setSilentSession(true);
    // 伴唱轨位置漂移校正：两路各自解码会缓慢错开，超阈值即重新对齐。
    _accompanyDriftSub = player.positionStream.listen(
      _onAccompanyPosition,
      onError: (Object _) {},
    );
    // 伴唱轨 ready 后补发被 loading 吞掉的 seek（just_audio 在 loading 态
    // 静默丢弃 seek），并立即做一次对齐校正。
    _accompanyStateSub = player.playerStateStream.listen(
      _onAccompanyState,
      onError: (Object _) {},
    );
    return player;
  }

  StreamSubscription<Duration>? _accompanyDriftSub;

  StreamSubscription<PlayerState>? _accompanyStateSub;

  /// 让伴唱轨共享当前活动播放器的 audioSessionId。
  ///
  /// 伴唱轨是「静默会话」（不建 MediaSession）；小米/HyperOS 会在原曲出声时把
  /// 这条没有 MediaSession 关联的 AudioTrack 直接 duck 到无声 —— 表现正是
  /// 「原曲暂停时伴奏正常、原曲一播放就听不见伴奏」。挂到活动播放器已与
  /// MediaSession 关联的 session 上（hasUid=true）即可避免；同时均衡器/音量
  /// 均衡对两路继续共用同一条 effect 链。
  ///
  /// 必须在 AudioTrack 创建前（setUrl / play 之前）下发。
  Future<void> _shareActiveAudioSession(AudioPlayer player) async {
    final id = _activePlayer.androidAudioSessionId;
    if (id == null || id == 0) return;
    try {
      await player.setSharedAudioSessionId(id);
    } catch (_) {}
  }

  /// 伴唱轨装载期间被丢弃的 seek 目标（loading 态 seek 不生效）。
  ///
  /// ready 后补发，避免「拖动进度条后伴奏停在旧位置」。
  Duration? _pendingAccompanySeek;

  /// 伴唱轨装载后是否还需要一次「就绪对齐」。
  ///
  /// 只在首次 ready 时消费一次；**不能**每次 ready 都强制 seek —— seek 会让
  /// 播放器回到 buffering（isPlaying=false → 重新 startRenderers），ready 后又
  /// 强制 seek，形成 seek→buffering→ready→seek 风暴（实测 14s 内 7000+ 次
  /// isPlaying 抖动、AudioSink 反复 pause/play，伴奏听起来就是没声）。
  bool _accompanyNeedsInitialAlign = false;

  /// 最近一次下发伴唱 seek 的时间，用于抑制 seek 风暴。
  DateTime? _accompanyLastSeekAt;

  /// 诊断日志节流（排查「伴奏总比原曲慢」）。
  DateTime? _lastAccompanySyncLogAt;

  /// 伴唱轨播放倍速基准（用户倍速，不含同步校正）。
  double _accompanyBaseSpeed = 1.0;

  /// 已下发给伴唱轨的倍速（用于去重，避免每个位置事件都发通道）。
  double _accompanyAppliedSpeed = 1.0;

  /// 由主播放器位置推算伴唱目标位置（夹在 0..伴奏时长 内）。
  ///
  /// 注意这里必须夹到**伴奏轨**的时长，不是主曲时长：伴奏常常比原曲短
  /// （纯伴奏少掉片头/片尾），用主曲时长上界会让 seek 目标定到伴奏末尾之外
  /// ——seek 被平台丢弃或跳到结尾，表现就是「怎么调都不准」。
  ///
  /// 不再叠加任何「同步偏移」：两路各自 AudioTrack 的排队深度不同，这层物理
  /// 延迟差无法用媒体位置修正；偏移与自动对齐体系已整体移除，只保留媒体位置
  /// 对齐 + 倍速追赶的漂移校正。
  Duration _accompanyTarget(Duration mainPos) {
    var target = mainPos;
    if (target < Duration.zero) target = Duration.zero;
    final dur = _accompanyPlayer?.duration;
    if (dur != null && target > dur) target = dur;
    return target;
  }

  /// 触发一次「跳转对齐」的最小偏差。
  ///
  /// 不能按 50ms 持续追：每次 seek 本身要停顿 300~400ms，追 50ms 会变成
  /// 「跳→落后→再跳」的无限切进度。阈值必须明显高于 seek 停顿，这里取
  /// 800ms：阈值以下的残差交给倍速追赶（无停顿），更大的偏差（拖进度条、
  /// 长时间卡顿/暂停恢复）才值得付一次 seek 的代价。
  static const int _kAccompanyJumpThresholdMs = 800;

  /// 向前跳转的提前量（伴奏落后时）。
  ///
  /// seek 会让伴唱轨停顿约 350~400ms（MediaCodec flush + 重新预滚）；真机日志
  /// 实测「跳转前 drift=1504、跳转后 drift=90」，说明停顿约 390ms。取 400ms，
  /// 跳完的残差接近 0，剩下的交给倍速追赶抹平。
  static const int _kAccompanyJumpLeadMs = 400;

  /// 两次跳转的最小间隔，避免 seek 后位置尚未刷新时连续再跳。
  static const Duration _kAccompanySeekCooldown = Duration(seconds: 2);

  /// 倍速追赶的死区（毫秒）：残差小于该值视为已对齐，立刻恢复原速。
  ///
  /// 取 10ms：真机日志里位置取样非常稳定（残差长期恒定在同一个整数），说明
  /// 读数噪声远小于此；旧值 40ms 会把残差钉在 39ms 不再收敛，正是「总是差
  /// 一点、伴奏偏后」的来源。
  static const int _kAccompanySpeedDeadbandMs = 10;

  /// 倍速追赶的期望追平时间（毫秒）：按「残差 / 该时间」换算追赶比例。
  ///
  /// 越小的值追得越猛。600ms 让 100ms 的残差直接顶到 [_kAccompanyCatchUpMaxRatio]，
  /// 几十毫秒的残差则只轻微加速，从而在 1~2 秒内收敛且不产生可闻的持续变速。
  static const int _kAccompanyCatchUpWindowMs = 600;

  /// 倍速追赶的最大比例（相对用户倍速）。
  ///
  /// just_audio 在 Android 侧用 Sonic 做时间拉伸（音高不变），但仍取 12% 上限：
  /// 过大的比率会让伴奏音色发闷；12% 已能把 800ms 内的残差在数秒内抹平。
  static const double _kAccompanyCatchUpMaxRatio = 0.12;

  /// 倍速追赶的最小比例：越过死区后至少加速/减速这么多，避免边缘抖动。
  static const double _kAccompanyCatchUpMinRatio = 0.01;

  /// 诊断：每秒最多打印一次两路位置/漂移/倍速（定位固定滞后还是逐渐变慢）。
  void _logAccompanySync(AudioPlayer main, AudioPlayer player, Duration accompanyPos) {
    final now = DateTime.now();
    final last = _lastAccompanySyncLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) return;
    _lastAccompanySyncLogAt = now;
    final drift = main.position.inMilliseconds - accompanyPos.inMilliseconds;
    // ignore: avoid_print
    print('[AccompanySync] main=${main.position.inMilliseconds} '
        'acc=${accompanyPos.inMilliseconds} drift=$drift '
        'speed(main=${main.speed},acc=${player.speed}) '
        'ready=${player.processingState} pwr=${player.playing}');
  }

  /// 每 5 秒最多打印一次各路 AudioTrack 排队深度（诊断）。
  DateTime? _lastOutputLatencyLogAt;

  Future<void> _logAccompanyOutputLatency() async {
    final now = DateTime.now();
    final last = _lastOutputLatencyLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) return;
    _lastOutputLatencyLogAt = now;
    try {
      final snapshot =
          await MusicHapticsService.instance.queryOutputLatencyTracks();
      final raw = await MusicHapticsService.instance.queryOutputLatencyRaw();
      // ignore: avoid_print
      print('[AccompanyLatency] tracks=${snapshot ?? "unavailable"}');
      // ignore: avoid_print
      print('[AccompanyLatencyRaw] ${raw ?? "unavailable"}');
    } catch (_) {
      // 诊断失败不影响播放
    }
  }

  /// 下发伴唱倍速（去重）。
  void _applyAccompanySpeed(AudioPlayer player, double speed) {
    final target = speed.clamp(0.25, 4.0);
    if ((target - _accompanyAppliedSpeed).abs() < 1e-3) return;
    _accompanyAppliedSpeed = target;
    // ignore: discarded_futures
    player.setSpeed(target).catchError((Object _) {});
  }

  /// 用倍速把残差追平（无 seek 停顿）。
  ///
  /// [driftMs] 为「目标位置 − 伴奏当前位置」：正值 = 伴奏落后 → 加速追赶；
  /// 负值 = 伴奏超前 → 减速等待。比例按残差线性换算并夹在
  /// [minRatio] ~ [_kAccompanyCatchUpMaxRatio] 之间，落入
  /// [_kAccompanySpeedDeadbandMs] 死区即恢复原速。
  ///
  /// 相比 seek：不打断解码、不产生 300~400ms 的停顿，因此可以反复微调；
  /// 相比固定小比例（旧版 ±6%）：残差越大追得越快，收敛时间更短。
  void _applyAccompanyCatchUp(AudioPlayer player, int driftMs) {
    final abs = driftMs.abs();
    if (abs <= _kAccompanySpeedDeadbandMs) {
      _applyAccompanySpeed(player, _accompanyBaseSpeed);
      return;
    }
    // 量化到 1% 步进：位置流每 ~100ms 来一次，不量化会让每个事件都重新下发
    // setSpeed，反复重建 Sonic 处理器反而制造抖动。
    final rawRatio = (abs / _kAccompanyCatchUpWindowMs)
        .clamp(_kAccompanyCatchUpMinRatio, _kAccompanyCatchUpMaxRatio);
    final ratio = (rawRatio * 100).round() / 100.0;
    final target = driftMs > 0
        ? _accompanyBaseSpeed * (1 + ratio)
        : _accompanyBaseSpeed * (1 - ratio);
    _applyAccompanySpeed(player, target);
  }

  /// 计算跳转目标：伴奏落后（drift > 0）时向前多推 [_kAccompanyJumpLeadMs]，
  /// 补偿 seek 后的停顿；向后跳不额外推。
  ///
  /// 上界同样必须用**伴奏轨**时长（理由见 [_accompanyTarget]）：这里已经叠加了
  /// 400ms 提前量，再用主曲时长裁剪更容易把目标顶到伴奏范围之外。
  Duration _accompanyJumpTarget(Duration target, int driftMs) {
    var t = driftMs > 0
        ? target + const Duration(milliseconds: _kAccompanyJumpLeadMs)
        : target;
    if (t < Duration.zero) t = Duration.zero;
    final dur = _accompanyPlayer?.duration;
    if (dur != null && t > dur) t = dur;
    return t;
  }

  /// 偏差超过阈值时安排一次跳转（带冷却）。返回 true 表示已发起 seek。
  bool _jumpAccompanyIfNeeded(AudioPlayer player, int driftMs) {
    if (driftMs.abs() <= _kAccompanyJumpThresholdMs) return false;
    final now = DateTime.now();
    final last = _accompanyLastSeekAt;
    if (last != null && now.difference(last) < _kAccompanySeekCooldown) {
      return false;
    }
    _accompanyLastSeekAt = now;
    _applyAccompanySpeed(player, _accompanyBaseSpeed);
    return true;
  }

  /// 伴唱轨 ready：补发挂起的 seek；装载后的首次 ready 再做一次对齐。
  void _onAccompanyState(PlayerState state) {
    if (state.processingState != ProcessingState.ready) return;
    final pending = _pendingAccompanySeek;
    if (pending != null) {
      _pendingAccompanySeek = null;
      final player = _accompanyPlayer;
      if (player != null) {
        // ignore: discarded_futures
        player.seek(pending).catchError((Object _) {});
      }
    }
    // 装载后的首次对齐：偏差大时用一次 seek（装载期主曲已经走了近 1s），
    // 否则直接交给倍速校正。
    if (_accompanyNeedsInitialAlign) {
      _accompanyNeedsInitialAlign = false;
      _alignAccompanyAfterLoad();
    }
  }

  /// 装载完成后的首次对齐（只执行一次）。
  void _alignAccompanyAfterLoad() {
    final player = _accompanyPlayer;
    final main = _activePlayer;
    if (player == null) return;
    if (!accompanyCanResync(
      ready: player.processingState == ProcessingState.ready,
    )) {
      return;
    }
    if (!main.playing) return;
    final mainPos = main.position;
    final accPos = player.position;
    _logAccompanySync(main, player, accPos);
    final target = _accompanyTarget(mainPos);
    final driftMs = (target - accPos).inMilliseconds;
    if (_jumpAccompanyIfNeeded(player, driftMs)) {
      final jump = _accompanyJumpTarget(target, driftMs);
      // ignore: avoid_print
      print('[AccompanySync] initial jump → target=${jump.inMilliseconds} '
          'acc=${accPos.inMilliseconds} drift=$driftMs');
      // ignore: discarded_futures
      player.seek(jump).catchError((Object _) {});
      return;
    }
    // 未超跳转阈值：交给倍速追赶，不再做固定 ±6% 变速。
    _applyAccompanyCatchUp(player, driftMs);
  }

  /// 伴唱轨位置漂移校正。
  ///
  /// 两路各自解码、各自推进，位置会缓慢错开（起播点不同、缓冲时机不同）。
  /// 普通漂移用倍速微调追赶（无停顿）；只有偏差极大（拖进度条/长时间卡顿）
  /// 才做一次 seek。主播放器是基准，绝不动它。
  void _onAccompanyPosition(Duration _) {
    // 不要用事件里携带的位置：positionStream 有 ~100ms 的投递间隔，拿旧位置
    // 跟主播放器当前位置比会平白多算出 ~100ms 且永远达不到「不算漂移」的稳态。
    // 直接读两路的 player.position（同一时刻取样）才是真实偏差。
    _resyncAccompany();
  }

  /// 实际执行漂移校正。
  ///
  /// 伴唱轨未 ready 时**跳过**：just_audio 的 seek 在 loading 态被静默丢弃，
  /// 由 [_onAccompanyState] 在 ready 后补做。
  void _resyncAccompany() {
    final mix = _accompanyMix;
    if (mix == null) return;
    final player = _accompanyPlayer;
    if (player == null) return;
    if (!accompanyCanResync(
      ready: player.processingState == ProcessingState.ready,
    )) {
      return;
    }
    final main = _activePlayer;
    if (!main.playing) return;
    // 两路都在同一时刻取样，避免用事件里的旧位置制造假漂移。
    final mainPos = main.position;
    final accompanyPos = player.position;
    _logAccompanySync(main, player, accompanyPos);
    final target = _accompanyTarget(mainPos);
    final driftMs = (target - accompanyPos).inMilliseconds;
    if (_jumpAccompanyIfNeeded(player, driftMs)) {
      final jump = _accompanyJumpTarget(target, driftMs);
      // ignore: avoid_print
      print('[AccompanySync] jump → target=${jump.inMilliseconds} '
          'acc=${accompanyPos.inMilliseconds} drift=$driftMs');
      // ignore: discarded_futures
      player.seek(jump).catchError((Object _) {});
      return;
    }
    // 阈值内：用倍速追赶剩余残差（无 seek 停顿），追平后自动恢复原速。
    _applyAccompanyCatchUp(player, driftMs);
  }

  /// 开启伴唱：装载伴奏 URL 并从 [position] 起播，与原曲并行出声。
  ///
  /// [mix] 为伴奏占比（0 = 纯原曲，1 = 纯伴奏）。
  /// 返回 false 表示装载失败（调用方据此 toast 并保持原状）。
  Future<bool> startAccompany(
    String url, {
    required AccompanyMix mix,
    required Duration position,
    double speed = 1.0,
  }) async {
    try {
      final player = _accompanyInstance();
      // 复用伴唱轨时也要重新对齐活动播放器的 session id（输出通路重建后会变）。
      await _shareActiveAudioSession(player);
      // 伴唱轨不参与响度归一（另一首歌，响度不同），但倍速要跟原曲一致，
      // 否则两路的时间轴会逐渐分叉。这里同时记下同步校正用的基准倍速。
      final baseSpeed = speed.clamp(0.25, 4.0);
      await player.setSpeed(baseSpeed);
      _accompanyBaseSpeed = baseSpeed;
      _accompanyAppliedSpeed = baseSpeed;
      // 复用伴唱轨时先清掉上一首的挂起 seek（否则会 seek 到旧位置）。
      _pendingAccompanySeek = null;
      // 装载后只做一次阈值对齐；seek 冷却清零（新会话允许一次校正）。
      _accompanyNeedsInitialAlign = true;
      _accompanyLastSeekAt = null;
      _lastAccompanySyncLogAt = null;
      var initialPos = position;
      if (initialPos < Duration.zero) initialPos = Duration.zero;
      final loadStart = DateTime.now();
      await player.setUrl(
        url,
        headers: const {},
        // 定位交给平台层 prepare 阶段一次性生效，避免 seek 竞态（同 setUrl）。
        initialPosition: initialPos,
      );
      // ignore: avoid_print
      print('[AccompanySync] load=${DateTime.now().difference(loadStart).inMilliseconds}ms '
          'target=${initialPos.inMilliseconds} '
          'mainNow=${_activePlayer.position.inMilliseconds}');
      _accompanyMix = mix;
      await _applyVolumes();
      // 只有原曲正在播放时才让伴奏轨起播：暂停态下点击开启伴唱，伴奏必须
      // 保持静音就位，等用户恢复播放时由 `play()` / `_playAccompany()` 一起启动。
      if (_activePlayer.playing) {
        // 不 await play()：它的 Future 直到播放结束/暂停才完成。
        // ignore: discarded_futures
        player.play();
      }
      // 不要在这里再强制 seek：seek 会把刚起播的伴奏打回 buffering，
      // 若与「ready 后强制对齐」叠加会形成反复 seek 的风暴（伴奏始终没声）。
      // 首次 ready 由 _onAccompanyState 按漂移阈值做一次对齐即可。
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[Accompany] 装载失败: $e');
      await stopAccompany();
      return false;
    }
  }

  /// 开启端侧分离（只有一条输出管线，不需要第二路播放器）。
  ///
  /// 与 [startAccompany] 互斥：先确保在线伴奏轨已停掉，避免两条伴奏来源叠加。
  ///
  /// 返回 false 表示原生侧没接受（模型缺失 / 未就绪 / 算力不足），调用方据此
  /// toast 并保持原状。
  Future<bool> startStemSeparation({required double mix}) async {
    // 同一条输出不允许两种伴奏来源并存
    if (_accompanyMix != null) await stopAccompany();
    await StemSeparationService.instance.setMix(mix);
    final ok = await StemSeparationService.instance.setEnabled(true);
    if (!ok) return false;
    _stemActive = true;
    _ensureStemStatsPoller();
    await _applyVolumes();
    return true;
  }

  /// 分离期间每 2s 拉一次原生统计。
  ///
  /// 存在的意义：卡音是**间歇性**的，事后问「刚才卡了没」无法定位；而
  /// `skippedFrames` / `droppedBlocks` 的增长是欠载的硬指标。只有把这两个
  /// 量在播放中持续记录下来，真机上出了问题才有据可查（这正是上一轮
  /// 「一卡一卡」排查时最缺的东西）。
  void _ensureStemStatsPoller() {
    _stemStatsTimer?.cancel();
    _stemStatsTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!_stemActive) {
        t.cancel();
        _stemStatsTimer = null;
        return;
      }
      await StemSeparationService.instance.refreshStats();
    });
  }

  Timer? _stemStatsTimer;

  /// 关闭端侧分离。
  Future<void> stopStemSeparation() async {
    _stemStatsTimer?.cancel();
    _stemStatsTimer = null;
    if (!_stemActive) {
      // 幂等：即便状态没置上也要把原生侧关掉（防止异常退出后残留）
      await StemSeparationService.instance.setEnabled(false);
      return;
    }
    _stemActive = false;
    await StemSeparationService.instance.setEnabled(false);
    await _applyVolumes();
  }

  /// 端侧分离的伴奏占比（0 = 纯原曲，1 = 纯伴奏）。
  Future<void> setStemMix(double mix) async {
    if (!_stemActive) return;
    await StemSeparationService.instance.setMix(mix);
  }

  /// 关闭伴唱：停掉伴奏轨，原曲音量恢复满值。
  Future<void> stopAccompany() async {
    _accompanyMix = null;
    _pendingAccompanySeek = null;
    _accompanyNeedsInitialAlign = false;
    _accompanyLastSeekAt = null;
    _lastAccompanySyncLogAt = null;
    final player = _accompanyPlayer;
    if (player != null) {
      try {
        await player.pause();
      } catch (_) {}
    }
    await _applyVolumes();
  }

  /// 伴唱轨与主播放器同步 seek。
  ///
  /// 伴唱轨未 ready（loading / idle）时**挂起**目标位置而不是直接 seek：
  /// `just_audio.seek()` 在 loading 态被静默丢弃（fork `just_audio.dart`
  /// 的 `case ProcessingState.loading: return;`），发过去也是白发。挂起后由
  /// [_onAccompanyState] 在 ready 时补发。
  Future<void> _seekAccompany(Duration position) async {
    final player = _accompanyPlayer;
    if (player == null || _accompanyMix == null) return;
    final target = _accompanyTarget(position);
    if (!accompanyCanResync(
      ready: player.processingState == ProcessingState.ready,
    )) {
      _pendingAccompanySeek = target;
      return;
    }
    _pendingAccompanySeek = null;
    // 用户主动 seek 已经完成两路对齐，取消装载后的首次对齐，并记一次冷却，
    // 避免位置上报尚未刷新时又被判定为漂移、立刻再 seek 一次。
    _accompanyNeedsInitialAlign = false;
    _accompanyLastSeekAt = DateTime.now();
    try {
      await player.seek(target);
    } catch (_) {}
  }

  /// 按当前音量下发两路的音量（在线伴唱固定纯伴奏：原曲静音、伴奏满音量）。
  ///
  /// 端侧分离走单条输出，原曲音量保持正常（混音在处理器里做，这里不折减）。
  /// 未开启任何伴唱时退化为改动前的单路行为（`_userVolume × 响度衰减`）。
  Future<void> _applyVolumes() async {
    final mix = _accompanyMix;
    final originalTarget = mix == null
        ? _userVolume * _vnAttenLinear
        : mix.volumes(
            userVolume: _userVolume,
            attenuation: _vnAttenLinear,
          ).original;
    final accompanyTarget = mix == null
        ? 0.0
        : mix.volumes(
            userVolume: _userVolume,
            attenuation: 1.0,
          ).accompany;
    try {
      if (!_crossfading) {
        await _activePlayer.setVolume(originalTarget);
      }
    } catch (_) {}
    final player = _accompanyPlayer;
    if (player != null && mix != null) {
      try {
        await player.setVolume(accompanyTarget);
      } catch (_) {}
    }
  }

  /// 伴唱模式下活动播放器的目标音量（供上层淡入淡出收尾使用）。
  double get _activePlayerVolumeTarget =>
      _accompanyMix == null
      ? _userVolume * _vnAttenLinear
      : (_accompanyMix!
            .volumes(
              userVolume: _userVolume,
              attenuation: _vnAttenLinear,
            )
            .original);

  /// 加载单源 URL。
  ///
  /// [initialPosition] 与 [setPlaylist] 同口径：交给平台层在 prepare 阶段
  /// 一次性定位，**不存在 seek 竞态**。传 null/zero 表示从头播。
  /// **不要**改成「加载后轮询等 ready 再 seek()」：`just_audio.seek()` 在
  /// `ProcessingState.loading` 时静默丢弃，超时分支落在这个状态就会从头播。
  Future<void> setUrl(
    String url, {
    double? loudnessLufs,
    double? loudnessPeakDb,
    Duration? initialPosition,
    dynamic tag,
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
    await _activePlayer.setUrl(
      url,
      headers: const {},
      initialPosition: initialPosition ?? Duration.zero,
      tag: tag,
    );
    await _applyNormalizationGainActive();
  }

  /// 设置用户音量（0..1）。淡化斜坡以它为上限。
  Future<void> setVolume(double volume) async {
    _userVolume = volume.clamp(0.0, 1.0);
    // 淡化中不要打断斜坡：新音量在斜坡结束时自然生效
    // 叠加音量均衡的衰减倍率（响歌压低）
    if (_crossfading) {
      // 取证：用户报「切歌时音量突然变大」，需要能区分「外部改音量被忽略」
      // 与「外部绕开这里直接写播放器」。这条日志是前者的判据。
      // ignore: avoid_print
      print('[VolAudit] setVolume(${_userVolume.toStringAsFixed(3)}) 淡化中被忽略');
      return;
    }
    // 伴唱开启时原曲音量要按比例折减（_applyVolumes 统一下发两路）。
    if (_accompanyMix != null) {
      await _applyVolumes();
      return;
    }
    await _activePlayer.setVolume(_userVolume * _vnAttenLinear);
  }

  /// [initialPosition] 在平台层 prepare 时一次性定位，**不存在 seek 竞态**。
  ///
  /// 必须用它而不是「加载完再 `seek()`」：`just_audio.seek()` 在
  /// `ProcessingState.loading` 时**直接 return 静默丢弃**（见 just_audio.dart
  /// `seek()` 的 switch），因此依赖「等 ready 再 seek」的写法仍会偶发失效
  /// （Media3 在未播放时不保证自行进入 ready）。见铁律 18。
  Future<void> setPlaylist(
    List<UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
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
      initialPosition: initialPosition ?? Duration.zero,
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
    // 伴唱轨同步倍速：两路时间轴必须同速，否则越播越错位。
    final accompany = _accompanyPlayer;
    if (accompany != null && _accompanyMix != null) {
      final base = speed.clamp(0.25, 4.0);
      // 用户改倍速时重置同步校正基准（避免把 ±6% 的追赶倍速当成新基准）。
      _accompanyBaseSpeed = base;
      _accompanyAppliedSpeed = base;
      try {
        await accompany.setSpeed(base);
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
  int _crossfadePrepareGeneration = 0;
  Future<void> _crossfadePrepareTail = Future<void>.value();

  /// 备用播放器当前的 automix 变速倍率（1.0 = 未变速）。
  ///
  /// 淡化结束后**不复位**：对拍成功后下一首整首都保持这个速率，
  /// 中途复位会造成明显的速度跳变。由上层在手动切歌时调 [resetAutomixRate]。
  double _preparedAutomixRate = 1.0;

  double get preparedAutomixRate => _preparedAutomixRate;

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
    double automixRate = 1.0,
  }) async {
    _preparedAutomixRate = automixRate;
    final generation = ++_crossfadePrepareGeneration;
    final previous = _crossfadePrepareTail;
    final turn = Completer<void>();
    _crossfadePrepareTail = turn.future;
    await previous;
    try {
      if (generation != _crossfadePrepareGeneration || _crossfading) {
        return false;
      }
      final standby = _standbyPlayer();
      // 淡入段响度即正确：预加载时设置新歌的归一增益（旧歌保持各自增益直至淡出）。
      // 先记下旧歌（活动播放器）的衰减 —— 下面的 _applyNormalizationGainTo
      // 会把 _vnAttenLinear 覆盖成新歌的值。
      final outgoingAtten = _vnAttenLinear;
      _vnLufs = loudnessLufs;
      _vnPeakDb = loudnessPeakDb;
      await _applyNormalizationGainTo(standby);
      if (generation != _crossfadePrepareGeneration) return false;
      // 两路分开存：standby 那份给淡入方，还原后的那份留给正在播的旧歌。
      _vnAttenLinearStandby = _vnAttenLinear;
      _vnAttenLinear = outgoingAtten;
      // 上一次 abort 留下的 retire 链（pause→seek0→恢复音量）若还在飞，
      // 必须先等它收尾再把这个播放器重新拉去当淡入方——否则 retire 末尾的
      // setVolume(_userVolume) 会落在下面的 setVolume(0) 之后，新歌以全音量
      // 起播再被斜坡压回，听感像淡化反向。
      final retire = _retireInFlight;
      if (retire != null) {
        _retireInFlight = null;
        await retire;
        if (generation != _crossfadePrepareGeneration) return false;
      }
      final isAux = standby != _mainPlayer;
      // ignore: avoid_print
      print('[Crossfade] 预加载到${isAux ? '辅' : '主'}播放器 …');
      await standby.setVolume(0);
      if (generation != _crossfadePrepareGeneration) {
        await _releaseStaleCrossfadePreparation(standby);
        return false;
      }
      await standby.setLoopMode(LoopMode.off);
      // automix 变速叠加在用户倍速之上；两端都钳在 just_audio 支持的区间内
      await standby.setSpeed((speed * automixRate).clamp(0.25, 4.0));
      if (generation != _crossfadePrepareGeneration) {
        await _releaseStaleCrossfadePreparation(standby);
        return false;
      }
      // setUrl 在加载完成后才返回，返回即可立即起播
      // 用带 artUri 的 AudioSource 加载：MediaSession 仅在 onMediaItemTransition 时
      // 同步系统封面（SystemUI 从 artUri 下载显示）；setUrl 无 artUri 时通知栏缺失封面，
      // 而 applySessionMetadata 的 bitmap 经 replaceMediaItem 注入不触发 MediaSession 同步。
      // 刻意不带 id（与 _setUrlAndPlay 口径一致）：framework MEDIA_ID 保持空串由
      // vivo hook 补 title|artist 身份，与 lrc_change extras 的 meidia_id 匹配口径一致。
      final artUriParsed = artUri != null ? Uri.tryParse(artUri) : null;
      final loaded = await standby.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          tag: {
            'title': title ?? '',
            'artist': artist,
            'album': null,
            'artUri': artUriParsed?.toString(),
          },
        ),
      );
      if (generation != _crossfadePrepareGeneration) {
        await _releaseStaleCrossfadePreparation(standby);
        return false;
      }
      _preparedPlayer = standby;
      // ignore: avoid_print
      print('[Crossfade] 预加载完成 dur=${loaded?.inSeconds}s');
      return true;
    } catch (e) {
      if (generation == _crossfadePrepareGeneration) {
        _preparedPlayer = null;
      }
      // ignore: avoid_print
      print('[Crossfade] prepare 失败: $e');
      return false;
    } finally {
      turn.complete();
    }
  }

  Future<void> _releaseStaleCrossfadePreparation(AudioPlayer player) async {
    try {
      await player.pause();
      await player.seek(Duration.zero);
      await player.setVolume(_userVolume * _vnAttenLinear);
    } catch (_) {}
  }

  /// 丢弃已预加载但尚未使用的备用播放器状态（手动切歌等场景）。
  void discardPreparedCrossfade() {
    _crossfadePrepareGeneration++;
    _preparedPlayer = null;
  }

  /// 把活动播放器速率复位到用户速度（手动切歌 / 上一首 / 关闭 automix 时调用）。
  Future<void> resetAutomixRate(double userSpeed) async {
    _preparedAutomixRate = 1.0;
    try {
      await _activePlayer.setSpeed(userSpeed);
    } catch (_) {}
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
    print(
      '[Crossfade] start dur=${duration.inMilliseconds}ms vol=$targetVolume',
    );
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
        if (token != _crossfadeToken) {
          // 取证：斜坡被中止 = 有别的路径（abortCrossfade / 已过交叉点的暂停收尾 /
          // 手动切歌）接管了这两个播放器。若用户听到「音量突然变大」，
          // 这条日志与紧随其后的 VolAudit 一起能定位是谁写的音量。
          // ignore: avoid_print
          print('[Crossfade] ⚠ 斜坡被中止（token 失效）'
              ' t=${(DateTime.now().difference(started).inMilliseconds / (totalMs <= 0 ? 1 : totalMs)).clamp(0.0, 1.0).toStringAsFixed(2)}');
          return;
        }
        // 进度按**真实经过时间**算，不是累加步数。切歌那一瞬 Dart 事件循环要
        // 跑 UI 重建 / 封面取色 / 预取，Future.delayed 会显著超时；累加步数会
        // 把斜坡越拖越长，表现为"规定时间到了还没淡完，最后突然跳回正常音量"。
        // 用 wall clock 后事件循环卡顿只让步子变粗，淡化始终按时收尾。
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        final t = totalMs <= 0 ? 1.0 : (elapsed / totalMs).clamp(0.0, 1.0);
        final gains = crossfadeGains(t);
        // 两路各自的响度衰减：旧歌用 _vnAttenLinear、新歌用 _vnAttenLinearStandby。
        // 漏掉任一都会让该路比正常播放响 1/atten 倍（音量均衡开启时最明显）。
        final rampOut = targetVolume * gains.outGain * _vnAttenLinear;
        final rampIn = targetVolume * gains.inGain * _vnAttenLinearStandby;
        // 不 await：每步两次 MethodChannel 调用，串行 await 会把步长拉长
        // ignore: discarded_futures
        outgoing.setVolume(rampOut);
        // ignore: discarded_futures
        incoming.setVolume(rampIn);
        final quartile = (t * 8).floor();
        if (quartile != loggedQuartile) {
          loggedQuartile = quartile;
          // 期望值必须与上面**实际下发**的值同源（含衰减），否则衰减 ≠ 1 时
          // 偏差检测会误报。
          final expectedOut = rampOut;
          final expectedIn = rampIn;
          // 读回**实际**音量与曲线期望值比对（volume 是同步 getter，零开销）。
          // 偏差过大 = 有别的代码路径在同一时间往这两个播放器写音量
          // （暂停淡入/淡出循环、音量滑块、abort 收尾、归一化增益下发等），
          // 斜坡被外来音量覆盖正是切歌爆音的头号嫌疑。
          // 必须留证据再动手，不靠猜。
          final actualOut = outgoing.volume;
          final actualIn = incoming.volume;
          final outDrift = (actualOut - expectedOut).abs();
          final inDrift = (actualIn - expectedIn).abs();
          final driftNote = (outDrift > 0.1 || inDrift > 0.1)
              ? ' ⚠音量偏差 out实际=${actualOut.toStringAsFixed(2)}'
                  ' in实际=${actualIn.toStringAsFixed(2)}'
              : '';
          // ignore: avoid_print
          print(
            '[Crossfade] t=${t.toStringAsFixed(3)} '
            '$outLabel(out)=${expectedOut.toStringAsFixed(2)} '
            '$inLabel(in)=${expectedIn.toStringAsFixed(2)}$driftNote',
          );
        }
        if (t >= 1.0) break;
      }
      if (token != _crossfadeToken) return;
      // 用 _userVolume 而非入口捕获的 targetVolume：斜坡进行中用户调过音量
      // 时（AudioService.setVolume 淡化中只更新 _userVolume 提前返回），
      // 结束以最新音量收尾，否则会回跳淡化开始时的旧音量
      // ignore: avoid_print
      print(
        '[Crossfade] 收尾 setVolume 后 activeIsMain=' +
            (_activePlayer == _mainPlayer).toString(),
      );
      // 活动播放器即将换给 incoming：此刻把新歌的衰减升格为「当前」，
      // 这样后续 setVolume / abort / 归一化重算都按新歌的衰减走。
      _vnAttenLinear = _vnAttenLinearStandby;
      await incoming.setVolume(_activePlayerVolumeTarget);
      await _retireFadedPlayer(outgoing);
      // ignore: avoid_print
      print(
        '[Crossfade] 收尾 retire 后 activeIsMain=' +
            (_activePlayer == _mainPlayer).toString(),
      );
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
  ///
  /// [keepVolume]：调用方**紧接着就要让播放器停声**（`pause()` / `stop()`）时置 true。
  /// 此时恢复音量毫无意义 —— 只会让淡入中的一路先"音量升上去"再停，
  /// 听感就是用户报的「点暂停时音量突然变大」。恢复播放由 `resume()` 的
  /// 淡入流程负责（它会从 0.01 重新淡入到目标音量），不需要这里兜。
  void abortCrossfade({bool keepVolume = false}) {
    if (!_crossfading) return;
    _crossfadeToken++;
    final outgoing = _fadingOutPlayer;
    final incoming = _fadingInPlayer;
    final crossed = _crossedOver;
    _setCrossfading(false);
    _fadingOutPlayer = null;
    _fadingInPlayer = null;
    // 取证：abort 的收尾会把已 promote 的 incoming 音量拉回正常（见下方），
    // 中途接管时正是用户报的「切歌时音量突然变大」。必须知道**是谁**在淡化中途
    // 调了它（实测 t≈0.54 被 `pause()` 路径打断），才能判断这次中断是否必要。
    final caller = StackTrace.current
        .toString()
        .split('\n')
        .skip(1)
        .take(3)
        .map((l) {
          final m = RegExp(r'\((?:(?:package|dart):[^)]*?/)?([^/)]+\.dart(?::\d+)?)')
              .firstMatch(l);
          return m?.group(1) ?? l.trim().split(' ').first;
        })
        .join(' <- ');
    // ignore: avoid_print
    print('[Crossfade] aborted crossed=$crossed 调用方: $caller');
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
    // 已过交叉点：活动播放器已经是 incoming（新歌），它的衰减是 standby 那份。
    // 不升格会把旧歌的衰减套到新歌上，导致音量偏差。
    if (crossed) _vnAttenLinear = _vnAttenLinearStandby;
    // 调用方马上要停声：不恢复音量（见 [keepVolume] 的说明）
    if (keepVolume) return;
    // 收尾**绝不能一步 setVolume**：实测 abort 常发生在淡化中途（t≈0.54），
    // 此时 incoming 音量还在斜坡低位（约 0.72），一步拉到满就是用户听到的
    // 「点暂停/切歌时音量突然变大」。改为 150ms 的补偿斜坡 —— 快速但连续。
    final rampToken = _crossfadeToken;
    // ignore: discarded_futures
    _rampVolumeTo(_activePlayer, _activePlayerVolumeTarget, rampToken);
  }

  /// 把播放器音量从**当前值**平滑升降到 [target]（默认 150ms / 6 步）。
  ///
  /// 专供 abort 收尾：`abortCrossfade` 会在淡化中途被 `pause()` / `setUrl()` 等
  /// 路径打断，此时淡入方音量还在斜坡低位，直接 `setVolume(target)` 会造成
  /// 「切歌时音量突然变大」（真机实测 12:46:58，t=0.54 处 incoming 0.72 → 1.00）。
  ///
  /// [token] 是抢占保护：期间若又开始新的淡化或再次 abort，立即停手，
  /// 否则会把音量写到已经换过角色的播放器上。
  Future<void> _rampVolumeTo(
    AudioPlayer p,
    double target,
    int token, {
    int ms = 150,
  }) async {
    final from = p.volume;
    if (!from.isFinite || (from - target).abs() < 0.01) {
      try {
        await p.setVolume(target);
      } catch (_) {}
      return;
    }
    const steps = 6;
    final stepMs = (ms / steps).round();
    for (var i = 1; i <= steps; i++) {
      if (token != _crossfadeToken) return;
      await Future<void>.delayed(Duration(milliseconds: stepMs));
      if (token != _crossfadeToken) return;
      try {
        await p.setVolume(from + (target - from) * i / steps);
      } catch (_) {
        return;
      }
    }
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
      await p.setVolume(_activePlayerVolumeTarget);
    } catch (_) {}
  }

  Future<void> dispose() async {
    abortCrossfade();
    // 释放前先关分离，避免原生侧还挂着 processor 的 hook
    if (_stemActive) {
      _stemActive = false;
      await StemSeparationService.instance.setEnabled(false);
    }
    await _media3FocusSub?.cancel();
    await _accompanyDriftSub?.cancel();
    _accompanyDriftSub = null;
    await _accompanyStateSub?.cancel();
    _accompanyStateSub = null;
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
    await _accompanyPlayer?.dispose();
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
  Map<String, String>? headers,
}) {
  return AudioSource.uri(
    Uri.parse(url),
    // 远程歌曲（WebDAV）的鉴权头，经 just_audio 本地代理附加到播放请求
    headers: headers,
    tag: {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'artUri': artUri?.toString(),
    },
  );
}

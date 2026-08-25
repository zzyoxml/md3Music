import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

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

/// 音频焦点 / 音频会话管理。
///
/// 关键设计：
/// - [_pausedByInterruption]：标记“暂停是由音频焦点丢失引起的”。
///   仅在这种情况下才在重新获得焦点时自动恢复播放，
///   避免覆盖用户主动的暂停。
/// - 区分临时中断（pause / unknown → 之后会自动恢复）和永久丢失
///   （如电话来电、强制中断），后者由 audio_session 标记 `dispose` 状态。
class AudioService {
  static final AudioService _instance = AudioService._internal();

  factory AudioService() => _instance;

  AudioService._internal();

  final AudioPlayer _player = AudioPlayer(
    // 关闭 just_audio 内置的中断处理（handleInterruptions=false）：
    // 所有音频焦点策略统一由本服务按 AudioFocusInterruptionMode 处理，
    // 避免两套逻辑叠加导致重复暂停/恢复。
    handleInterruptions: false,
    // MD3Music fork: 关闭 just_audio 对 audio_session 的自动激活。
    // 焦点由 Media3 的 AudioFocusManager 唯一管理（handleAudioFocus=true），
    // audio_session 保持 setActive(false)；否则播放时会重新激活 audio_session
    // 抢回焦点，与 Media3 交替 request/abandon 导致播放反复暂停。
    handleAudioSessionActivation: false,
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
  );
  final ConcatenatingAudioSource _playlistSource = ConcatenatingAudioSource(
    children: [],
  );

  AudioPlayer get player => _player;

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Stream<bool> get playingStream => _player.playingStream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  ProcessingState get processingState => _player.processingState;

  Stream<SequenceState?> get sequenceStateStream => _player.sequenceStateStream;

  Stream<double> get speedStream => _player.speedStream;

  bool get playing => _player.playing;

  Duration get position => _player.position;

  Duration? get duration => _player.duration;

  double get speed => _player.speed;

  /// Android 音频会话 ID，供均衡器绑定使用。
  /// just_audio 0.9.x 在播放器初始化后才会有值。
  int? get androidAudioSessionId => _player.androidAudioSessionId;

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
    _player.setIgnoreAudioFocus(value);
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

  /// 同步 native 焦点处理标志（Media3 AudioFocusManager）：
  /// - [AudioFocusInterruptionMode.keepPlaying]（非忽略时）：skip Media3 内置处理，
  ///   播放与进度完全保持——避免 suppression 无声导致 MediaSession 进度错开
  /// - forced willPauseWhenDucked：忽略 / keepPlaying / pauseAndResume → true
  ///   （系统派发 LOSS_TRANSIENT 事件而非自动 duck 音量）；duckAndRestore → false
  ///   （系统级自动 duck 0.2 → 自动恢复）
  void _syncNativeFocusFlags() {
    final keepPlayingActive = !_ignoreAudioFocus &&
        _interruptionMode == AudioFocusInterruptionMode.keepPlaying;
    // ignore: discarded_futures
    _player.setForceKeepPlaying(keepPlayingActive);
    // ignore: discarded_futures
    _player.setForceWillPauseWhenDucked(
        _ignoreAudioFocus ||
            _interruptionMode != AudioFocusInterruptionMode.duckAndRestore);
  }

  /// Media3 AudioFocusManager 原始焦点事件订阅（真实系统事件，先于 Media3
  /// 自动 duck/pause 处理发出）。keepPlaying 模式据此对抗自动暂停。
  StreamSubscription<int>? _media3FocusSub;

  Future<void> init() async {
    await _player.setLoopMode(LoopMode.off);
    await _configureAudioSession();
    // MD3Music fork: 焦点事件源改为 Media3 AudioFocusManager 转发
    // （audio_session 的 interruptionEventStream 已停用，见 _configureAudioSession）
    _media3FocusSub =
        _player.audioFocusChangeStream.listen(_handleMedia3FocusChange);
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
        print('[AudioFocus] keepPlaying LOSS, playing=${_player.playing}');
        if (_player.playing) {
          // ignore: discarded_futures
          _player.pause();
        }
      }
      return;
    }
    if (_interruptionMode == AudioFocusInterruptionMode.pauseAndResume) {
      if (focusChange != 1) {
        if (_player.playing) {
          _pausedByInterruption = true;
          // ignore: discarded_futures
          _player.pause();
        }
      } else if (_pausedByInterruption) {
        _pausedByInterruption = false;
        // ignore: discarded_futures
        _player.play();
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
    await _player.play();
  }

  Future<void> pause() async {
    // 用户主动暂停：清除中断暂停标记（中断引起的暂停不在 GAIN 时自动恢复）
    _pausedByInterruption = false;
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setUrl(String url) async {
    await _player.setUrl(url, headers: const {});
  }

  Future<void> setPlaylist(
    List<UriAudioSource> sources, {
    int startIndex = 0,
  }) async {
    _playlistSource.clear();
    if (sources.isNotEmpty) {
      _playlistSource.addAll(sources);
    }
    await _player.setAudioSource(
      _playlistSource,
      initialIndex: startIndex,
      initialPosition: Duration.zero,
    );
  }

  Future<void> addAudioSource(UriAudioSource source) async {
    await _playlistSource.add(source);
  }

  Future<void> addAllAudioSources(List<UriAudioSource> sources) async {
    await _playlistSource.addAll(sources);
  }

  /// 在指定位置插入音频源，不打断当前播放。
  /// 用于"下一首播放"等需要在队列中间插入的场景。
  Future<void> insertAudioSourceAt(int index, UriAudioSource source) async {
    await _playlistSource.insert(index, source);
  }

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
  }

  Future<void> seekToNext() async {
    await _player.seekToNext();
  }

  Future<void> seekToPrevious() async {
    await _player.seekToPrevious();
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _player.setLoopMode(mode);
  }

  Future<void> setShuffleModeEnabled(bool enabled) async {
    await _player.setShuffleModeEnabled(enabled);
  }

  Future<void> dispose() async {
    await _media3FocusSub?.cancel();
    await _player.dispose();
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

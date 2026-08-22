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

  /// 是否因为音频焦点丢失 / 设备中断（拔耳机、来电等）而处于暂停状态。
  /// 在此状态下若重新获得音频焦点，可自动恢复播放。
  /// 主动调用 [pause] 不会设置此标志。
  bool _pausedByInterruption = false;
  bool get wasPausedByInterruption => _pausedByInterruption;

  /// 恢复中的互斥锁：焦点事件流与就绪兜底流可能并发触发恢复，
  /// 用该标志防止重复进入 [play]，避免恢复瞬间的状态抖动。
  bool _resumeInProgress = false;

  /// 是否完全忽略音频焦点：开启后不响应任何中断事件
  /// （来电 / 导航 / 拔耳机等），保持音量与播放状态不变。
  bool _ignoreAudioFocus = false;
  bool get ignoreAudioFocus => _ignoreAudioFocus;
  void setIgnoreAudioFocus(bool value) => _ignoreAudioFocus = value;

  /// 短暂失去音频焦点时的处理策略（默认：暂停后自动恢复）。
  AudioFocusInterruptionMode _interruptionMode =
      AudioFocusInterruptionMode.pauseAndResume;
  AudioFocusInterruptionMode get interruptionMode => _interruptionMode;
  void setInterruptionMode(AudioFocusInterruptionMode mode) =>
      _interruptionMode = mode;

  /// duck 降音量前的原音量，用于中断结束后还原，
  /// 避免无条件弹回 1.0 覆盖用户手动设定的音量。
  double _volumeBeforeDuck = 1.0;

  /// duck 模式下降音量的目标值（原音量的比例 0.5）。
  final double _duckVolume = 0.5;

  /// 各事件流的订阅句柄，dispose 时统一取消，避免单例长期持有泄漏。
  StreamSubscription<PlayerState>? _resumeSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;

  Future<void> init() async {
    await _player.setLoopMode(LoopMode.off);
    await _configureAudioSession();
    _setupResumeOnReady();
  }

  /// 兜底恢复：当 [tryResumeAfterFocusLoss] 因播放器未 ready 跳过时，
  /// 监听播放器状态变为 ready 后自动尝试恢复。
  void _setupResumeOnReady() {
    _resumeSub = _player.playerStateStream.listen((state) {
      if (_pausedByInterruption &&
          state.processingState == ProcessingState.ready) {
        // ignore: discarded_futures
        tryResumeAfterFocusLoss();
      }
    });
  }

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _interruptionSub = session.interruptionEventStream.listen((event) {
        // 完全忽略模式：对所有中断事件不做任何响应（保持音量、保持播放）
        if (_ignoreAudioFocus) return;
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // 仅「降低音量后自动恢复」模式响应 duck，其余模式保持音量
              // （避免荣耀平板 V8 Pro 频繁 duck/unduck 音量波动）。
              if (_interruptionMode ==
                      AudioFocusInterruptionMode.duckAndRestore &&
                  _player.playing) {
                _volumeBeforeDuck = _player.volume;
                // ignore: discarded_futures
                _player.setVolume(_duckVolume);
              }
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              switch (_interruptionMode) {
                case AudioFocusInterruptionMode.keepPlaying:
                  break; // 保持播放、保持音量
                case AudioFocusInterruptionMode.pauseAndResume:
                  if (_player.playing) {
                    _pausedByInterruption = true;
                    pause();
                  }
                  break;
                case AudioFocusInterruptionMode.duckAndRestore:
                  // 暂停型中断也改为降音量处理：播放不中断，仅压低音量
                  if (_player.playing) {
                    _volumeBeforeDuck = _player.volume;
                    // ignore: discarded_futures
                    _player.setVolume(_duckVolume);
                  }
                  break;
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (_interruptionMode ==
                  AudioFocusInterruptionMode.duckAndRestore) {
                // ignore: discarded_futures
                _player.setVolume(_volumeBeforeDuck);
              }
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_interruptionMode ==
                  AudioFocusInterruptionMode.pauseAndResume) {
                // 焦点恢复：仅在是被动暂停时尝试恢复（不覆盖用户主动暂停）
                tryResumeAfterFocusLoss();
              } else if (_interruptionMode ==
                  AudioFocusInterruptionMode.duckAndRestore) {
                // 恢复中断前的原音量
                // ignore: discarded_futures
                _player.setVolume(_volumeBeforeDuck);
              }
              break;
          }
        }
      });
      // 拔耳机 / 蓝牙断开：通常伴随系统焦点变更，但 just_audio 也会收到
      // becomingNoisyEvent。统一标记为「中断暂停」以便外层恢复逻辑复用。
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        if (_ignoreAudioFocus) return; // 忽略模式下拔耳机也不暂停
        if (_player.playing) {
          _pausedByInterruption = true;
          pause();
        }
      });
    } catch (e) {}
  }

  /// 焦点恢复时尝试自动恢复播放。
  ///
  /// 仅当：
  /// 1) 当前处于「中断暂停」状态（_pausedByInterruption=true）
  /// 2) 播放器已 ready（processingState == ready）
  /// 时才会调 play()，避免与用户主动暂停冲突。
  Future<void> tryResumeAfterFocusLoss() async {
    if (_resumeInProgress) return; // 防并发恢复
    if (!_pausedByInterruption) return;
    if (_player.processingState != ProcessingState.ready) {
      // 还没 ready，留着标志位等下次状态变化再试
      return;
    }
    _resumeInProgress = true;
    try {
      _pausedByInterruption = false;
      await play();
    } finally {
      _resumeInProgress = false;
    }
  }

  Future<void> play() async {
    // 主动 play 不影响 _pausedByInterruption 标志；
    // 若是被动恢复（_pausedByInterruption=true），play 后清掉标志。
    await _player.play();
    _pausedByInterruption = false;
  }

  Future<void> pause() async {
    // pause() 由外部主动调用时不修改 _pausedByInterruption；
    // 中断引起的 pause 由 _configureAudioSession 内置 listener 设置标志。
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
    _pausedByInterruption = false;
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
    await _resumeSub?.cancel();
    await _interruptionSub?.cancel();
    await _noisySub?.cancel();
    await _player.dispose();
    _pausedByInterruption = false;
    _resumeInProgress = false;
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

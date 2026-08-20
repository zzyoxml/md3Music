import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

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

  /// 是否响应 duck 压低音量（导航 / 游戏等会短暂压低背景音乐的场景）。
  /// 默认关闭：荣耀平板 V8 Pro 在频繁 duck/unduck 时音量忽高忽低，
  /// 开启后 duck 会把音量压到 [_duckVolume]，结束恢复 [1.0]。
  bool _duckEnabled = false;
  final double _duckVolume = 0.5;
  void setDuckEnabled(bool value) => _duckEnabled = value;

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
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (_duckEnabled && _player.playing) {
                // 仅在显式开启 duck 时压低音量；默认忽略以
                // 避免荣耀平板 V8 Pro 频繁 duck/unduck 音量波动。
                // ignore: discarded_futures
                _player.setVolume(_duckVolume);
              }
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_player.playing) {
                _pausedByInterruption = true;
                pause();
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (_duckEnabled) {
                // ignore: discarded_futures
                _player.setVolume(1.0);
              }
              break;
            case AudioInterruptionType.pause:
              // 焦点恢复：仅在是被动暂停时尝试恢复（不覆盖用户主动暂停）
              tryResumeAfterFocusLoss();
              break;
            case AudioInterruptionType.unknown:
              // 修复：unknown 型中断（部分游戏引擎 / 游戏内通话上报）结束时
              // 也尝试恢复播放，否则音乐被动暂停后无法自动恢复。
              // ignore: discarded_futures
              tryResumeAfterFocusLoss();
              break;
          }
        }
      });
      // 拔耳机 / 蓝牙断开：通常伴随系统焦点变更，但 just_audio 也会收到
      // becomingNoisyEvent。统一标记为「中断暂停」以便外层恢复逻辑复用。
      _noisySub = session.becomingNoisyEventStream.listen((_) {
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

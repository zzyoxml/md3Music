import 'dart:async';

import 'package:just_audio/just_audio.dart' as just_audio;

/// PlayerProvider竞态测试用服务：可控装载完成顺序，播放命令立即返回。
class ControlledAudioService {
  final _player = _ControlledAudioPlayer();
  final _positionState = StreamController<Duration>.broadcast();
  final _playerState = StreamController<just_audio.PlayerState>.broadcast();
  final _playingState = StreamController<bool>.broadcast();
  final _speedState = StreamController<double>.broadcast();
  final _playlistWaiters = <_PlaylistWaiter>[];
  final List<Completer<void>> playlistLoads = [];
  final List<Duration?> sourceInitialPositions = [];
  int playCommandCount = 0;
  int pauseCommandCount = 0;
  int seekCount = 0;
  Duration? lastSeekPosition;
  Completer<void>? seekCompleter;
  Completer<void>? pauseCompleter;
  Completer<void>? pauseStarted;
  Object? nextSetUrlError;
  bool playing = false;
  bool autoResumeAfterLoad = false;
  bool get isCrossfading => false;

  dynamic get player => _player;
  bool get hasPlayerStateListener => _playerState.hasListener;

  Stream<Duration> get positionStream => _positionState.stream;
  Stream<Duration?> get durationStream => const Stream.empty();
  Stream<bool> get playingStream => _playingState.stream;
  Stream<just_audio.PlayerState> get playerStateStream => _playerState.stream;
  Stream<just_audio.SequenceState?> get sequenceStateStream =>
      const Stream.empty();
  Stream<double> get speedStream => _speedState.stream;
  just_audio.ProcessingState get processingState => _player.processingState;

  Future<void> init() async {}
  Future<void> setLoopMode(just_audio.LoopMode _) async {}
  Future<void> setShuffleModeEnabled(bool _) async {}
  Future<void> setIgnoreAudioFocus(bool _) async {}
  void setInterruptionMode(Object _) {}
  Future<void> setVolume(double _) async {}
  Future<void> pause() async {
    pauseCommandCount++;
    if (!(pauseStarted?.isCompleted ?? true)) pauseStarted!.complete();
    final completer = pauseCompleter;
    if (completer != null) await completer.future;
    final wasPlaying = playing;
    playing = false;
    _player.playing = false;
    if (autoResumeAfterLoad && wasPlaying) _playingState.add(false);
  }

  Future<void> seek(Duration position) async {
    seekCount++;
    lastSeekPosition = position;
    final completer = seekCompleter;
    if (completer != null) await completer.future;
  }

  void abortCrossfade({bool keepVolume = false}) {}
  void discardPreparedCrossfade() {}
  Future<void> resetAutomixRate(double _) async {}

  /// AutoMix 实测响度补给（真实实现会改音量均衡增益）；替身只吞掉调用。
  Future<void> applyMeasuredLoudness(double? _) async {}

  Future<void> playCommand({
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    playCommandCount++;
    playing = true;
    _player.playing = true;
  }

  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> _, {
    int startIndex = 0,
    Duration? initialPosition,
  }) {
    sourceInitialPositions.add(initialPosition);
    return _beginLoad();
  }

  /// [tag]：just_audio `setUrl` 的媒体元数据（生产实现带该形参——fork 用它补
  /// vivo 原子随身听/锁屏身份，见 `audio_service_io.dart` 的 setUrl）。
  ///
  /// **必须与生产签名保持同步**：`PlayerProvider` 以 `dynamic` 调用本替身，
  /// 少一个形参就抛 `NoSuchMethodError`，而该异常在加载链路里被静默吞掉
  /// （诊断日志只剩 `load.end outcome=exception errorClass=NoSuchMethodError`），
  /// 表现为「音源永不装载 → `waitForPlaylistLoads` 永久等待 → 用例挂到 10 分钟」。
  Future<void> setUrl(
    String _, {
    double? loudnessLufs,
    double? loudnessPeakDb,
    Duration? initialPosition,
    dynamic tag,
  }) {
    sourceInitialPositions.add(initialPosition);
    final error = nextSetUrlError;
    nextSetUrlError = null;
    if (error != null) return Future<void>.error(error);
    return _beginLoad();
  }

  Future<void> completeSourceLoad(int index) async {
    playlistLoads[index].complete();
    if (autoResumeAfterLoad) {
      // 模拟平台在「播放中 setAudioSource」完成后保留旧 playWhenReady。
      playing = true;
      _player.playing = true;
      _playingState.add(true);
    }
    if (index == playlistLoads.length - 1) {
      _player.processingState = just_audio.ProcessingState.ready;
      _playerState.add(
        just_audio.PlayerState(false, just_audio.ProcessingState.ready),
      );
    }
  }

  void emitPlaying(bool playing) {
    this.playing = playing;
    _player.playing = playing;
    _playingState.add(playing);
  }

  void emitPosition(Duration position) => _positionState.add(position);

  void setDiagnosticSnapshot({
    required Duration position,
    required Duration bufferedPosition,
    required double speed,
  }) {
    _player.position = position;
    _player.bufferedPosition = bufferedPosition;
    _player.speed = speed;
  }

  void emitPlayerState() => _playerState.add(
    just_audio.PlayerState(_player.playing, _player.processingState),
  );

  /// 模拟平台自然播完：同步 processingState 后在 playerStateStream 上吐一次
  /// completed，走 PlayerProvider 真实的 `_handlePlaybackCompleted` 通路。
  void emitCompleted() {
    _player.processingState = just_audio.ProcessingState.completed;
    _playerState.add(
      just_audio.PlayerState(_player.playing, just_audio.ProcessingState.completed),
    );
  }

  void emitSpeed(double speed) {
    _player.speed = speed;
    _speedState.add(speed);
  }

  void emitError(just_audio.PlayerException error) {
    _player.emitError(error);
  }

  Future<void> dispose() async {
    await _positionState.close();
    await _playingState.close();
    await _speedState.close();
    await _playerState.close();
    await _player.dispose();
  }

  Future<void> _beginLoad() {
    final load = Completer<void>();
    playlistLoads.add(load);
    _player.processingState = just_audio.ProcessingState.loading;
    _playerState.add(
      just_audio.PlayerState(false, just_audio.ProcessingState.loading),
    );
    for (final waiter in List<_PlaylistWaiter>.from(_playlistWaiters)) {
      if (playlistLoads.length >= waiter.target) {
        _playlistWaiters.remove(waiter);
        waiter.completer.complete();
      }
    }
    return load.future;
  }

  Future<void> waitForPlaylistLoads(int count) {
    if (playlistLoads.length >= count) return Future<void>.value();
    final completer = Completer<void>();
    _playlistWaiters.add(_PlaylistWaiter(count, completer));
    return completer.future;
  }
}

class _ControlledAudioPlayer {
  final _errors = StreamController<just_audio.PlayerException>.broadcast(
    sync: true,
  );
  Stream<just_audio.PlayerException> get errorStream => _errors.stream;
  bool playing = false;
  Duration position = Duration.zero;
  Duration bufferedPosition = Duration.zero;
  double speed = 1.0;
  double volume = 1;
  Completer<void>? volumeChanged;
  void setVolume(double value) {
    volume = value;
    final changed = volumeChanged;
    if (changed != null && !changed.isCompleted) changed.complete();
  }

  void emitError(just_audio.PlayerException error) => _errors.add(error);

  Future<void> dispose() => _errors.close();

  void seek(Duration _) {}
  just_audio.ProcessingState processingState = just_audio.ProcessingState.ready;
}

class _PlaylistWaiter {
  final int target;
  final Completer<void> completer;

  const _PlaylistWaiter(this.target, this.completer);
}

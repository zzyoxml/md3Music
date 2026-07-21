import 'dart:developer' as developer;

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();

  factory AudioService() => _instance;

  AudioService._internal();

  final AudioPlayer _player = AudioPlayer();
  final ConcatenatingAudioSource _playlistSource = ConcatenatingAudioSource(children: []);

  /// 标记当前暂停是否由音频焦点被打断导致。
  /// 仅在 interruption begin 时置 true；用户主动 pause/play 时清零。
  /// interruption end 时只有此标记为 true 才自动恢复播放，避免
  /// "用户手动暂停 → 其他 app 短暂占用焦点又释放 → 错误自动恢复播放"。
  ///
  /// 注意：Android 的 AUDIOFOCUS_LOSS（永久丢失，如抖音请求 AUDIOFOCUS_GAIN）
  /// 只触发 interruption begin，不触发 interruption end。
  /// 这种情况需要 app 回到前台时调用 [tryResumeAfterFocusLoss] 主动恢复。
  bool _pausedByInterruption = false;

  AudioPlayer get player => _player;

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Stream<bool> get playingStream => _player.playingStream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  Stream<SequenceState?> get sequenceStateStream => _player.sequenceStateStream;

  Stream<double> get speedStream => _player.speedStream;

  bool get playing => _player.playing;

  Duration get position => _player.position;

  Duration? get duration => _player.duration;

  double get speed => _player.speed;

  Future<void> init() async {
    await _player.setLoopMode(LoopMode.off);
    await _configureAudioSession();
  }

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      session.interruptionEventStream.listen((event) {
        developer.log(
          'interruption event: begin=${event.begin}, type=${event.type}, '
          'player.playing=${_player.playing}, '
          'processingState=${_player.processingState}, '
          '_pausedByInterruption=$_pausedByInterruption',
          name: 'AudioService',
        );
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // 修复荣耀平板 V8 Pro 音量忽高忽低问题
              // 不再降低音量，而是保持原音量（避免频繁 duck/unduck 导致波动）
              // _player.setVolume(0.5);  // 注释掉：会导致音量波动
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_player.playing) {
                // 标记为"被打断的暂停"，恢复焦点时自动续播；
                // 直接调用 _player.pause() 绕过公开 pause()，保留标记。
                // 注意：Android AUDIOFOCUS_LOSS（永久丢失）也走这里，
                // 但不会触发 interruption end，需要 app 回前台时
                // 调用 tryResumeAfterFocusLoss 主动恢复。
                _pausedByInterruption = true;
                _player.pause();
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // 恢复时也不再调整音量，保持 1.0
              // _player.setVolume(1.0);  // 注释掉：避免音量波动
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // 焦点恢复时自动续播。
              // 部分设备/系统把焦点恢复事件映射成 unknown 而非 pause，
              // 因此 unknown 也需要处理，否则抖音等 app 打断后无法自动续播。
              // 仅当之前是被打断导致的暂停时才恢复，避免手动暂停被错误唤醒。
              // 放宽 processingState 检查：只要不是 idle/completed 就尝试恢复。
              if (_pausedByInterruption &&
                  !_player.playing &&
                  _player.processingState != ProcessingState.idle &&
                  _player.processingState != ProcessingState.completed) {
                _pausedByInterruption = false;
                developer.log('恢复播放：interruption end 触发自动续播',
                    name: 'AudioService');
                play();
              }
              break;
          }
        }
      });
      session.becomingNoisyEventStream.listen((_) {
        if (_player.playing) {
          // 拔耳机暂停不算"被打断"，焦点恢复时不应自动续播
          _pausedByInterruption = false;
          _player.pause();
        }
      });
    } catch (e) {
          }
  }

  Future<void> play() async {
    // 用户主动播放：清除打断标记，避免后续焦点事件误判
    _pausedByInterruption = false;
    await _player.play();
  }

  Future<void> pause() async {
    // 用户主动暂停：清除打断标记，避免后续焦点恢复时错误自动播放
    _pausedByInterruption = false;
    await _player.pause();
  }

  /// App 回到前台时调用：如果之前是被音频焦点打断暂停的，主动恢复播放。
  ///
  /// 背景：Android AUDIOFOCUS_LOSS（永久丢失，如抖音请求 AUDIOFOCUS_GAIN）
  /// 只触发 interruption begin，不触发 interruption end。
  /// 当抖音关闭释放焦点时，Android 发送 AUDIOFOCUS_GAIN 回调给
  /// audio_session 的 listener，但 EventChannel 可能在后台无法
  /// 传递事件到 Dart 层。因此在 app 回前台时，主动重新请求音频焦点
  /// （session.setActive(true)），触发 Android AudioManager 的
  /// AUDIOFOCUS_GAIN 回调，从而通过 EventChannel 发射 interruption end 事件。
  ///
  /// 返回 true 表示已恢复播放，false 表示不需要恢复（用户已手动操作或正在播放）。
  Future<bool> tryResumeAfterFocusLoss() async {
    developer.log(
      'tryResumeAfterFocusLoss: _pausedByInterruption=$_pausedByInterruption, '
      'playing=${_player.playing}, processingState=${_player.processingState}',
      name: 'AudioService',
    );
    if (!_pausedByInterruption) return false;

    // 重新激活 audio session，触发 Android 重新请求音频焦点。
    // 如果其他 app 已释放焦点，AudioManager 会立即回调 AUDIOFOCUS_GAIN，
    // audio_session 将发射 interruption end 事件，interruptionEventStream
    // 的监听器会自动恢复播放（检查 _pausedByInterruption 标记）。
    // 如果其他 app 仍持有焦点，setActive 会失败或焦点请求被拒绝，
    // _pausedByInterruption 保持 true，下次 resumed 时再试。
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
      developer.log('tryResumeAfterFocusLoss: session.setActive(true) 完成',
          name: 'AudioService');
    } catch (e) {
      developer.log('tryResumeAfterFocusLoss: session.setActive 失败: $e',
          name: 'AudioService');
    }

    // setActive 可能触发 interruption end → play()，也可能不触发。
    // 作为兜底：如果 setActive 后 _pausedByInterruption 仍为 true
    // 且播放器未在播放，说明焦点恢复事件可能被延迟或丢失。
    // 等一小段时间后检查，如果还没恢复就手动恢复。
    await Future.delayed(const Duration(milliseconds: 500));
    if (_pausedByInterruption &&
        !_player.playing &&
        _player.processingState != ProcessingState.idle &&
        _player.processingState != ProcessingState.completed) {
      _pausedByInterruption = false;
      developer.log('恢复播放：setActive 后兜底恢复', name: 'AudioService');
      await _player.play();
      return true;
    }
    return false;
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setUrl(String url) async {
    await _player.setUrl(
      url,
      headers: const {},
    );
  }

  Future<void> setPlaylist(List<UriAudioSource> sources, {int startIndex = 0}) async {
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

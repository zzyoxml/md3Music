import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';

import '../core/services/audio_service.dart';
import '../core/services/desktop_lyric_service.dart';
import '../core/services/lyricon_provider_service.dart';
import '../core/services/media_notification_service.dart';
import '../data/models/song.dart';
import '../data/repositories/history_repository.dart';
import '../data/repositories/playback_state_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../main.dart';
import '../widgets/apple_lyrics/models/lyric_line.dart';
import '../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'favorites_provider.dart';
import 'kugou_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';

enum AppLoopMode { off, one, all }

enum AudioQuality {
  standard('128', '标准音质'),
  high('320', '高音质'),
  flac('flac', '无损音质');

  const AudioQuality(this.value, this.label);
  final String value;
  final String label;
}

class PlayerProvider extends ChangeNotifier {
  Song? _currentSong;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  List<Song> _playlist = [];
  List<Song> _originalPlaylist = [];
  int _currentIndex = -1;
  AppLoopMode _loopMode = AppLoopMode.off;
  bool _shuffleEnabled = false;
  double _volume = 1.0;
  double _speed = 1.0;
  bool _isResolvingUrl = false;
  String? _resolveError;
  AudioQuality _audioQuality = AudioQuality.standard;

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  /// 当前播放时长。优先用音频引擎的实际时长，fallback 到歌曲元数据时长。
  ///
  /// fallback 的原因：恢复上次会话时音频源未加载，durationStream 会发射 null
  /// 覆盖 _duration。用 currentSong.duration 作为 fallback 让 mini player
  /// 进度条在恢复后立即可见，不需要等用户点播放。
  Duration? get duration => _duration ?? _currentSong?.duration;
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  AppLoopMode get loopMode => _loopMode;
  bool get shuffleEnabled => _shuffleEnabled;
  double get volume => _volume;
  double get speed => _speed;
  bool get isResolvingUrl => _isResolvingUrl;
  String? get resolveError => _resolveError;
  AudioQuality get audioQuality => _audioQuality;
  String get audioQualityLabel => _audioQuality.label;

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<just_audio.PlayerState>? _playerStateSubscription;
  StreamSubscription<just_audio.SequenceState?>? _sequenceStateSubscription;
  StreamSubscription<double>? _speedSubscription;

  dynamic _audioService;
  bool _audioInitialized = false;
  Future<void> Function()? onPlaylistEnd;
  // 未登录时尝试播放需联网歌曲,通知 UI 弹窗
  void Function()? onLoginRequired;

  // —— Lyricon 钩子字段 ——
  // 记录上次推送给 Lyricon 的歌曲，用于在 notifyListeners 回调中检测切歌
  // （PlayerProvider 没有专门的切歌回调，用 addListener 监听自身是最小侵入方式）
  Song? _lastLyriconSong;
  // 歌词异步拉取的竞态 token：每次切歌自增，过期结果被丢弃
  int _lyriconFetchToken = 0;

  // —— 上次播放状态恢复 ——
  // 持久化仓库：保存/读取"上次退出时的播放列表 + 索引 + 进度"
  final PlaybackStateRepository _playbackStateRepo = PlaybackStateRepository();
  // 恢复状态后首次按播放键时，需要 seek 到此进度并懒加载音频源；
  // 为 null 表示无待恢复进度，直接走普通 play() 路径
  Duration? _pendingResumePosition;

  PlayerProvider() {
    _initAudioService();
    // 监听自身变化检测切歌 → 推送 Lyricon（仅 enabled 时实际推送）
    addListener(_handleLyriconSongChange);
  }

  Future<void> _initAudioService() async {
    try {
      MediaNotificationService.initCallbacks();
      MediaNotificationService.onPrevious = () => previous();
      MediaNotificationService.onNext = () => next();
      MediaNotificationService.onTogglePlayPause = () {
        if (_isPlaying) {
          pause();
        } else {
          resume();
        }
      };
      MediaNotificationService.onSeekTo = (pos) {
        seek(Duration(milliseconds: pos));
      };
      final audioServiceModule = await _loadAudioService();
      _audioService = audioServiceModule;
      _audioInitialized = true;
      await _audioService.init();
      _initStreams();
      await _loadDefaultQuality();
      // 恢复上次退出时的播放状态（仅设置元数据，不播放）
      await restoreLastSession();
    } catch (e) {
          }
  }

  /// 恢复上次会话：设置播放列表/当前歌曲/进度，并预加载音频源。
  ///
  /// 预加载音频源（setUrl + seek，不播放）的目的是：
  /// 1. 让 durationStream 从音频引擎获取真实时长，mini player 进度条立即可见
  /// 2. seek 到上次进度，用户按播放键时直接续播，无需再次加载
  Future<void> restoreLastSession() async {
    try {
      final saved = await _playbackStateRepo.load();
      if (saved == null) return;
      _playlist = saved.playlist;
      _originalPlaylist = List.from(saved.playlist);
      _currentIndex = saved.currentIndex;
      _currentSong = saved.playlist[saved.currentIndex];
      _position = saved.position;
      _duration = _currentSong?.duration; // fallback，音频加载后会被真实值覆盖
      _pendingResumePosition = saved.position;
      // 重启后强制暂停：用户必须主动按播放键，避免冷启动突然出声
      _isPlaying = false;
      notifyListeners();
      _updateNotification();

      // 预加载音频源（不播放），让 durationStream 发射真实时长，
      // mini player 进度条立即可见，不需要等用户点播放。
      // _resolveAndPlayCurrentSong 会解析在线 URL 并调用 _setUrlAndPlay(playAfter: false)
      if (_currentSong != null && saved.position > Duration.zero) {
        await _resolveAndPlayCurrentSong(
            seekTo: saved.position, playAfter: false);
        // 预加载完成，音频已就绪。清除标记，resume() 不需要再次加载。
        _pendingResumePosition = null;
      }
    } catch (_) {}
  }

  /// 供 app.dart 在 AppLifecycleState.paused 时调用，保存当前播放状态。
  Future<void> savePlaybackStateForBackground() async {
    await _savePlaybackState();
  }

  /// 供 app.dart 在 AppLifecycleState.resumed 时调用。
  /// 如果当前是被音频焦点打断（如抖音抢占 AUDIOFOCUS_GAIN）导致的暂停，
  /// 主动恢复播放。用户手动暂停的情况下不会恢复。
  Future<void> tryResumeAfterFocusLoss() async {
    await _audioService?.tryResumeAfterFocusLoss();
  }

  /// 私有保存方法。多处调用（切歌/暂停/完成/清空）。
  /// fire-and-forget 调用即可，不阻塞 UI；失败静默忽略。
  Future<void> _savePlaybackState() async {
    try {
      if (_playlist.isEmpty || _currentSong == null) {
        await _playbackStateRepo.clear();
        return;
      }
      await _playbackStateRepo.save(
        playlist: _playlist,
        currentIndex: _currentIndex < 0 ? 0 : _currentIndex,
        position: _position,
      );
    } catch (_) {}
  }

  Future<void> _loadDefaultQuality() async {
    try {
      final settings = SettingsRepository();
      final qualityValue = await settings.getDefaultQuality();
            _audioQuality = AudioQuality.values.firstWhere(
        (q) => q.value == qualityValue,
        orElse: () {
                    return AudioQuality.standard;
        },
      );
            notifyListeners();
    } catch (e) {
          }
  }

  Future<dynamic> _loadAudioService() async {
    return AudioServiceLoader.load();
  }

  void _initStreams() {
    if (_audioService == null || !_audioInitialized) return;

    try {
      _positionSubscription = _audioService.positionStream.listen(
        (position) {
          _position = position;
          _updateNotificationPosition();
          notifyListeners();
          // 直接转发给 Lyricon，无节流。
          // positionStream 本身就是 ~200ms 周期（just_audio 默认），是天然节流。
          // MethodChannel 是异步的，不阻塞 Dart UI；setPosition 是 fire-and-forget。
          // 仅在播放中推送，暂停时跳过避免无意义 IPC。
          if (LyriconProviderService.instance.enabled && _isPlaying) {
            try {
              LyriconProviderService.instance
                  .setPosition(position.inMilliseconds);
            } catch (_) {}
          }
        },
        onError: (e) {
                  },
      );

      _durationSubscription = _audioService.durationStream.listen(
        (duration) {
          _duration = duration;
          notifyListeners();
        },
        onError: (e) {
                  },
      );

      _playingSubscription = _audioService.playingStream.listen(
        (isPlaying) {
          _isPlaying = isPlaying;
          _updateNotification();
          notifyListeners();
          // 播放/暂停切换时立即推 Lyricon，避免等下一个 positionStream tick
          // state 必须用 PlaybackStateCompat.STATE_PLAYING=3 / STATE_PAUSED=2
          if (LyriconProviderService.instance.enabled) {
            try {
              LyriconProviderService.instance.setPlaybackState(
                state: isPlaying ? 3 : 2,
                position: _position.inMilliseconds,
                speed: 1.0,
              );
            } catch (_) {}
          }
        },
        onError: (e) {
                  },
      );

      _playerStateSubscription = _audioService.playerStateStream.listen(
        (playerState) {
          try {
            if (playerState.processingState ==
                just_audio.ProcessingState.completed) {
              _handlePlaybackCompleted();
            }
          } catch (e) {
                      }
        },
        onError: (e) {
                  },
      );

      _sequenceStateSubscription = _audioService.sequenceStateStream.listen(
        (sequenceState) {
          try {
            if (sequenceState != null && sequenceState.currentSource != null) {
              final effectiveIndex = sequenceState.effectiveSequence.indexOf(
                sequenceState.currentSource!,
              );
              if (effectiveIndex >= _playlist.length - 2 &&
                  onPlaylistEnd != null) {
                onPlaylistEnd!();
              }
            }
          } catch (e) {
                      }
        },
        onError: (e) {
                  },
      );

      _speedSubscription = _audioService.speedStream.listen(
        (speed) {
          _speed = speed;
          notifyListeners();
        },
        onError: (e) {
                  },
      );
    } catch (e) {
          }
  }

  bool _handlingCompletion = false;

  Future<void> _handlePlaybackCompleted() async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      if (_loopMode == AppLoopMode.one) {
        seek(Duration.zero);
        _audioService?.play();
      } else if (_currentIndex >= _playlist.length - 1) {
        if (onPlaylistEnd != null) {
          await onPlaylistEnd!();
        } else {
          // 非 FM：最后一曲播完回到第一曲
          if (_shuffleEnabled) {
            final currentSong = _currentSong;
            final remaining = _playlist
                .where((s) => s.id != currentSong?.id)
                .toList();
            remaining.shuffle();
            // currentSong 可能为 null，使用 collection-if 条件添加
            _playlist = [
              if (currentSong != null) currentSong,
              ...remaining,
            ];
            _currentIndex = 0;
          } else {
            _currentIndex = 0;
          }
          if (_playlist.isNotEmpty) {
            _currentSong = _playlist[_currentIndex];
          }
          final ok = await _resolveAndPlayCurrentSong();
          if (!ok) {
            _resolveError = '无法获取播放链接';
          }
          notifyListeners();
          _savePlaybackState();
        }
      } else {
        next();
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  Future<void> playSong(Song song) async {
    if (song.isOnline && song.url == null) {
      await playOnlineSong(song);
      return;
    }

    _currentSong = song;
    _playlist = [song];
    _originalPlaylist = [song];
    _currentIndex = 0;
    _resolveError = null;
    _pendingResumePosition = null;  // 用户主动选歌，放弃待恢复进度
    _recordHistory(song);
    _updateNotification();
    notifyListeners();
    _savePlaybackState();

    if (_audioService != null) {
      final source = _createAudioSource(song);
      await _audioService.setPlaylist([source], startIndex: 0);
      await _audioService.play();
    }
  }

  Future<void> playOnlineSong(Song song) async {
        final apiClient = KugouApiClient();
    if (!apiClient.isLoggedIn) {
      onLoginRequired?.call();
      return;
    }
    _currentSong = song;
    _pendingResumePosition = null;  // 用户主动选歌，放弃待恢复进度
    _playlist = [song];
    _originalPlaylist = [song];
    _currentIndex = 0;
    _isResolvingUrl = true;
    _resolveError = null;
    _recordHistory(song);
    _updateNotification();
        notifyListeners();

    try {
      final apiClient = KugouApiClient();
      
      final result = await apiClient.getSongUrl(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result != null && result.url.isNotEmpty) {
                final resolvedSong = song.copyWith(url: result.url);
        _currentSong = resolvedSong;
        _playlist = [resolvedSong];
        _isResolvingUrl = false;
                notifyListeners();
        _savePlaybackState();

        if (_audioService != null) {
                    final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
                  } else {
                  }
      } else {
                _isResolvingUrl = false;
        _resolveError = '无法获取播放链接';
        notifyListeners();
      }
    } catch (e) {
            _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }
  }

  Future<void> playPlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;

    _playlist = List.from(songs);
    _originalPlaylist = List.from(songs);
    _currentIndex = startIndex;
    _currentSong = songs[startIndex];
    _resolveError = null;
    _recordHistory(songs[startIndex]);
    notifyListeners();
    _savePlaybackState();

    if (_currentSong!.isOnline && _currentSong!.url == null) {
      _isResolvingUrl = true;
      notifyListeners();

      try {
        final apiClient = KugouApiClient();
        final result = await apiClient.getSongUrl(
          _currentSong!.id,
          quality: _audioQuality.value,
          albumId: _currentSong!.albumId,
          albumAudioId: _currentSong!.albumAudioId,
        );

        if (result != null && result.url.isNotEmpty) {
          final resolvedSong = _currentSong!.copyWith(url: result.url);
          _currentSong = resolvedSong;
          _playlist[startIndex] = resolvedSong;
          _isResolvingUrl = false;
          notifyListeners();
          _savePlaybackState();

          if (_audioService != null) {
            await _setUrlAndPlay(result.url);
          }
        } else {
          _isResolvingUrl = false;
          _resolveError = '无法获取播放链接';
          notifyListeners();
        }
      } catch (e) {
        _isResolvingUrl = false;
        _resolveError = e.toString();
        notifyListeners();
      }

      _prefetchNextSongs(startIndex);
    } else if (_audioService != null) {
      final playbackUrl = _currentSong!.isOnline
          ? _currentSong!.url
          : _currentSong!.localPath;
      if (playbackUrl != null && playbackUrl.isNotEmpty) {
        await _setUrlAndPlay(playbackUrl);
      }
    }
  }

  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;

    if (!KugouApiClient().isLoggedIn) {
      onLoginRequired?.call();
      return;
    }

    _playlist = List.from(songs);
    _originalPlaylist = List.from(songs);
    _currentIndex = startIndex;
    _currentSong = songs[startIndex];
    _isResolvingUrl = true;
    _resolveError = null;
    _recordHistory(songs[startIndex]);
    _updateNotification();
    notifyListeners();
    _savePlaybackState();

    try {
      final apiClient = KugouApiClient();
            final result = await apiClient.getSongUrl(
        _currentSong!.id,
        quality: _audioQuality.value,
        albumId: _currentSong!.albumId,
        albumAudioId: _currentSong!.albumAudioId,
      );

      if (result != null && result.url.isNotEmpty) {
        final resolvedSong = _currentSong!.copyWith(url: result.url);
        _currentSong = resolvedSong;
        _playlist[startIndex] = resolvedSong;
        _isResolvingUrl = false;
        notifyListeners();
        _savePlaybackState();

        if (_audioService != null) {
          await _setUrlAndPlay(result.url);
        }
      } else {
        _isResolvingUrl = false;
        _resolveError = '无法获取播放链接';
        notifyListeners();
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }

    _prefetchNextSongs(startIndex);
  }

  void _prefetchNextSongs(int startIndex) {
    final prefetchCount = 3;
    for (
      int i = startIndex + 1;
      i < _playlist.length && i <= startIndex + prefetchCount;
      i++
    ) {
      final song = _playlist[i];
      if (song.isOnline && song.url == null) {
        KugouApiClient()
            .getSongUrl(
              song.id,
              quality: _audioQuality.value,
              albumId: song.albumId,
              albumAudioId: song.albumAudioId,
            )
            .then((result) {
              if (result != null && result.url.isNotEmpty) {
                _playlist[i] = song.copyWith(url: result.url);
              }
            });
      }
    }
  }

  /// 设置音频源并等待就绪后播放。
  ///
  /// 不直接使用 [playerStateStream.firstWhere] 等待 ready 状态,因为
  /// `setUrl` 期间可能已经发出过 ready 事件,而 broadcast stream 的
  /// `firstWhere` 只能捕获订阅之后的事件,会一直等不到下一次 ready,
  /// 直到超时才走到 play(),表现为"暂停"。
  /// 这里采用轮询同步状态 [AudioPlayer.playerState] 的方式,避免漏掉。
  Future<void> _setUrlAndPlay(
    String url, {
    Duration? seekTo,
    bool playAfter = true,
  }) async {
    if (_audioService == null) return;
    // 任何路径加载新音频源后，待恢复进度都失去意义：
    // 防止"恢复状态后用户点其他歌曲 → 后续 resume() 错误 seek 到旧进度"
    _pendingResumePosition = null;
    await _audioService.setUrl(url);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final state = _audioService.player.playerState;
      if (state.processingState == just_audio.ProcessingState.ready) {
        if (seekTo != null && seekTo > Duration.zero) {
          await _audioService.seek(seekTo);
        }
        if (playAfter) {
          await _audioService.play();
        }
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // 超时仍尝试 seek/play,避免完全卡住
    if (seekTo != null && seekTo > Duration.zero) {
      await _audioService.seek(seekTo);
    }
    if (playAfter) {
      await _audioService.play();
    }
  }

  Future<void> pause() async {
    await _audioService?.pause();
    _savePlaybackState();
  }

  Future<void> resume() async {
    // 上次会话恢复后首次按播放：懒加载音频源 + seek 到上次进度
    if (_pendingResumePosition != null && _currentSong != null) {
      final pending = _pendingResumePosition!;
      _pendingResumePosition = null;
      // 走完整解析流程（处理在线 URL 失效），seek 到上次进度
      await _resolveAndPlayCurrentSong(seekTo: pending);
      return;
    }
    await _audioService?.play();
  }

  Future<void> seek(Duration position) async {
    // 立即更新位置，让 UI（进度条、歌词行高亮、滚动）即时响应
    // 否则要等 just_audio positionStream 触发，会有一帧的滞后，
    // 导致拖动 slider 后歌词不跟随。
    if (_position != position) {
      _position = position;
      notifyListeners();
    }
    await _audioService?.seek(position);
    // 同步进度到 Lyricon（仅 enabled 时推送，避免无意义 IPC；
    // seek 由用户拖动进度条或切歌/上一首/下一首触发，频率自然不高，无需额外节流）
    if (LyriconProviderService.instance.enabled) {
      try {
        LyriconProviderService.instance.seekTo(position.inMilliseconds);
      } catch (_) {}
    }
  }

  Future<bool> _resolveAndPlayCurrentSong({Duration? seekTo, bool playAfter = true}) async {
    if (_currentSong == null) return false;

    if (_currentSong!.isOnline && _currentSong!.url == null) {
      if (!KugouApiClient().isLoggedIn) {
        onLoginRequired?.call();
        return false;
      }
      _isResolvingUrl = true;
      notifyListeners();

      try {
        final result = await KugouApiClient().getSongUrl(
          _currentSong!.id,
          quality: _audioQuality.value,
          albumId: _currentSong!.albumId,
          albumAudioId: _currentSong!.albumAudioId,
        );

        if (result != null && result.url.isNotEmpty) {
          final resolvedSong = _currentSong!.copyWith(url: result.url);
          _currentSong = resolvedSong;
          _playlist[_currentIndex] = resolvedSong;
        } else {
          _isResolvingUrl = false;
          return false;
        }
      } catch (e) {
        _isResolvingUrl = false;
        return false;
      }
    }

    _isResolvingUrl = false;
    notifyListeners();

    if (_audioService != null) {
      final playbackUrl = _currentSong!.isOnline
          ? _currentSong!.url
          : _currentSong!.localPath;
      if (playbackUrl != null && playbackUrl.isNotEmpty) {
        // seekTo 仅在恢复上次会话时非空，由 resume() 或 restoreLastSession() 传入
        await _setUrlAndPlay(playbackUrl, seekTo: seekTo, playAfter: playAfter);
      }
    }
    return true;
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;

    if (_loopMode == AppLoopMode.one) {
      await seek(Duration.zero);
      await _audioService?.play();
      return;
    }

    // 已到末尾且非列表循环,停止播放(不静默跳到下一首)
    if (_currentIndex >= _playlist.length - 1 && _loopMode != AppLoopMode.all) {
      await _audioService?.pause();
      return;
    }

    final nextIndex = (_currentIndex + 1) % _playlist.length;
    _currentIndex = nextIndex;
    _currentSong = _playlist[nextIndex];
    _resolveError = null;
    _updateNotification();

    final ok = await _resolveAndPlayCurrentSong();
    if (!ok) {
      _resolveError = '无法获取播放链接';
    }
    notifyListeners();
    _savePlaybackState();
  }

  Future<void> previous() async {
    if (_playlist.isEmpty) return;

    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    final startIndex = _currentIndex;
    int prevIndex = _currentIndex;
    for (int i = 0; i < _playlist.length; i++) {
      prevIndex = prevIndex > 0 ? prevIndex - 1 : _playlist.length - 1;
      if (prevIndex == startIndex) {
        if (_loopMode == AppLoopMode.all) break;
        await seek(Duration.zero);
        return;
      }

      _currentIndex = prevIndex;
      _currentSong = _playlist[prevIndex];
      _resolveError = null;

      if (await _resolveAndPlayCurrentSong()) {
        _savePlaybackState();
        return;
      }
      _resolveError = '无法获取播放链接';
    }
    notifyListeners();
  }

  Future<void> playSongAt(int index) async {
    if (index < 0 || index >= _playlist.length) return;

    _currentIndex = index;
    _currentSong = _playlist[index];
    _resolveError = null;
    notifyListeners();

    await _resolveAndPlayCurrentSong();
    _savePlaybackState();
  }

  Future<void> clearPlaylist() async {
    await _audioService?.stop();
    _playlist = [];
    _originalPlaylist = [];
    _currentIndex = -1;
    _currentSong = null;
    _isPlaying = false;
    _position = Duration.zero;
    _duration = null;
    _resolveError = null;
    _pendingResumePosition = null;
    _updateNotification();
    notifyListeners();
    _savePlaybackState();  // 会触发 _playbackStateRepo.clear()
  }

  Future<void> appendPlaylist(List<Song> songs) async {
    final newSongs = <Song>[];
    for (final song in songs) {
      if (!_playlist.any((s) => s.id == song.id)) {
        newSongs.add(song);
        _playlist.add(song);
      }
    }
    notifyListeners();

    if (newSongs.isNotEmpty) {
      if (_audioService != null) {
        final sources = newSongs
            .map((song) => _createAudioSource(song))
            .toList();
        await _audioService.addAllAudioSources(sources);
      }
      _prefetchNextSongs(_currentIndex);
    }
  }

  Future<void> toggleLoopMode() async {
    switch (_loopMode) {
      case AppLoopMode.off:
        _loopMode = AppLoopMode.all;
        break;
      case AppLoopMode.all:
        _loopMode = AppLoopMode.one;
        break;
      case AppLoopMode.one:
        _loopMode = AppLoopMode.off;
        break;
    }
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    _shuffleEnabled = !_shuffleEnabled;
    if (_shuffleEnabled) {
      final currentSong = _currentSong;
      final remaining = _playlist
          .where((s) => s.id != currentSong?.id)
          .toList();
      remaining.shuffle();
      // currentSong 可能为 null，使用 collection-if 条件添加
      _playlist = [
        if (currentSong != null) currentSong,
        ...remaining,
      ];
      _currentIndex = 0;
    } else {
      final currentSong = _currentSong;
      _playlist = List.from(_originalPlaylist);
      if (currentSong != null) {
        _currentIndex = _playlist.indexWhere((s) => s.id == currentSong.id);
        if (_currentIndex < 0) _currentIndex = 0;
      }
    }
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _audioService?.player?.setVolume(_volume);
    notifyListeners();
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 4.0);
    await _audioService?.setSpeed(_speed);
    notifyListeners();
  }

  void setAudioQuality(AudioQuality quality) {
    if (_audioQuality == quality) return;
    _audioQuality = quality;
    SettingsRepository().setDefaultQuality(quality.value);
    notifyListeners();
    _applyQualityToCurrent();
  }

  Future<void> _applyQualityToCurrent() async {
    final song = _currentSong;
    if (song == null || !song.isOnline) return;
    if (_audioService == null) return;

    final wasPlaying = _audioService!.playing;
    final savedPosition = _audioService!.position;
    _isResolvingUrl = true;
    _resolveError = null;
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      final result = await apiClient.getSongUrl(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result == null || result.url.isEmpty) {
        _isResolvingUrl = false;
        _resolveError = '无法获取播放链接';
        notifyListeners();
        return;
      }

      final resolvedSong = song.copyWith(url: result.url);
      _currentSong = resolvedSong;
      if (_playlist.isNotEmpty && _currentIndex >= 0) {
        _playlist[_currentIndex] = resolvedSong;
      } else {
        _playlist
          ..clear()
          ..add(resolvedSong);
        _currentIndex = 0;
      }
      _isResolvingUrl = false;
      notifyListeners();

      if (_audioService != null) {
        // 同 playOnlinePlaylist:_playlist 中其他歌曲 url 仍为 null,
        // 用 setUrl 只切当前歌曲,避免 just_audio_web 的 null check 异常
        await _setUrlAndPlay(
          result.url,
          seekTo: savedPosition,
          playAfter: wasPlaying,
        );
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }
  }

  DateTime? _lastNotificationUpdate;

  void _updateNotificationPosition() {
    final now = DateTime.now();
    if (_lastNotificationUpdate != null &&
        now.difference(_lastNotificationUpdate!).inSeconds < 1) {
      return;
    }
    _lastNotificationUpdate = now;
    _updateNotification();
  }

  void _updateNotification() {
    final song = _currentSong;
    if (song == null) return;
    // Check favorite status from FavoritesProvider via global context
    bool isFavorited = false;
    try {
      final ctx = appNavigatorKey.currentContext;
      if (ctx != null) {
        isFavorited = ctx.read<FavoritesProvider>().isFavorite(song.id);
      }
    } catch (_) {}
    MediaNotificationService.updateNotification(
      // 使用 displayName 剥离 .mp3 等扩展名，与 _createAudioSource 行为保持一致
      title: song.displayName,
      artist: song.artist,
      artUrl: song.artworkUri,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration ?? Duration.zero,
      desktopLyricEnabled: DesktopLyricService.instance.enabled,
      isFavorited: isFavorited,
    );
  }

  /// Public method to refresh notification (called when favorite state changes)
  void refreshNotification() {
    _updateNotification();
  }

  void _recordHistory(Song song) {
    HistoryRepository().addHistory(song);
  }

  just_audio.UriAudioSource _createAudioSource(Song song) {
    final playbackUrl = song.isOnline ? song.url : song.localPath;
    if (kIsWeb) {
      return createAudioSourceWeb(
        id: song.id,
        url: playbackUrl ?? '',
        // 使用 displayName 剥离 .mp3 等扩展名，避免系统通知栏/锁屏显示后缀
        title: song.displayName,
        artist: song.artist,
        album: song.album,
        artUri: song.artworkUri != null ? Uri.parse(song.artworkUri!) : null,
      );
    }
    return createAudioSource(
      id: song.id,
      url: playbackUrl ?? '',
      // 使用 displayName 剥离 .mp3 等扩展名，避免系统通知栏/锁屏显示后缀
      title: song.displayName,
      artist: song.artist,
      album: song.album,
      artUri: song.artworkUri != null ? Uri.parse(song.artworkUri!) : null,
    );
  }

  /// 监听自身 notifyListeners：检测 currentSong 变化时推送 Lyricon。
  ///
  /// PlayerProvider 没有专门的切歌回调（playSong / next / previous / playSongAt
  /// 等多处都会切歌），用 addListener 监听自身是最小侵入方式。
  /// 每次 notifyListeners（含 position tick）都会触发本方法，但首行 short-circuit
  /// 仅做一次字符串比较，开销可忽略。
  void _handleLyriconSongChange() {
    if (!LyriconProviderService.instance.enabled) return;
    final song = _currentSong;
    // id 相同（含都为 null）则不处理，避免高频 tick 触发重复推送
    if (song?.id == _lastLyriconSong?.id) return;
    _lastLyriconSong = song;
    _pushLyriconSongChange(song);
  }

  /// 拉取歌词 → 解析 → 推送 Lyricon onSongChanged。
  ///
  /// 参考 [DesktopLyricService._onTick] / [_fetchLyricFor] 的模式：
  /// - 通过 appNavigatorKey.currentContext 拿 KugouProvider
  /// - 调 kugou.getLyric 拉 LRC（Task 15 双请求会同时拉 KRC）
  /// - 用 LyricParserChain.parse 自动识别 KRC/LRC/纯文本
  /// - 推送 LyriconProviderService.instance.onSongChanged
  ///
  /// 竞态处理：每次切歌自增 _lyriconFetchToken，异步结果过期则丢弃，
  /// 避免快速切歌时旧歌词覆盖新歌词。
  Future<void> _pushLyriconSongChange(Song? song) async {
    if (!LyriconProviderService.instance.enabled) return;
    final token = ++_lyriconFetchToken;
    try {
      List<LyricLine> lines = const [];
      if (song != null) {
        final ctx = appNavigatorKey.currentContext;
        if (ctx != null) {
          try {
            final kugou = ctx.read<KugouProvider>();
            // fmt='lrc' 触发 KugouApiClient 内部并发双请求（LRC + KRC），
            // 返回的 KugouLyric 同时携带 decodedContent（LRC）与
            // decodedKrcContent（KRC），由 displayLyric 优先返回 KRC 明文。
            // 不复用 kugou.lyric 缓存：KugouProvider 未暴露 lyricSongId getter，
            // 无法判断缓存是否属于当前歌曲（切歌瞬间缓存可能仍是上一首）。
            // getLyric 内部有 _lyricSongId 竞态保护，与 apple_lyrics_view
            // 的并发请求互不干扰（后调覆盖前调，结果一致）。
            await kugou.getLyric(
              song.id,
              songName: song.title,
              fmt: 'lrc',
            );
            if (token != _lyriconFetchToken) return; // 切歌已变化，丢弃旧结果
            // 复用 LyricParserChain 自动识别 KRC/LRC/纯文本（与
            // DesktopLyricService 同一解析入口，不重复实现解析逻辑）
            final text = kugou.lyric?.displayLyric;
            if (text != null && text.isNotEmpty) {
              lines = LyricParserChain.parse(text);
            }
          } catch (_) {}
        }
      }
      if (token != _lyriconFetchToken) return;
      // 传入当前播放进度和状态，让 Lyricon 能立即触发歌词渲染
      // （Lyricon 推荐调用顺序：setSong → setPosition → setPlaybackState）
      await LyriconProviderService.instance.onSongChanged(
        song,
        lines,
        positionMs: _position.inMilliseconds,
        isPlaying: _isPlaying,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    // 应用被销毁前保存一次播放状态（fire-and-forget，不阻塞 dispose）
    _savePlaybackState();
    removeListener(_handleLyriconSongChange);
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _sequenceStateSubscription?.cancel();
    _speedSubscription?.cancel();
    super.dispose();
  }
}

class AudioServiceLoader {
  static Future<dynamic> load() async {
    return AudioService();
  }
}

just_audio.UriAudioSource createAudioSourceWeb({
  required String id,
  required String url,
  required String title,
  String? artist,
  String? album,
  Uri? artUri,
}) {
  return createAudioSource(
    id: id,
    url: url,
    title: title,
    artist: artist,
    album: album,
    artUri: artUri,
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import '../core/services/audio_service.dart';
import '../core/services/media_notification_service.dart';
import '../data/models/song.dart';
import '../data/repositories/history_repository.dart';
import '../data/repositories/settings_repository.dart';
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
  Duration? get duration => _duration;
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

  PlayerProvider() {
    _initAudioService();
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
    } catch (e) {
      debugPrint('Failed to initialize audio service: $e');
    }
  }

  Future<void> _loadDefaultQuality() async {
    try {
      final settings = SettingsRepository();
      final qualityValue = await settings.getDefaultQuality();
      debugPrint('Loading default quality from settings: "$qualityValue"');
      _audioQuality = AudioQuality.values.firstWhere(
        (q) => q.value == qualityValue,
        orElse: () {
          debugPrint('Quality "$qualityValue" not found, defaulting to standard');
          return AudioQuality.standard;
        },
      );
      debugPrint('Audio quality set to: ${_audioQuality.value} (${_audioQuality.label})');
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load default quality: $e');
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
        },
        onError: (e) {
          debugPrint('positionStream error: $e');
        },
      );

      _durationSubscription = _audioService.durationStream.listen(
        (duration) {
          _duration = duration;
          notifyListeners();
        },
        onError: (e) {
          debugPrint('durationStream error: $e');
        },
      );

      _playingSubscription = _audioService.playingStream.listen(
        (isPlaying) {
          _isPlaying = isPlaying;
          _updateNotification();
          notifyListeners();
        },
        onError: (e) {
          debugPrint('playingStream error: $e');
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
            debugPrint('playerState handler error: $e');
          }
        },
        onError: (e) {
          debugPrint('playerStateStream error: $e');
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
            debugPrint('sequenceState handler error: $e');
          }
        },
        onError: (e) {
          debugPrint('sequenceStateStream error: $e');
        },
      );

      _speedSubscription = _audioService.speedStream.listen(
        (speed) {
          _speed = speed;
          notifyListeners();
        },
        onError: (e) {
          debugPrint('speedStream error: $e');
        },
      );
    } catch (e) {
      debugPrint('PlayerProvider _initStreams error: $e');
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
        } else if (_loopMode == AppLoopMode.all) {
          if (_shuffleEnabled) {
            final currentSong = _currentSong;
            final remaining = _playlist.where((s) => s.id != currentSong?.id).toList();
            remaining.shuffle();
            _playlist = [?currentSong, ...remaining];
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
    _recordHistory(song);
    _updateNotification();
    notifyListeners();

    if (_audioService != null) {
      final source = _createAudioSource(song);
      await _audioService.setPlaylist([source], startIndex: 0);
      await _audioService.play();
    }
  }

  Future<void> playOnlineSong(Song song) async {
    debugPrint('playOnlineSong: START - ${song.title} by ${song.artist}');
    final apiClient = KugouApiClient();
    if (!apiClient.isLoggedIn) {
      onLoginRequired?.call();
      return;
    }
    _currentSong = song;
    _playlist = [song];
    _originalPlaylist = [song];
    _currentIndex = 0;
    _isResolvingUrl = true;
    _resolveError = null;
    _recordHistory(song);
    _updateNotification();
    debugPrint('playOnlineSong: notifyListeners() - set initial state');
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      debugPrint(
        'playOnlineSong: song=${song.title}, isLoggedIn=${apiClient.isLoggedIn}, token=${apiClient.token?.substring(0, 10) ?? 'null'}, userid=${apiClient.userid}',
      );

      final result = await apiClient.getSongUrl(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result != null && result.url.isNotEmpty) {
        debugPrint(
          'playOnlineSong: got URL: ${result.url.substring(0, 50)}...',
        );
        final resolvedSong = song.copyWith(url: result.url);
        _currentSong = resolvedSong;
        _playlist = [resolvedSong];
        _isResolvingUrl = false;
        debugPrint(
          'playOnlineSong: notifyListeners() - update with resolved song',
        );
        notifyListeners();

        if (_audioService != null) {
          debugPrint('playOnlineSong: setting playlist and playing');
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
          debugPrint('playOnlineSong: audio playback started');
        } else {
          debugPrint('playOnlineSong: audioService is null');
        }
      } else {
        debugPrint('playOnlineSong: no URL received');
        _isResolvingUrl = false;
        _resolveError = '无法获取播放链接';
        notifyListeners();
      }
    } catch (e) {
      debugPrint('playOnlineSong error: $e');
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

    try {
      final apiClient = KugouApiClient();
      debugPrint('playOnlinePlaylist: requesting URL for "${_currentSong!.title}" with quality=${_audioQuality.value}');
      final result = await apiClient.getSongUrl(
        _currentSong!.id,
        quality: _audioQuality.value,
        albumId: _currentSong!.albumId,
        albumAudioId: _currentSong!.albumAudioId,
      );
      debugPrint('playOnlinePlaylist: URL result: ${result?.url.substring(0, 50)}...');

      if (result != null && result.url.isNotEmpty) {
        final resolvedSong = _currentSong!.copyWith(url: result.url);
        _currentSong = resolvedSong;
        _playlist[startIndex] = resolvedSong;
        _isResolvingUrl = false;
        notifyListeners();

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
  }

  Future<void> resume() async {
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
  }

  Future<bool> _resolveAndPlayCurrentSong() async {
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
        await _setUrlAndPlay(playbackUrl);
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

      if (await _resolveAndPlayCurrentSong()) return;
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
        final sources = newSongs.map((song) => _createAudioSource(song)).toList();
        await _audioService.addAllAudioSources(sources);
      }
      _prefetchNextSongs(_currentIndex);
    }
  }

  Future<void> toggleLoopMode() async {
    switch (_loopMode) {
      case AppLoopMode.off:
        _loopMode = AppLoopMode.one;
        await _audioService?.setLoopMode(just_audio.LoopMode.one);
        break;
      case AppLoopMode.one:
        _loopMode = AppLoopMode.all;
        await _audioService?.setLoopMode(just_audio.LoopMode.all);
        break;
      case AppLoopMode.all:
        _loopMode = AppLoopMode.off;
        await _audioService?.setLoopMode(just_audio.LoopMode.off);
        break;
    }
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    _shuffleEnabled = !_shuffleEnabled;
    if (_shuffleEnabled) {
      final currentSong = _currentSong;
      final remaining = _playlist.where((s) => s.id != currentSong?.id).toList();
      remaining.shuffle();
      _playlist = [?currentSong, ...remaining];
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
    MediaNotificationService.updateNotification(
      title: song.title,
      artist: song.artist,
      artUrl: song.artworkUri,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration ?? Duration.zero,
    );
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
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.artworkUri != null ? Uri.parse(song.artworkUri!) : null,
      );
    }
    return createAudioSource(
      id: song.id,
      url: playbackUrl ?? '',
      title: song.title,
      artist: song.artist,
      album: song.album,
      artUri: song.artworkUri != null ? Uri.parse(song.artworkUri!) : null,
    );
  }

  @override
  void dispose() {
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

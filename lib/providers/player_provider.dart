import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import '../core/services/audio_service.dart';
import '../data/models/song.dart';
import '../services/kugou_api/kugou_api_client.dart';

enum AppLoopMode {
  off,
  one,
  all,
}

class PlayerProvider extends ChangeNotifier {
  Song? _currentSong;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  List<Song> _playlist = [];
  int _currentIndex = -1;
  AppLoopMode _loopMode = AppLoopMode.off;
  bool _shuffleEnabled = false;
  double _volume = 1.0;
  double _speed = 1.0;
  bool _isResolvingUrl = false;
  String? _resolveError;

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

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<just_audio.PlayerState>? _playerStateSubscription;
  StreamSubscription<just_audio.SequenceState?>? _sequenceStateSubscription;
  StreamSubscription<double>? _speedSubscription;

  dynamic _audioService;
  bool _audioInitialized = false;

  PlayerProvider() {
    _initAudioService();
  }

  Future<void> _initAudioService() async {
    try {
      final audioServiceModule = await _loadAudioService();
      _audioService = audioServiceModule;
      _audioInitialized = true;
      _initStreams();
    } catch (e) {
      debugPrint('Failed to initialize audio service: $e');
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
          notifyListeners();
        },
        onError: (e) {
          debugPrint('playingStream error: $e');
        },
      );

      _playerStateSubscription = _audioService.playerStateStream.listen(
        (playerState) {
          try {
            if (playerState.processingState == just_audio.ProcessingState.completed) {
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
              final tag = sequenceState.currentSource!.tag;
              if (tag != null) {
                final effectiveIndex = sequenceState.effectiveSequence.indexOf(sequenceState.currentSource!);
                if (effectiveIndex >= 0 && effectiveIndex < _playlist.length) {
                  _currentIndex = effectiveIndex;
                  _currentSong = _playlist[effectiveIndex];
                  notifyListeners();
                }
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

  void _handlePlaybackCompleted() {
    if (_loopMode == AppLoopMode.one) {
      seek(Duration.zero);
      _audioService?.play();
    } else if (_loopMode == AppLoopMode.all && _currentIndex >= _playlist.length - 1) {
      _currentIndex = 0;
      if (_playlist.isNotEmpty) {
        _currentSong = _playlist[0];
      }
      seek(Duration.zero);
      _audioService?.play();
      notifyListeners();
    }
  }

  Future<void> playSong(Song song) async {
    if (song.isOnline && song.url == null) {
      await playOnlineSong(song);
      return;
    }

    _currentSong = song;
    _playlist = [song];
    _currentIndex = 0;
    _resolveError = null;
    notifyListeners();

    if (_audioService != null) {
      final source = _createAudioSource(song);
      await _audioService.setPlaylist([source], startIndex: 0);
      await _audioService.play();
    }
  }

  Future<void> playOnlineSong(Song song) async {
    _currentSong = song;
    _playlist = [song];
    _currentIndex = 0;
    _isResolvingUrl = true;
    _resolveError = null;
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      final result = await apiClient.getSongUrl(
        song.id,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result != null && result.url.isNotEmpty) {
        final resolvedSong = song.copyWith(url: result.url);
        _currentSong = resolvedSong;
        _playlist = [resolvedSong];
        _isResolvingUrl = false;
        notifyListeners();

        if (_audioService != null) {
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
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
    _currentIndex = startIndex;
    _currentSong = songs[startIndex];
    _resolveError = null;
    notifyListeners();

    if (_currentSong!.isOnline && _currentSong!.url == null) {
      _isResolvingUrl = true;
      notifyListeners();

      try {
        final apiClient = KugouApiClient();
        final result = await apiClient.getSongUrl(
          _currentSong!.id,
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
            final source = _createAudioSource(resolvedSong);
            await _audioService.setPlaylist([source], startIndex: 0);
            await _audioService.play();
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
      final sources = songs.map((song) => _createAudioSource(song)).toList();
      await _audioService.setPlaylist(sources, startIndex: startIndex);
      await _audioService.play();
    }
  }

  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;

    _playlist = List.from(songs);
    _currentIndex = startIndex;
    _currentSong = songs[startIndex];
    _isResolvingUrl = true;
    _resolveError = null;
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      final result = await apiClient.getSongUrl(
        _currentSong!.id,
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
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
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
    for (int i = startIndex + 1; i < _playlist.length && i <= startIndex + prefetchCount; i++) {
      final song = _playlist[i];
      if (song.isOnline && song.url == null) {
        KugouApiClient().getSongUrl(
          song.id,
          albumId: song.albumId,
          albumAudioId: song.albumAudioId,
        ).then((result) {
          if (result != null && result.url.isNotEmpty) {
            _playlist[i] = song.copyWith(url: result.url);
          }
        });
      }
    }
  }

  Future<void> pause() async {
    await _audioService?.pause();
  }

  Future<void> resume() async {
    await _audioService?.play();
  }

  Future<void> seek(Duration position) async {
    await _audioService?.seek(position);
  }

  Future<bool> _resolveAndPlayCurrentSong() async {
    if (_currentSong == null) return false;

    if (_currentSong!.isOnline && _currentSong!.url == null) {
      _isResolvingUrl = true;
      notifyListeners();

      try {
        final result = await KugouApiClient().getSongUrl(
          _currentSong!.id,
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
      final source = _createAudioSource(_currentSong!);
      await _audioService.setPlaylist([source], startIndex: 0);
      await _audioService.play();
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

    final startIndex = _currentIndex;
    int nextIndex = _currentIndex;
    for (int i = 0; i < _playlist.length; i++) {
      nextIndex = (nextIndex + 1) % _playlist.length;
      if (nextIndex == startIndex) {
        if (_loopMode == AppLoopMode.all) break;
        return;
      }

      if (!_playlist[nextIndex].isOnline || _playlist[nextIndex].url != null || _loopMode == AppLoopMode.all) {
        _currentIndex = nextIndex;
        _currentSong = _playlist[nextIndex];
        _resolveError = null;

        if (await _resolveAndPlayCurrentSong()) return;
        _resolveError = '无法获取播放链接';
      }
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

      if (!_playlist[prevIndex].isOnline || _playlist[prevIndex].url != null || _loopMode == AppLoopMode.all) {
        _currentIndex = prevIndex;
        _currentSong = _playlist[prevIndex];
        _resolveError = null;

        if (await _resolveAndPlayCurrentSong()) return;
        _resolveError = '无法获取播放链接';
      }
    }
    notifyListeners();
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
    await _audioService?.setShuffleModeEnabled(_shuffleEnabled);
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

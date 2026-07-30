import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';

import '../core/services/audio_service.dart';
import '../core/services/desktop_lyric_service.dart';
import '../core/services/home_widget_service.dart';
import '../core/services/lyricon_provider_service.dart';
import '../core/services/media_notification_service.dart';
import '../core/services/media_store_service.dart';
import '../data/models/song.dart';
import '../core/utils/audio_scanner.dart';
import '../data/repositories/history_repository.dart';
import '../data/repositories/player_state_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../main.dart';
import '../services/stream_cache_manager.dart';
import '../widgets/apple_lyrics/models/lyric_line.dart';
import '../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'favorites_provider.dart';
import 'kugou_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';

enum AppLoopMode { off, one, all }

enum AudioQuality {
  standard('128', '标准音质'),
  high('320', '高音质'),
  flac('flac', '无损音质'),
  hires('high', 'Hi-Res 无损');

  const AudioQuality(this.value, this.label);
  final String value;
  final String label;
}

class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
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
  // 边听边存：当前歌曲的本地缓存封面路径（缓存命中时设置，供 MediaSession 兜底）
  String? _cachedArtworkPath;
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

  /// 当前歌曲的实际音质标签。
  /// 本地歌曲优先使用 song.quality 推断的标签，在线歌曲使用全局音质偏好。
  String get currentQualityLabel {
    final song = _currentSong;
    if (song != null && !song.isOnline && song.quality != null) {
      switch (song.quality) {
        case '128':
          return '标准音质';
        case '320':
          return '高音质';
        case 'flac':
          return '无损音质';
        case 'high':
          return 'Hi-Res 无损';
        default:
          return song.quality!;
      }
    }
    return _audioQuality.label;
  }

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

  // —— 播放状态持久化 ——
  final _stateRepo = PlayerStateRepository();
  bool _stateRestored = false;
  // 保存防抖计时器：避免 positionStream 每 200ms 都写磁盘
  Timer? _saveDebounce;

  PlayerProvider() {
    WidgetsBinding.instance.addObserver(this);
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
      // 恢复上次播放状态
      await _restoreState();
    } catch (e) {}
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
    } catch (e) {}
  }

  Future<dynamic> _loadAudioService() async {
    return AudioServiceLoader.load();
  }

  /// 冷启动恢复上次播放状态：加载歌曲、播放列表、恢复位置。
  Future<void> _restoreState() async {
    if (_stateRestored) return;
    _stateRestored = true;
    try {
      final state = await _stateRepo.restoreState();
      if (state == null) return;

      _currentSong = state.currentSong;
      _playlist = List.from(state.playlist);
      _originalPlaylist = List.from(state.playlist);
      _currentIndex = state.currentIndex;
      _loopMode = AppLoopMode.values.firstWhere(
        (m) => m.name == state.loopMode,
        orElse: () => AppLoopMode.off,
      );
      _shuffleEnabled = state.shuffleEnabled;
      _position = Duration.zero; // 先置零，等 setUrl 成功后 seek 到目标位置

      // 设置循环模式
      if (_audioService != null) {
        await _audioService.setLoopMode(_loopMode == AppLoopMode.one
            ? just_audio.LoopMode.one
            : _loopMode == AppLoopMode.all
                ? just_audio.LoopMode.all
                : just_audio.LoopMode.off);
        await _audioService.setShuffleModeEnabled(_shuffleEnabled);
      }

      // 构建播放源并 seek 到保存的位置（不自动播放，等用户手动触发）
      final ok = await _resolveAndPlayCurrentSong(seekTo: state.position, play: false);
      if (ok) {
        _position = state.position;
      }
      notifyListeners();
    } catch (e) {}
  }

  /// 防抖保存播放状态：positionStream 每 200ms 触发一次，
  /// 用 3 秒防抖避免频繁写磁盘，仅保存关键字段。
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), _saveState);
  }

  /// 立即保存播放状态（切歌、暂停、循环模式变更时调用）。
  void _saveState() {
    _saveDebounce?.cancel();
    try {
      _stateRepo.saveState(
        currentSong: _currentSong,
        playlist: _playlist,
        currentIndex: _currentIndex,
        position: _position,
        loopMode: _loopMode.name,
        shuffleEnabled: _shuffleEnabled,
      );
    } catch (_) {}
  }

  void _initStreams() {
    if (_audioService == null || !_audioInitialized) return;

    try {
      _positionSubscription = _audioService.positionStream.listen((position) {
        _position = position;
        _updateNotificationPosition();
        notifyListeners();
        // 防抖保存位置（3 秒）
        _scheduleSave();
        // 直接转发给 Lyricon，无节流。
        // positionStream 本身就是 ~200ms 周期（just_audio 默认），是天然节流。
        // MethodChannel 是异步的，不阻塞 Dart UI；setPosition 是 fire-and-forget。
        // 仅在播放中推送，暂停时跳过避免无意义 IPC。
        if (LyriconProviderService.instance.enabled && _isPlaying) {
          try {
            LyriconProviderService.instance.setPosition(
              position.inMilliseconds,
            );
          } catch (_) {}
        }
      }, onError: (e) {});

      _durationSubscription = _audioService.durationStream.listen((duration) {
        _duration = duration;
        notifyListeners();
      }, onError: (e) {});

      _playingSubscription = _audioService.playingStream.listen((isPlaying) {
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
      }, onError: (e) {});

      _playerStateSubscription = _audioService.playerStateStream.listen((
        playerState,
      ) {
        try {
          if (playerState.processingState ==
              just_audio.ProcessingState.completed) {
            _handlePlaybackCompleted();
          }
        } catch (e) {}
      }, onError: (e) {});

      _sequenceStateSubscription = _audioService.sequenceStateStream.listen((
        sequenceState,
      ) {
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
        } catch (e) {}
      }, onError: (e) {});

      _speedSubscription = _audioService.speedStream.listen((speed) {
        _speed = speed;
        notifyListeners();
      }, onError: (e) {});
    } catch (e) {}
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
        // 走到这里：当前是最后一首（含单首歌场景），且非 FM、非列表循环
        if (onPlaylistEnd != null) {
          await onPlaylistEnd!();
        } else {
          // 记录当前位置与歌曲实际时长，用于判断是否异常结束
          // （URL 过期 / 试听片段提前 completed 时，position 明显小于歌曲时长）
          final lastPosition = _position;
          final songDuration = _currentSong?.duration ?? Duration.zero;
          final bool isAbnormalEnd = lastPosition.inSeconds > 5 &&
              songDuration.inSeconds > 0 &&
              lastPosition.inSeconds < songDuration.inSeconds * 0.8;

          // 非 FM：最后一曲播完回到第一曲
          if (_shuffleEnabled) {
            final currentSong = _currentSong;
            final remaining = _playlist
                .where((s) => s.id != currentSong?.id)
                .toList();
            remaining.shuffle();
            // currentSong 可能为 null，使用 collection-if 条件添加
            _playlist = [if (currentSong != null) currentSong, ...remaining];
            _currentIndex = 0;
          } else {
            _currentIndex = 0;
          }
          if (_playlist.isNotEmpty) {
            _currentSong = _playlist[_currentIndex];
          }
          // 异常结束时清除旧 URL，强制重新解析（避免复用过期链接）
          if (isAbnormalEnd && _currentSong != null && _currentSong!.isOnline) {
            _currentSong = _currentSong!.copyWith(url: null);
            _playlist[_currentIndex] = _currentSong!;
          }
          // 异常结束时从上次位置继续播放；正常播完从 0 开始
          final seekTo = isAbnormalEnd ? lastPosition : null;
          final ok = await _resolveAndPlayCurrentSong(seekTo: seekTo);
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
    _position = Duration.zero;
    _recordHistory(song);
    _updateNotification();
    _saveState();
    notifyListeners();

    if (_audioService != null) {
      final playbackUrl = await _resolvePlaybackUrl(song);
      if (playbackUrl == null || playbackUrl.isEmpty) {
        _resolveError = '无法获取播放链接';
        notifyListeners();
        return;
      }
      // 把解析后的真实路径回写到 song，避免下次切回时重新解析
      if (!song.isOnline) {
        _currentSong = song.copyWith(localPath: playbackUrl);
        _playlist[0] = _currentSong!;
        notifyListeners();
      }
      final source = _createAudioSource(_currentSong!);
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

    // 边听边存：检查本地缓存（登录检查通过后才查缓存，避免未登录时静默播放）
    final cacheEnabled = await SettingsRepository().getStreamCacheEnabled();
    String? cachedPath;
    if (cacheEnabled) {
      await StreamCacheManager.instance.ensureInitialized();
      cachedPath = await StreamCacheManager.instance.getCachedAudioPath(
        song.id,
        _audioQuality.value,
      );
    }

    _currentSong = song;
    _playlist = [song];
    _originalPlaylist = [song];
    _currentIndex = 0;
    _isResolvingUrl = true;
    _resolveError = null;
    _position = Duration.zero;
    _recordHistory(song);
    _updateNotification();
    _saveState();
    notifyListeners();

    try {
      // 缓存命中：直接用本地路径播放
      if (cachedPath != null) {
        final fileUri = Uri.file(cachedPath).toString();
        final resolvedSong = song.copyWith(url: fileUri);
        _currentSong = resolvedSong;
        _playlist = [resolvedSong];
        _isResolvingUrl = false;
        // 查询本地缓存封面路径，供 MediaSession 断网兜底
        _cachedArtworkPath =
            await StreamCacheManager.instance.getCachedArtworkPath(song.id);
        _saveState();
        notifyListeners();

        if (_audioService != null) {
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
        }
        return;
      }
      _cachedArtworkPath = null;

      final apiClient = KugouApiClient();

      final result = await apiClient.getSongUrlWithFallback(
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
        _saveState();
        notifyListeners();

        if (_audioService != null) {
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
        } else {}

        // 边听边存：异步缓存音频（不阻塞播放）
        if (cacheEnabled) {
          // fire-and-forget，不 await
          StreamCacheManager.instance.cacheAudio(
            resolvedSong,
            result.quality,
            result.url,
          );
          // 同时缓存封面（如果 URL 存在）
          if (song.artworkUri != null && song.artworkUri!.isNotEmpty) {
            StreamCacheManager.instance.cacheArtwork(
              song.id,
              song.artworkUri!,
            );
          }
          // 缓存元数据
          StreamCacheManager.instance.cacheSongMetadata(song);
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
    _position = Duration.zero;
    _recordHistory(songs[startIndex]);
    _saveState();
    notifyListeners();

    if (_currentSong!.isOnline && _currentSong!.url == null) {
      _isResolvingUrl = true;
      notifyListeners();

      try {
        final apiClient = KugouApiClient();
        final result = await apiClient.getSongUrlWithFallback(
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
      final playbackUrl = await _resolvePlaybackUrl(_currentSong!);
      if (playbackUrl == null || playbackUrl.isEmpty) {
        _resolveError = '无法获取播放链接';
        notifyListeners();
        return;
      }
      // 把解析后的真实路径回写到 song（适用于本地 content:// URI）
      if (!_currentSong!.isOnline) {
        _currentSong = _currentSong!.copyWith(localPath: playbackUrl);
        _playlist[_currentIndex] = _currentSong!;
        notifyListeners();
      }
      await _setUrlAndPlay(playbackUrl);
    }
  }

  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;

    // 边听边存：先查本地缓存（断网时仍可播放已缓存歌曲）
    final cacheEnabled = await SettingsRepository().getStreamCacheEnabled();
    String? cachedPath;
    if (cacheEnabled) {
      await StreamCacheManager.instance.ensureInitialized();
      cachedPath = await StreamCacheManager.instance.getCachedAudioPath(
        songs[startIndex].id,
        _audioQuality.value,
      );
    }

    // 缓存未命中且未登录时才提示登录
    if (cachedPath == null && !KugouApiClient().isLoggedIn) {
      onLoginRequired?.call();
      return;
    }

    _playlist = List.from(songs);
    _originalPlaylist = List.from(songs);
    _currentIndex = startIndex;
    _currentSong = songs[startIndex];
    _isResolvingUrl = true;
    _resolveError = null;
    _position = Duration.zero;
    _recordHistory(songs[startIndex]);
    _updateNotification();
    notifyListeners();

    try {
      // 缓存命中：直接播放本地文件
      if (cachedPath != null) {
        final fileUri = Uri.file(cachedPath).toString();
        final resolvedSong = _currentSong!.copyWith(url: fileUri);
        _currentSong = resolvedSong;
        _playlist[startIndex] = resolvedSong;
        _isResolvingUrl = false;
        // 查询本地缓存封面路径，供 MediaSession 断网兜底
        _cachedArtworkPath = await StreamCacheManager.instance
            .getCachedArtworkPath(_currentSong!.id);
        notifyListeners();

        if (_audioService != null) {
          await _setUrlAndPlay(fileUri);
        }
      } else {
        _cachedArtworkPath = null;
        final apiClient = KugouApiClient();
        final result = await apiClient.getSongUrlWithFallback(
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

          // 边听边存：异步缓存音频（不阻塞播放）
          if (cacheEnabled) {
            StreamCacheManager.instance.cacheAudio(
              resolvedSong,
              result.quality,
              result.url,
            );
            if (_currentSong!.artworkUri != null &&
                _currentSong!.artworkUri!.isNotEmpty) {
              StreamCacheManager.instance.cacheArtwork(
                _currentSong!.id,
                _currentSong!.artworkUri!,
              );
            }
            StreamCacheManager.instance.cacheSongMetadata(_currentSong!);
          }
        } else {
          _isResolvingUrl = false;
          _resolveError = '无法获取播放链接';
          notifyListeners();
        }
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }

    _prefetchNextSongs(startIndex);
    _fetchClimaxData();
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
            .getSongUrlWithFallback(
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

  /// 播放云盘歌曲列表。
  /// 与 [playOnlinePlaylist] 的区别：URL 解析优先走 /user/cloud/url，
  /// 失败再回退到 /song/url，适配用户上传到云盘的音乐。
  Future<void> playCloudPlaylist(List<Song> songs, int startIndex) async {
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
    _position = Duration.zero;
    _recordHistory(songs[startIndex]);
    _updateNotification();
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      final url = await _resolveCloudUrl(apiClient, songs[startIndex]);
      if (url != null && url.isNotEmpty) {
        final resolvedSong = songs[startIndex].copyWith(url: url);
        _currentSong = resolvedSong;
        _playlist[startIndex] = resolvedSong;
        _isResolvingUrl = false;
        notifyListeners();
        if (_audioService != null) {
          await _setUrlAndPlay(url);
        }
      } else {
        _isResolvingUrl = false;
        _resolveError = '无法获取云盘播放链接';
        notifyListeners();
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }

    _prefetchCloudSongs(startIndex);
    _fetchClimaxData();
  }

  /// 云盘歌曲 URL 解析：先 /user/cloud/url，后 /song/url 兜底
  Future<String?> _resolveCloudUrl(
    KugouApiClient apiClient,
    Song song,
  ) async {
    try {
      final cloudResult = await apiClient.getUserCloudUrl(
        song.id,
        albumId: song.albumId,
        name: song.title,
        albumAudioId: song.albumAudioId,
      );
      if (cloudResult != null) {
        final data = cloudResult['data'];
        if (data is Map<String, dynamic>) {
          final rawUrl = data['url'];
          if (rawUrl is String && rawUrl.isNotEmpty) {
            return rawUrl;
          }
          if (rawUrl is List && rawUrl.isNotEmpty) {
            return rawUrl.first.toString();
          }
        }
      }
    } catch (_) {}

    // 回退到通用 /song/url
    try {
      final result = await apiClient.getSongUrlWithFallback(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );
      if (result != null && result.url.isNotEmpty) {
        return result.url;
      }
    } catch (_) {}
    return null;
  }

  /// 预取云盘列表后续歌曲 URL（对齐 _prefetchNextSongs）
  void _prefetchCloudSongs(int startIndex) {
    final prefetchCount = 3;
    final apiClient = KugouApiClient();
    for (int i = startIndex + 1;
        i < _playlist.length && i <= startIndex + prefetchCount;
        i++) {
      final song = _playlist[i];
      if (song.isOnline && song.url == null) {
        _resolveCloudUrl(apiClient, song).then((url) {
          if (url != null && url.isNotEmpty) {
            _playlist[i] = song.copyWith(url: url);
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
    // 淡出：暂停前平滑降低音量
    final fadeEnabled = await SettingsRepository().getPauseFadeEnabled();
    if (fadeEnabled && _audioService != null) {
      final originalVolume = _volume;
      const fadeDuration = Duration(milliseconds: 250);
      const steps = 10;
      final stepDuration = fadeDuration ~/ steps;
      for (int i = steps - 1; i >= 0; i--) {
        await _audioService?.player?.setVolume(originalVolume * i / steps);
        await Future.delayed(stepDuration);
      }
      await _audioService?.pause();
      // 恢复音量设置（下次播放时使用）
      await _audioService?.player?.setVolume(originalVolume);
    } else {
      await _audioService?.pause();
    }
    _saveState();
  }

  Future<void> resume() async {
    // 淡入：播放后平滑提升音量
    final fadeEnabled = await SettingsRepository().getPauseFadeEnabled();
    if (fadeEnabled && _audioService != null) {
      final targetVolume = _volume;
      await _audioService?.player?.setVolume(0);
      await _audioService?.play();
      const fadeDuration = Duration(milliseconds: 250);
      const steps = 10;
      final stepDuration = fadeDuration ~/ steps;
      for (int i = 1; i <= steps; i++) {
        await _audioService?.player?.setVolume(targetVolume * i / steps);
        await Future.delayed(stepDuration);
      }
    } else {
      await _audioService?.play();
    }
    _saveState();
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
    _saveState();
    // 同步进度到 Lyricon（仅 enabled 时推送，避免无意义 IPC；
    // seek 由用户拖动进度条或切歌/上一首/下一首触发，频率自然不高，无需额外节流）
    if (LyriconProviderService.instance.enabled) {
      try {
        LyriconProviderService.instance.seekTo(position.inMilliseconds);
      } catch (_) {}
    }
  }

  Future<bool> _resolveAndPlayCurrentSong({Duration? seekTo, bool play = true}) async {
    if (_currentSong == null) return false;

    if (_currentSong!.isOnline) {
      // 边听边存：检查本地缓存（无论 URL 是否已预取都先查缓存）
      final song = _currentSong!;
      final cacheEnabled = await SettingsRepository().getStreamCacheEnabled();
      if (cacheEnabled) {
        await StreamCacheManager.instance.ensureInitialized();
        final cachedPath = await StreamCacheManager.instance.getCachedAudioPath(
          song.id,
          _audioQuality.value,
        );
        if (cachedPath != null) {
          // 缓存命中，直接播放本地文件
          // 查询本地缓存封面路径，供 MediaSession 断网兜底
          _cachedArtworkPath = await StreamCacheManager.instance
              .getCachedArtworkPath(song.id);
          await _setUrlAndPlay(
            Uri.file(cachedPath).toString(),
            seekTo: seekTo,
            playAfter: play,
          );
          // 异步获取高潮时间（不阻塞播放）
          _fetchClimaxData();
          return true;
        }
        _cachedArtworkPath = null;
      }

      // 缓存未命中：需要 URL 来播放
      if (song.url == null) {
        // URL 不存在，需要解析
        if (!KugouApiClient().isLoggedIn) {
          onLoginRequired?.call();
          return false;
        }
        _isResolvingUrl = true;
        notifyListeners();

        try {
          final result = await KugouApiClient().getSongUrlWithFallback(
            _currentSong!.id,
            quality: _audioQuality.value,
            albumId: _currentSong!.albumId,
            albumAudioId: _currentSong!.albumAudioId,
          );

          if (result != null && result.url.isNotEmpty) {
            final resolvedSong = _currentSong!.copyWith(url: result.url);
            _currentSong = resolvedSong;
            _playlist[_currentIndex] = resolvedSong;
            // 边听边存：异步缓存音频（不阻塞播放）
            if (cacheEnabled) {
              final songToCache = _currentSong!.copyWith(url: result.url);
              // fire-and-forget，不 await
              StreamCacheManager.instance.cacheAudio(
                songToCache,
                result.quality,
                result.url,
              );
              // 同时缓存封面（如果 URL 存在）
              if (song.artworkUri != null && song.artworkUri!.isNotEmpty) {
                StreamCacheManager.instance.cacheArtwork(
                  song.id,
                  song.artworkUri!,
                );
              }
              // 缓存元数据
              StreamCacheManager.instance.cacheSongMetadata(song);
            }
          } else {
            _isResolvingUrl = false;
            return false;
          }
        } catch (e) {
          _isResolvingUrl = false;
          return false;
        }
      } else {
        // URL 已存在（预取过），边听边存：异步缓存
        if (cacheEnabled) {
          // fire-and-forget，不 await
          StreamCacheManager.instance.cacheAudio(
            song,
            _audioQuality.value,
            song.url!,
          );
          if (song.artworkUri != null && song.artworkUri!.isNotEmpty) {
            StreamCacheManager.instance.cacheArtwork(
              song.id,
              song.artworkUri!,
            );
          }
          StreamCacheManager.instance.cacheSongMetadata(song);
        }
      }
    }

    _isResolvingUrl = false;
    notifyListeners();

    if (_audioService != null) {
      final playbackUrl = await _resolvePlaybackUrl(_currentSong!);
      if (playbackUrl != null && playbackUrl.isNotEmpty) {
        // 把解析后的真实路径回写到 song（适用于本地 content:// URI）
        if (!_currentSong!.isOnline) {
          _currentSong = _currentSong!.copyWith(localPath: playbackUrl);
          _playlist[_currentIndex] = _currentSong!;
          notifyListeners();
        }
        await _setUrlAndPlay(playbackUrl, seekTo: seekTo, playAfter: play);
      } else {
        _resolveError = '无法获取播放链接';
        notifyListeners();
      }
    }

    // 异步获取高潮时间（不阻塞播放）
    _fetchClimaxData();

    return true;
  }

  /// 异步获取当前歌曲的高潮时间数据。
  ///
  /// 调用酷狗 /song/climax 接口，获取高潮起止时间后更新 [_currentSong]。
  /// 不阻塞播放流程，失败时静默忽略。
  Future<void> _fetchClimaxData() async {
    final song = _currentSong;
    if (song == null || !song.isOnline) return;
    if (song.climaxStart != null) return;
    try {
      final climax = await KugouApiClient().getSongClimax(
        song.id,
        albumAudioId: song.albumAudioId,
      );
      if (climax == null) return;
      final startMs = double.tryParse(climax.startTime ?? '');
      final endMs = double.tryParse(climax.endTime ?? '');
      if (startMs == null || endMs == null) return;
      if (_currentSong?.id != song.id) return;
      // API 返回毫秒，转为秒存储
      _currentSong = song.copyWith(
        climaxStart: startMs / 1000.0,
        climaxEnd: endMs / 1000.0,
      );
      final idx = _playlist.indexWhere((s) => s.id == song.id);
      if (idx >= 0) _playlist[idx] = _currentSong!;
      notifyListeners();
    } catch (_) {
      // 静默忽略，高潮数据非必需
    }
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;

    // 取消当前歌曲的缓存下载
    if (_currentSong != null && _currentSong!.isOnline) {
      StreamCacheManager.instance.cancelAudioDownload(_currentSong!.id);
    }

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
    _position = Duration.zero; // 切歌时重置位置，避免恢复时跳到上一首的进度
    _updateNotification();
    _saveState();

    final ok = await _resolveAndPlayCurrentSong();
    if (!ok) {
      _resolveError = '无法获取播放链接';
    }
    notifyListeners();
  }

  Future<void> previous() async {
    if (_playlist.isEmpty) return;

    // 取消当前歌曲的缓存下载
    if (_currentSong != null && _currentSong!.isOnline) {
      StreamCacheManager.instance.cancelAudioDownload(_currentSong!.id);
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
      _position = Duration.zero;

      if (await _resolveAndPlayCurrentSong()) {
        _saveState();
        return;
      }
      _resolveError = '无法获取播放链接';
    }
    _saveState();
    notifyListeners();
  }

  Future<void> playSongAt(int index) async {
    if (index < 0 || index >= _playlist.length) return;

    // 取消当前歌曲的缓存下载
    if (_currentSong != null && _currentSong!.isOnline) {
      StreamCacheManager.instance.cancelAudioDownload(_currentSong!.id);
    }

    _currentIndex = index;
    _currentSong = _playlist[index];
    _resolveError = null;
    _position = Duration.zero;
    _saveState();
    notifyListeners();

    await _resolveAndPlayCurrentSong();
  }

  Future<void> clearPlaylist() async {
    // 取消当前歌曲的缓存下载
    if (_currentSong != null && _currentSong!.isOnline) {
      StreamCacheManager.instance.cancelAudioDownload(_currentSong!.id);
    }

    await _audioService?.stop();
    _playlist = [];
    _originalPlaylist = [];
    _currentIndex = -1;
    _currentSong = null;
    _isPlaying = false;
    _position = Duration.zero;
    _duration = null;
    _resolveError = null;
    _stateRepo.clearState();
    _updateNotification();
    notifyListeners();
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
        // 异步把 content:// 全部解析为真实路径后建 source
        final resolvedSongs = await _resolveLocalPathsForBatch(newSongs);
        final sources = resolvedSongs
            .map((song) => _createAudioSource(song))
            .toList();
        await _audioService.addAllAudioSources(sources);
        // 回写真实路径到 _playlist
        for (final song in resolvedSongs) {
          final idx = _playlist.indexWhere((s) => s.id == song.id);
          if (idx >= 0) _playlist[idx] = song;
        }
        notifyListeners();
      }
      _prefetchNextSongs(_currentIndex);
    }
  }

  /// 在当前播放歌曲之后插入歌曲（"下一首播放"功能）。
  ///
  /// - 不在播放列表中的歌曲：新增并插入到当前歌曲之后，同步 audio_service 队列。
  /// - 已在播放列表中的歌曲：移动到当前歌曲之后（不重复添加），仅调整 Dart 端
  ///   顺序，不重建 audio_service 队列（与 [reorderPlaylist] 策略一致，避免
  ///   打断当前播放；切歌走 _currentIndex/_playlist，不依赖 audio_service 队列）。
  Future<void> insertAfterCurrent(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (_playlist.isEmpty || _currentIndex < 0) {
      // 播放列表为空，直接追加
      await appendPlaylist(songs);
      return;
    }

    final currentId = _playlist[_currentIndex].id;
    final newSongs = <Song>[]; // 不在列表中：需新增
    final moveSongs = <Song>[]; // 已在列表中：需移动
    for (final song in songs) {
      // 当前正在播放的歌曲本身就是"当前"，无需移动
      if (song.id == currentId) continue;
      if (_playlist.any((s) => s.id == song.id)) {
        moveSongs.add(song);
      } else {
        newSongs.add(song);
      }
    }
    if (newSongs.isEmpty && moveSongs.isEmpty) return;

    // 1. 先从 _playlist 移除待移动歌曲（稍后统一插回当前歌曲之后）
    if (moveSongs.isNotEmpty) {
      final moveIds = moveSongs.map((s) => s.id).toSet();
      _playlist.removeWhere((s) => moveIds.contains(s.id));
    }

    // 2. 重新定位当前歌曲索引（前面被移除的歌曲会使当前歌曲前移）
    int curIdx = _playlist.indexWhere((s) => s.id == currentId);
    if (curIdx < 0) curIdx = _playlist.isEmpty ? 0 : _playlist.length - 1;
    final insertIndex = curIdx + 1;

    // 3. 插入：新增歌曲在前，移动歌曲在后，保持调用顺序
    _playlist.insertAll(insertIndex, [...newSongs, ...moveSongs]);

    // 4. 当前歌曲本身未移动，但其前后增删歌曲会改变索引，按 id 重新定位
    _currentIndex = _playlist.indexWhere((s) => s.id == currentId);
    if (_currentIndex < 0) _currentIndex = 0;

    // 5. 同步 _originalPlaylist：把新增+移动的歌曲插到当前歌曲之后
    if (moveSongs.isNotEmpty) {
      final moveIds = moveSongs.map((s) => s.id).toSet();
      _originalPlaylist.removeWhere((s) => moveIds.contains(s.id));
    }
    final origCurIdx = _originalPlaylist.indexWhere((s) => s.id == currentId);
    final origInsert = origCurIdx >= 0
        ? (origCurIdx + 1).clamp(0, _originalPlaylist.length)
        : _originalPlaylist.length;
    _originalPlaylist.insertAll(origInsert, [...newSongs, ...moveSongs]);

    notifyListeners();

    // 6. audio_service 队列同步：仅对新增歌曲插入 source。
    //    移动歌曲不重建队列（Dart 端顺序已正确，切歌走 _currentIndex）。
    if (_audioService != null && _currentSong != null && newSongs.isNotEmpty) {
      final resolvedSongs = await _resolveLocalPathsForBatch(newSongs);
      // 回写真实路径到 _playlist（newSongs 占据 insertIndex 起的位置）
      for (int i = 0; i < resolvedSongs.length; i++) {
        final idx = insertIndex + i;
        if (idx < _playlist.length) {
          _playlist[idx] = resolvedSongs[i];
        }
      }
      // 逐个插入到 audio_service 队列，不打断当前播放
      for (int i = 0; i < resolvedSongs.length; i++) {
        final source = _createAudioSource(resolvedSongs[i]);
        await _audioService.insertAudioSourceAt(insertIndex + i, source);
      }
      notifyListeners();
    }
    _prefetchNextSongs(_currentIndex);
  }

  /// 从播放列表中删除指定索引的歌曲。
  ///
  /// 同步更新 _playlist / _originalPlaylist / _currentIndex。
  /// 底层 audio_service 队列的处理策略：
  /// - 删除非当前歌曲：**不重建** audio_service 队列，避免打断当前播放。
  ///   音频结束事件由 _handlePlaybackCompleted 监听，所有跳转/切歌都使用
  ///   Dart 端 _playlist + _resolveAndPlayCurrentSong，不依赖 audio_service
  ///   内部队列，因此陈旧的内部队列不会造成问题。
  /// - 删除当前歌曲：必须重建 audio_service 队列并加载新当前歌曲。
  /// - 列表清空：停止 audio_service。
  /// 边界处理：
  /// - 列表为空：清空所有播放状态
  /// - 删除的是当前播放歌曲：自动切到同索引位置的新歌
  /// - 删除的在当前歌曲之前：_currentIndex 前移
  /// - 删除的在当前歌曲之后：索引不变
  Future<void> removeFromPlaylist(int index) async {
    if (index < 0 || index >= _playlist.length) return;

    final removedSong = _playlist[index];
    final wasCurrent = index == _currentIndex;

    // 1. 维护 Dart 端列表
    _playlist.removeAt(index);

    // 同步 _originalPlaylist（shuffle 关闭时用于还原原始顺序）
    final origIndex = _originalPlaylist.indexWhere(
      (s) => s.id == removedSong.id,
    );
    if (origIndex != -1) _originalPlaylist.removeAt(origIndex);

    // 2. 维护当前播放索引
    if (_playlist.isEmpty) {
      _currentIndex = -1;
      _currentSong = null;
      _isPlaying = false;
      _position = Duration.zero;
      _duration = null;
      _resolveError = null;
    } else if (wasCurrent) {
      // 删除的就是当前播放歌曲：跳到（原 index 处的）新歌
      // index 可能在删除后越界，需要 clamp
      _currentIndex = index.clamp(0, _playlist.length - 1);
      _currentSong = _playlist[_currentIndex];
      _resolveError = null;
    } else if (index < _currentIndex) {
      // 删除的在当前歌曲之前：索引前移
      _currentIndex--;
    }

    // 3. 同步底层 audio_service 队列
    if (_audioService == null) {
      // 无 audio_service（初始化未完成），仅更新 Dart 端状态
    } else if (_playlist.isEmpty) {
      // 列表清空：停止播放
      await _audioService!.stop();
      _updateNotification();
    } else if (wasCurrent) {
      // 删除的是当前播放歌曲：先解析新当前歌曲的 URL，再重建队列播放
      if (_currentSong != null && _currentSong!.isOnline && _currentSong!.url == null) {
        try {
          final result = await KugouApiClient().getSongUrlWithFallback(
            _currentSong!.id,
            quality: _audioQuality.value,
            albumId: _currentSong!.albumId,
            albumAudioId: _currentSong!.albumAudioId,
          );
          if (result != null && result.url.isNotEmpty) {
            final resolvedSong = _currentSong!.copyWith(url: result.url);
            _currentSong = resolvedSong;
            _playlist[_currentIndex] = resolvedSong;
          }
        } catch (_) {}
      }
      // 重建前先批量解析本地 content://，避免 just_audio 加载失败
      final resolvedPlaylist = await _resolveLocalPathsForBatch(_playlist);
      for (int i = 0; i < resolvedPlaylist.length && i < _playlist.length; i++) {
        _playlist[i] = resolvedPlaylist[i];
      }
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        _currentSong = _playlist[_currentIndex];
      }
      final sources = _playlist.map(_createAudioSource).toList();
      await _audioService!.setPlaylist(
        sources,
        startIndex: _currentIndex >= 0 ? _currentIndex : 0,
      );
      await _audioService!.seek(Duration.zero);
      await _audioService!.play();
    }
    // else: 删除非当前歌曲，不动 audio_service，避免打断当前播放
    _updateNotification();

    notifyListeners();
  }

  /// 重排播放列表中的歌曲顺序。
  ///
  /// 参数遵循 Flutter ReorderableListView 的约定：当 oldIndex < newIndex
  /// 时，newIndex 需要 -1 才是实际插入位置。
  ///
  /// 只更新 Dart 端 _playlist / _originalPlaylist / _currentIndex，
  /// **不重建** audio_service 队列。
  /// 原理：项目所有切歌逻辑（_handlePlaybackCompleted → next() →
  /// _resolveAndPlayCurrentSong）都使用 Dart 端 _currentIndex 和 _currentSong
  /// 加载 URL，不依赖 audio_service 内部队列。audio_service 当前正在播放的
  /// source 不会因为 _playlist 顺序变化而失效，重建反而会打断当前播放。
  Future<void> reorderPlaylist(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _playlist.length) return;

    // ReorderableListView 的 newIndex 在 oldIndex 之前时需 -1 的标准处理
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    if (newIndex < 0 || newIndex >= _playlist.length) return;

    // 1. 维护 Dart 端列表
    final song = _playlist.removeAt(oldIndex);
    _playlist.insert(newIndex, song);

    // 同步 _originalPlaylist：按相同偏移量调整
    final origOld = _originalPlaylist.indexWhere((s) => s.id == song.id);
    if (origOld != -1) {
      _originalPlaylist.removeAt(origOld);
      final origNew = origOld.clamp(0, _originalPlaylist.length);
      _originalPlaylist.insert(origNew, song);
    }

    // 2. 维护当前播放索引
    if (oldIndex == _currentIndex) {
      // 拖动的是当前播放歌曲：索引跟随到新位置
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      // 当前歌曲被「向后挤」一位
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      // 当前歌曲被「向前挤」一位
      _currentIndex++;
    }

    // 3. 不重建 audio_service 队列，避免打断当前播放
    _updateNotification();
    notifyListeners();
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
    _saveState();
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
      _playlist = [if (currentSong != null) currentSong, ...remaining];
      _currentIndex = 0;
    } else {
      final currentSong = _currentSong;
      _playlist = List.from(_originalPlaylist);
      if (currentSong != null) {
        _currentIndex = _playlist.indexWhere((s) => s.id == currentSong.id);
        if (_currentIndex < 0) _currentIndex = 0;
      }
    }
    _saveState();
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
      final result = await apiClient.getSongUrlWithFallback(
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
    // 边听边存兜底：缓存命中时 artUrl 用本地 file:// 路径，避免断网时 MediaSession 无封面
    // 仅对在线歌曲生效，本地歌曲使用自身的 artworkUri，避免上一首在线缓存封面残留
    final effectiveArtUrl = (song.isOnline && _cachedArtworkPath != null)
        ? Uri.file(_cachedArtworkPath!).toString()
        : song.artworkUri;
    MediaNotificationService.updateNotification(
      // 使用 displayName 剥离 .mp3 等扩展名，与 _createAudioSource 行为保持一致
      title: song.displayName,
      artist: song.artist,
      artUrl: effectiveArtUrl,
      // 本地歌曲传递文件路径，供原生侧提取内嵌封面
      fallbackFilePath: song.localPath,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration ?? Duration.zero,
      desktopLyricEnabled: DesktopLyricService.instance.enabled,
      isFavorited: isFavorited,
    );
    // 同步更新桌面小组件（封面由原生侧从 MediaSession 缓存同步，无需传路径）
    HomeWidgetService.updateWidget(
      title: song.displayName,
      artist: song.artist,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration ?? Duration.zero,
    );
  }

  /// Public method to refresh notification (called when favorite state changes)
  void refreshNotification() {
    _updateNotification();
  }

  void _recordHistory(Song song) {
    HistoryRepository().addHistory(song);
    // 在线歌曲且已登录时，同步听歌历史到云端
    if (song.isOnline && KugouApiClient().isLoggedIn) {
      final mxid = song.albumAudioId ?? song.id;
      KugouApiClient().uploadPlayHistory(mxid).then((_) {}).catchError((_) => null);
    }
  }

  just_audio.UriAudioSource _createAudioSource(Song song) {
    final playbackUrl = song.isOnline ? song.url : song.localPath;
    // 本地歌曲的 artworkUri 是 local:// 或 content:// 格式，
    // just_audio 无法加载这些 URI 作为封面；系统通知封面由
    // AudioPlaybackService 通过 fallbackFilePath 提取内嵌封面处理
    final effectiveArtUri = song.isOnline && song.artworkUri != null
        ? Uri.parse(song.artworkUri!)
        : null;
    if (kIsWeb) {
      return createAudioSourceWeb(
        id: song.id,
        url: playbackUrl ?? '',
        // 使用 displayName 剥离 .mp3 等扩展名，避免系统通知栏/锁屏显示后缀
        title: song.displayName,
        artist: song.artist,
        album: song.album,
        artUri: effectiveArtUri,
      );
    }
    return createAudioSource(
      id: song.id,
      url: playbackUrl ?? '',
      // 使用 displayName 剥离 .mp3 等扩展名，避免系统通知栏/锁屏显示后缀
      title: song.displayName,
      artist: song.artist,
      album: song.album,
      artUri: effectiveArtUri,
    );
  }

  /// 把 [Song] 转为可播放的 `file://` 或绝对路径 URL。
  ///
  /// **关键**：本地音乐在 MediaStore 中以 `content://media/...` 形式存在，
  /// 而 `just_audio.setUrl` 不支持 `content://` 协议，会导致
  /// "播放没声音"。这里通过原生 MethodChannel 把 `content://` 解析为
  /// 真实文件路径（命中 MediaStore.DATA 字段或拷贝到 App 缓存）。
  ///
  /// 解析结果会回写到 song 的 `localPath`（去掉 `content://` 前缀后的真实路径），
  /// 后续切歌/重播时无需重新解析。
  Future<String?> _resolvePlaybackUrl(Song song) async {
    if (song.isOnline) return song.url;
    final raw = song.localPath;
    if (raw == null || raw.isEmpty) return null;
    // 非 content:// 协议：直接当本地路径用（兼容旧的绝对路径/SMB 路径等）
    if (!raw.startsWith('content://')) {
      // just_audio 的 setUrl / AudioSource.uri 需要完整的 URI，
      // 裸路径 /storage/emulated/0/... 会导致 "No host specified in URI" 错误。
      // 这里把绝对路径转换为 file:// URI。
      if (raw.startsWith('/')) {
        return Uri.file(raw).toString();
      }
      return raw;
    }
    try {
      final resolved = await MediaStoreService.resolveLocalPath(raw);
      if (resolved == null || resolved.isEmpty) {
        debugPrint('[PlayerProvider] 解析 content:// 失败: $raw');
        return null;
      }
      // resolved 是真实文件路径，同样需要转换为 file:// URI
      if (resolved.startsWith('/')) {
        final fileUri = Uri.file(resolved).toString();
        debugPrint('[PlayerProvider] content:// → $fileUri');
        return fileUri;
      }
      debugPrint('[PlayerProvider] content:// → $resolved');
      return resolved;
    } catch (e) {
      debugPrint('[PlayerProvider] resolvePlaybackUrl 异常: $e');
      return null;
    }
  }

  /// 批量解析一组本地音乐（仅对 `content://` URI 调用原生 MethodChannel）。
  ///
  /// 用于在 `appendPlaylist` / `insertAfterCurrent` / `removeFromPlaylist` 等
  /// 一次性构建多 source 的入口，避免对每首歌的 `content://` 漏解析而传给
  /// `just_audio` 导致"播放没声音"。
  ///
  /// 在线歌曲保持原样不动。解析失败的本地歌曲保留原 `content://`（让上层
  /// `setPlaylist` 静默失败，避免阻塞整体流程）。
  Future<List<Song>> _resolveLocalPathsForBatch(List<Song> songs) async {
    final result = <Song>[];
    for (final song in songs) {
      if (song.isOnline) {
        result.add(song);
        continue;
      }
      final raw = song.localPath;
      if (raw == null || raw.isEmpty) {
        result.add(song);
        continue;
      }
      // 非 content:// 的裸路径也需要转换为 file:// URI
      if (!raw.startsWith('content://')) {
        if (raw.startsWith('/') && !raw.startsWith('file://')) {
          result.add(song.copyWith(localPath: Uri.file(raw).toString()));
        } else {
          result.add(song);
        }
        continue;
      }
      final resolved = await _resolvePlaybackUrl(song);
      if (resolved != null && resolved != raw) {
        result.add(song.copyWith(localPath: resolved));
      } else {
        result.add(song);
      }
    }
    return result;
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
        // 本地歌曲优先读取内嵌歌词
        if (!song.isOnline) {
          final localPath = song.localPath;
          if (localPath != null && localPath.isNotEmpty) {
            String filePath = localPath;
            if (filePath.startsWith('file://')) {
              filePath = Uri.parse(filePath).toFilePath();
            }
            final embedded = readEmbeddedLyrics(filePath);
            if (embedded != null && embedded.isNotEmpty) {
              lines = LyricParserChain.parse(embedded);
            }
          }
        }

        // 内嵌歌词为空时从酷狗 API 获取
        if (lines.isEmpty) {
          final ctx = appNavigatorKey.currentContext;
          if (ctx != null) {
            try {
              final kugou = ctx.read<KugouProvider>();
              // 本地歌曲传空 hash + "歌名 艺术家" 关键词搜索
              final lyricHash = song.isOnline ? song.id : '';
              final searchName = !song.isOnline && song.artist != '未知艺术家'
                  ? '${song.title} ${song.artist}'
                  : song.title;
              await kugou.getLyric(lyricHash, songName: searchName, fmt: 'lrc');
              if (token != _lyriconFetchToken) return;
              final text = kugou.lyric?.displayLyric;
              final translationText = kugou.lyric?.translatedContent;
              final romaText = kugou.lyric?.romaContent;
              if (text != null && text.isNotEmpty) {
                lines = LyricParserChain.parse(
                  text,
                  translationText: translationText,
                  romaText: romaText,
                );
              }
            } catch (_) {}
          }
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // App 进入后台或即将被杀死，立即保存播放状态
      _saveState();
      _saveDebounce?.cancel();
    }
  }

  @override
  void dispose() {
    _saveState(); // 退出时立即保存
    _saveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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

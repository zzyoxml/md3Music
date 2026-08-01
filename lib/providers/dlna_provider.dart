import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../core/services/dlna_service.dart';
import '../data/models/song.dart';
import 'player_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';

/// 投屏状态枚举。
enum DlnaCastState {
  idle,       // 空闲
  searching,  // 正在搜索设备
  connecting, // 正在连接设备
  casting,    // 正在投屏
  error,      // 出错
}

/// DLNA 投屏状态管理，app 级持久。
class DlnaProvider extends ChangeNotifier {
  final DlnaService _service = DlnaService();

  // ── 状态 ──
  DlnaCastState _state = DlnaCastState.idle;
  List<DlnaDeviceInfo> _devices = [];
  String? _castTitle;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  String? _errorMessage;
  int _volume = 100;
  // 当前投屏的媒体类型（audio/video），用于切歌时保持类型一致
  DlnaMediaType _castMediaType = DlnaMediaType.audio;

  // 投屏前本地播放状态，用于停止投屏后恢复
  bool _wasPlayingBefore = false;
  // 标记正在切歌（手动或自动），防止自动切歌重复触发
  // 注意：不拦截手动切歌，手动切歌会重置此标志
  bool _autoSkipping = false;

  StreamSubscription? _devicesSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  Timer? _statePollTimer;

  DlnaCastState get state => _state;
  List<DlnaDeviceInfo> get devices => _devices;
  String? get castTitle => _castTitle;
  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration? get duration => _duration;
  String? get errorMessage => _errorMessage;
  int get volume => _volume;
  String? get deviceName => _service.deviceName;
  bool get isCasting => _state == DlnaCastState.casting;
  DlnaMediaType get castMediaType => _castMediaType;

  DlnaProvider() {
    _devicesSub = _service.devicesStream.listen((devices) {
      _devices = devices;
      notifyListeners();
    });
    _positionSub = _service.positionStream.listen((pos) {
      _position = pos;
      // 自动下一曲：position 接近 duration（差值≤3秒）时触发
      _checkAutoNext();
      notifyListeners();
    });
    _durationSub = _service.durationStream.listen((dur) {
      _duration = dur;
      notifyListeners();
    });
  }

  /// 检测投屏播放结束：position 接近 duration 时自动切下一首。
  /// 通过回调 [onAutoNext] 注入切歌逻辑，避免 Provider 持有 BuildContext。
  Future<void> Function(BuildContext)? onAutoNext;

  void _checkAutoNext() {
    // 防止重复触发、非投屏状态、无时长信息时不触发
    if (_autoSkipping) return;
    if (!isCasting || !_isPlaying) return;
    final dur = _duration;
    if (dur == null || dur.inSeconds < 10) return;
    // position 距离结束 3 秒内视为播放结束
    final remaining = dur.inSeconds - _position.inSeconds;
    if (remaining <= 3 && _position.inSeconds > 0) {
      _autoSkipping = true;
      // 通过回调触发外部切歌（避免在 provider 中持有 context）
      final ctx = _autoNextContext;
      if (ctx != null && onAutoNext != null) {
        // 异步执行，不阻塞 position 监听；finally 会复位 _autoSkipping
        onAutoNext!(ctx);
      } else {
        _autoSkipping = false;
      }
    }
  }

  /// 自动切歌的 context 缓存（由 UI 层设置）。
  BuildContext? _autoNextContext;
  void setAutoNextContext(BuildContext context) {
    _autoNextContext = context;
  }

  /// 开始搜索局域网内的 DLNA 设备。
  Future<void> startSearch() async {
    _state = DlnaCastState.searching;
    _devices = [];
    _errorMessage = null;
    notifyListeners();
    try {
      await _service.startSearch();
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = '搜索失败：$e';
      notifyListeners();
    }
  }

  /// 停止搜索。
  Future<void> stopSearch() async {
    await _service.stopSearch();
    if (_state == DlnaCastState.searching) {
      _state = DlnaCastState.idle;
      notifyListeners();
    }
  }

  /// 投屏歌曲：获取在线播放 URL → cast → 暂停本地播放。
  /// [preserveWasPlaying] 为 true 时不覆盖 _wasPlayingBefore（切歌场景）。
  Future<void> castSong(BuildContext context, Song song,
      {bool preserveWasPlaying = false}) async {
    if (!song.isOnline) {
      _state = DlnaCastState.error;
      _errorMessage = '本地歌曲不支持投屏';
      notifyListeners();
      return;
    }

    _state = DlnaCastState.connecting;
    _castTitle = song.displayName;
    _castMediaType = DlnaMediaType.audio;
    notifyListeners();

    try {
      // 获取新鲜的播放 URL
      final apiClient = KugouApiClient();
      final playerProvider = context.read<PlayerProvider>();
      final result = await apiClient.getSongUrlWithFallback(
        song.id,
        quality: playerProvider.audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result == null || result.url.isEmpty) {
        _state = DlnaCastState.error;
        _errorMessage = '无法获取播放地址';
        notifyListeners();
        return;
      }

      final success = await _service.cast(
        result.url,
        title: song.displayName,
        mediaType: DlnaMediaType.audio,
      );

      if (success) {
        // 暂停本地播放（切歌场景不覆盖 _wasPlayingBefore）
        if (!preserveWasPlaying) {
          _wasPlayingBefore = playerProvider.isPlaying;
        }
        if (playerProvider.isPlaying) {
          playerProvider.pause();
        }
        _state = DlnaCastState.casting;
        _isPlaying = true;
        _startStatePolling();
        notifyListeners();
      } else {
        _state = DlnaCastState.error;
        _errorMessage = '投屏失败，请重试';
        notifyListeners();
      }
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = '投屏出错：$e';
      notifyListeners();
    }
  }

  /// 投屏 MV：使用已解析的 MV URL。
  Future<void> castMv(String url, String title) async {
    _state = DlnaCastState.connecting;
    _castTitle = title;
    _castMediaType = DlnaMediaType.video;
    notifyListeners();

    try {
      final success = await _service.cast(
        url,
        title: title,
        mediaType: DlnaMediaType.video,
      );

      if (success) {
        _state = DlnaCastState.casting;
        _isPlaying = true;
        _startStatePolling();
        notifyListeners();
      } else {
        _state = DlnaCastState.error;
        _errorMessage = '投屏失败，请重试';
        notifyListeners();
      }
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = '投屏出错：$e';
      notifyListeners();
    }
  }

  /// 选择设备并连接。
  void selectDevice(DlnaDeviceInfo device) {
    _service.connectDevice(device.device);
  }

  Future<void> play() async {
    await _service.play();
    _isPlaying = true;
    notifyListeners();
  }

  Future<void> pause() async {
    await _service.pause();
    _isPlaying = false;
    notifyListeners();
  }

  /// 停止投屏并恢复本地播放。
  Future<void> stop() async {
    await _service.stop();
    _stopStatePolling();
    _state = DlnaCastState.idle;
    _isPlaying = false;
    _position = Duration.zero;
    _duration = null;
    _castTitle = null;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _service.seek(position);
    _position = position;
    notifyListeners();
  }

  Future<void> setVolume(int vol) async {
    _volume = vol;
    await _service.setVolume(vol);
    notifyListeners();
  }

  /// 切歌后重新投屏（遥控页面上一首/下一首/自动切歌）。
  /// 根据 _castMediaType 决定投屏音频还是 MV，保持媒体类型一致。
  /// 使用 autoPlay: false 避免本地播放器实际播放，仅切换索引。
  /// 使用 preserveWasPlaying: true 保持原始 _wasPlayingBefore 不被覆盖。
  ///
  /// 防抖说明：_checkAutoNext 已在触发前检查 _autoSkipping；
  /// 此处统一设置 _autoSkipping = true 仅用于在切歌异步执行期间
  /// 阻止 _checkAutoNext 重复触发，不拦截手动切歌。
  Future<void> castNextSong(BuildContext context, {bool isAutoNext = false}) async {
    _autoSkipping = true;
    try {
      final playerProvider = context.read<PlayerProvider>();
      await playerProvider.next(autoPlay: false);
      final song = playerProvider.currentSong;
      if (song != null) {
        await _castByMediaType(context, song);
      }
    } finally {
      _autoSkipping = false;
    }
  }

  Future<void> castPreviousSong(BuildContext context) async {
    _autoSkipping = true;
    try {
      final playerProvider = context.read<PlayerProvider>();
      await playerProvider.previous(autoPlay: false);
      final song = playerProvider.currentSong;
      if (song != null) {
        await _castByMediaType(context, song);
      }
    } finally {
      _autoSkipping = false;
    }
  }

  /// 根据当前投屏媒体类型选择投屏方式：audio → castSong，video → castMv。
  /// MV 切歌时重新解析新歌曲的 MV URL，避免变成音频投屏。
  Future<void> _castByMediaType(BuildContext context, Song song) async {
    if (_castMediaType == DlnaMediaType.video) {
      // MV 投屏切歌：重新解析新歌曲的 MV
      final albumAudioId = song.albumAudioId;
      if (albumAudioId == null || albumAudioId.isEmpty) {
        // 新歌曲没有 MV 信息，回退到音频投屏
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      final api = KugouApiClient();
      final mvInfo = await api.getMvByAlbumAudioId(albumAudioId);
      if (mvInfo == null || !mvInfo.hasMv) {
        // 新歌曲无 MV，回退到音频投屏
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      // 优先用 mvId 取详情，否则直接用 hash
      String? hash = mvInfo.hash;
      final mvId = mvInfo.mvId;
      if (mvId != null && mvId.isNotEmpty) {
        final detail = await api.getVideoDetail(mvId);
        if (detail != null && detail.qualities.isNotEmpty) {
          hash = detail.qualities.last.hash;
        }
      }
      if (hash == null || hash.isEmpty) {
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      final url = await api.getVideoUrl(hash);
      if (url == null || url.isEmpty) {
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      await castMv(url, song.displayName);
      // MV 切歌也需要保持 _wasPlayingBefore
      _wasPlayingBefore = false;
    } else {
      // 音频投屏切歌
      await castSong(context, song, preserveWasPlaying: true);
    }
  }

  /// 停止投屏后恢复本地播放。
  Future<void> restoreLocalPlayback(BuildContext context) async {
    if (_wasPlayingBefore) {
      _wasPlayingBefore = false;
      try {
        context.read<PlayerProvider>().resume();
      } catch (_) {}
    }
  }

  /// 定期轮询设备传输状态，同步播放/暂停状态。
  void _startStatePolling() {
    _statePollTimer?.cancel();
    _statePollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_service.isCasting) {
        timer.cancel();
        return;
      }
      final transportState = await _service.getTransportState();
      if (transportState != null) {
        final wasPlaying = _isPlaying;
        _isPlaying = transportState == 'PLAYING';
        if (wasPlaying != _isPlaying) {
          notifyListeners();
        }
      }
    });
  }

  void _stopStatePolling() {
    _statePollTimer?.cancel();
    _statePollTimer = null;
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _statePollTimer?.cancel();
    _service.dispose();
    super.dispose();
  }
}
